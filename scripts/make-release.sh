#!/bin/bash
# 从与 main/HEAD 精确对应的外审 stage 创建 GitHub Draft Release。
# 本脚本不重建产物，确保外审、真机验证与待发布资产为同一字节。
# 用法：bash scripts/make-release.sh X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: bash scripts/make-release.sh X.Y.Z}"
REPO="porcelaintech/parallel-workshop"
DEFAULT_BRANCH="main"
TAG="v${VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 无效版本号: $VERSION"; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区不干净；发布必须对应精确提交"
  git status --short
  exit 1
fi

ORIGIN_URL="$(git remote get-url origin)"
ORIGIN_REPO="$(python3 - "$ORIGIN_URL" <<'PY'
import re, sys
url = sys.argv[1].strip()
patterns = (
    r'^https://github\.com/([^/]+/[^/]+?)(?:\.git)?$',
    r'^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$',
    r'^ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$',
)
for pattern in patterns:
    match = re.match(pattern, url)
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(2)
PY
)" || { echo "❌ origin 不是受支持的 GitHub HTTPS/SSH 地址: $ORIGIN_URL"; exit 1; }
[ "$ORIGIN_REPO" = "$REPO" ] || { echo "❌ origin 仓库不匹配: $ORIGIN_REPO"; exit 1; }

echo "==> 同步并锁定 ${REPO}/${DEFAULT_BRANCH}"
git fetch origin "$DEFAULT_BRANCH" --tags
BRANCH="$(git branch --show-current)"
[ "$BRANCH" = "$DEFAULT_BRANCH" ] || { echo "❌ 只能从 ${DEFAULT_BRANCH} 发布，当前为 $BRANCH"; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "origin/${DEFAULT_BRANCH}")"
[ "$HEAD_SHA" = "$REMOTE_SHA" ] || { echo "❌ HEAD 与 origin/${DEFAULT_BRANCH} 不一致"; exit 1; }

python3 - "$VERSION" <<'PY'
import json, re, sys
from pathlib import Path
version = sys.argv[1]
manifest = json.load(open('Windows/edge-extension/manifest.json'))['version']
npm = json.load(open('npm-launcher/package.json'))['version']
cask = re.search(r'version "([0-9.]+)"', Path('homebrew/Casks/parallel-workbench.rb').read_text()).group(1)
if {manifest, npm, cask} != {version}:
    raise SystemExit(f'版本不一致: manifest={manifest} npm={npm} cask={cask} expected={version}')
checks = {
    'README.md': f'v{version} 是当前稳定版',
    'Windows/README.md': f'v{version} 是当前稳定版',
    'Windows/edge-extension/WINDOWS.md': f'v{version} 是当前稳定版',
    'macOS/README.md': f'v{version} 是当前稳定版',
    '交付说明/产品说明与代码解读.md': f'版本：v{version}｜',
}
for filename, expected in checks.items():
    text = Path(filename).read_text()
    if expected not in text or '当前上线候选' in text:
        raise SystemExit(f'{filename} 尚未切换为正式版本文案')
if f'VERSION={version}' not in Path('macOS/README.md').read_text():
    raise SystemExit('macOS/README.md 手动下载版本未同步')
PY

SHORT="$(git rev-parse --short=12 HEAD)"
NAME="ParallelWorkbench-${VERSION}-prelaunch-external-audit-${SHORT}"
STAGE="build/external-audit/${NAME}"
AUDIT_ARCHIVE="build/${NAME}.zip"
AUDIT_VERIFY="build/${NAME}.VERIFY.log"
ARTIFACTS="$STAGE/artifacts"
[ -d "$ARTIFACTS" ] || { echo "❌ 缺少与 HEAD 对应的外审 stage: $STAGE"; exit 1; }
[ -f "$AUDIT_ARCHIVE" ] && [ -f "$AUDIT_VERIFY" ] || { echo "❌ 缺少外审 ZIP 或最终验证 sidecar"; exit 1; }
unzip -t "$AUDIT_ARCHIVE" > /dev/null

grep -Fx "Manifest version: ${VERSION}" "$STAGE/audit/PROVENANCE.txt" > /dev/null
grep -Fx "Git commit: ${HEAD_SHA}" "$STAGE/audit/PROVENANCE.txt" > /dev/null
grep -F 'QA 门禁全部通过' "$STAGE/audit/QA.log" > /dev/null
grep -F 'PASS:' "$STAGE/audit/SECRET_SCAN.txt" > /dev/null

python3 - "$ARTIFACTS" "$VERSION" "$STAGE/audit/ARTIFACTS_SHA256.txt" <<'PY'
import json, re, sys, zipfile
from pathlib import Path
root = Path(sys.argv[1])
version = sys.argv[2]
hash_list = Path(sys.argv[3])
expected = {
    'ParallelWorkbench.app.zip',
    f'ParallelWorkbench-{version}.dmg',
    'edge-extension.zip',
    'edge-extension-store.zip',
    'install-windows.ps1',
}
actual = {item.name for item in root.iterdir() if item.is_file()}
if actual != expected:
    raise SystemExit(f'外审 artifacts 集合不精确: extra={actual-expected} missing={expected-actual}')
if any(item.is_symlink() for item in root.iterdir()):
    raise SystemExit('外审 artifacts 不得包含符号链接')
listed = []
for line in hash_list.read_text().splitlines():
    match = re.fullmatch(r'([0-9a-f]{64})\s+\*?\./([^/]+)', line)
    if not match:
        raise SystemExit(f'ARTIFACTS_SHA256 格式无效: {line!r}')
    listed.append(match.group(2))
if len(listed) != len(expected) or set(listed) != expected:
    raise SystemExit('ARTIFACTS_SHA256 文件集合缺失、重复或多余')
with zipfile.ZipFile(root / 'edge-extension.zip') as archive:
    manifest = json.loads(archive.read('edge-extension/manifest.json'))
if manifest.get('version') != version:
    raise SystemExit('Edge 用户包 manifest 版本不匹配')
with zipfile.ZipFile(root / 'edge-extension-store.zip') as archive:
    store_manifest = json.loads(archive.read('manifest.json'))
if store_manifest.get('version') != version or 'key' in store_manifest:
    raise SystemExit('Edge 商店包 manifest 版本/渠道不匹配')
PY

(cd "$ARTIFACTS" && shasum -a 256 -c ../audit/ARTIFACTS_SHA256.txt)
cmp -s install-windows.ps1 "$ARTIFACTS/install-windows.ps1" || { echo "❌ 外审 Windows 引导器与 HEAD 不一致"; exit 1; }

MOUNT_DIR="$(mktemp -d /tmp/pwb-release-verify.XXXXXX)"
cleanup_mount() {
  hdiutil detach "$MOUNT_DIR" > /dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" > /dev/null 2>&1 || true
}
trap cleanup_mount EXIT
hdiutil attach "$ARTIFACTS/ParallelWorkbench-${VERSION}.dmg" -readonly -nobrowse -mountpoint "$MOUNT_DIR" > /dev/null
DMG_VERSION="$(plutil -extract CFBundleShortVersionString raw "$MOUNT_DIR/ParallelWorkbench.app/Contents/Info.plist")"
[ "$DMG_VERSION" = "$VERSION" ] || { echo "❌ DMG App 版本不匹配: $DMG_VERSION"; exit 1; }
cleanup_mount
trap - EXIT

if git show-ref --verify --quiet "refs/tags/${TAG}"; then
  echo "❌ 本地 tag 已存在: $TAG"
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" > /dev/null 2>&1; then
  echo "❌ 远程 tag 已存在: $TAG"
  exit 1
fi
if gh release list -R "$REPO" --limit 100 --json tagName --jq '.[].tagName' | grep -Fx "$TAG" > /dev/null; then
  echo "❌ Release 已存在: $TAG"
  exit 1
fi

DMG="$ARTIFACTS/ParallelWorkbench-${VERSION}.dmg"
EDGE_ZIP="$ARTIFACTS/edge-extension.zip"
BOOTSTRAP="$ARTIFACTS/install-windows.ps1"
DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
ZIP_SHA="$(shasum -a 256 "$EDGE_ZIP" | awk '{print $1}')"
BOOTSTRAP_SHA="$(shasum -a 256 "$BOOTSTRAP" | awk '{print $1}')"
NOTES_FILE="build/release-notes-${TAG}.md"
python3 - "$VERSION" "$TAG" "$REPO" "$DMG_SHA" "$ZIP_SHA" "$BOOTSTRAP_SHA" "$NOTES_FILE" <<'PY'
import sys
from pathlib import Path
version, tag, repo, dmg_sha, zip_sha, bootstrap_sha, output = sys.argv[1:]
windows_command = next(
    line.strip() for line in Path('Windows/README.md').read_text().splitlines()
    if 'releases/latest/download/install-windows.ps1' in line
)
notes = f'''平行工作台 v{version}

改进：
- Windows 固定 Latest 快速安装，支持重试、SHA-256、原子替换与中文/空格路径。
- 记住平台选择、分页、缩放及 DeepSeek 上次模型；登录存储保持原位。
- 新增豆包，并保留六个平台 iframe 状态。
- Edge 启动保持零 blank，640/900/1440px 自适应 1/2/3 窗格。
- 双端更新链路与完整下载超时、哈希校验进一步加固。

一键安装：

macOS：
```bash
curl -fsSL https://raw.githubusercontent.com/{repo}/main/install.sh | bash
```

Windows PowerShell：
```powershell
{windows_command}
```

资产：
- [ParallelWorkbench-{version}.dmg](https://github.com/{repo}/releases/download/{tag}/ParallelWorkbench-{version}.dmg)
- [edge-extension.zip](https://github.com/{repo}/releases/download/{tag}/edge-extension.zip)
- [install-windows.ps1](https://github.com/{repo}/releases/download/{tag}/install-windows.ps1)

SHA256 ParallelWorkbench-{version}.dmg {dmg_sha}
SHA256 edge-extension.zip {zip_sha}
SHA256 install-windows.ps1 {bootstrap_sha}
'''
Path(output).write_text(notes)
PY

echo "==> 创建并推送精确 tag ${TAG}"
git tag -a "$TAG" -m "Release $TAG" "$HEAD_SHA"
git push origin "$TAG"

echo "==> 从已审计资产创建 Draft Release"
if ! gh release create "$TAG" "$DMG" "$EDGE_ZIP" "$BOOTSTRAP" \
  --title "平行工作台 ${VERSION}" --notes-file "$NOTES_FILE" \
  --draft --verify-tag -R "$REPO"; then
  echo "❌ Draft Release 创建失败；远程 tag ${TAG} 已存在，请人工检查后恢复"
  exit 1
fi

REMOTE_TAG_TARGET="$(git ls-remote origin "refs/tags/${TAG}^{}" | awk '{print $1}')"
[ "$REMOTE_TAG_TARGET" = "$HEAD_SHA" ] || { echo "❌ 远程 tag 未指向 HEAD"; exit 1; }

DMG_SIZE="$(stat -f %z "$DMG")"
ZIP_SIZE="$(stat -f %z "$EDGE_ZIP")"
BOOTSTRAP_SIZE="$(stat -f %z "$BOOTSTRAP")"
RELEASE_JSON="build/release-${TAG}.json"
VERIFIED=0
for attempt in 1 2 3 4 5; do
  gh release view "$TAG" -R "$REPO" --json tagName,isDraft,assets,url > "$RELEASE_JSON"
  if python3 - "$RELEASE_JSON" "$TAG" \
      "ParallelWorkbench-${VERSION}.dmg:$DMG_SIZE:$DMG_SHA" \
      "edge-extension.zip:$ZIP_SIZE:$ZIP_SHA" \
      "install-windows.ps1:$BOOTSTRAP_SIZE:$BOOTSTRAP_SHA" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
expected_tag = sys.argv[2]
expected = {}
for spec in sys.argv[3:]:
    name, size, digest = spec.split(':', 2)
    expected[name] = (int(size), digest)
actual = {item['name']: (int(item['size']), str(item.get('digest') or '').removeprefix('sha256:'))
          for item in data.get('assets', [])}
if data.get('tagName') != expected_tag or data.get('isDraft') is not True:
    raise SystemExit(1)
if actual != expected:
    raise SystemExit(1)
PY
  then
    VERIFIED=1
    break
  fi
  sleep 2
done
[ "$VERIFIED" -eq 1 ] || { echo "❌ Draft Release 三项资产的名称/大小/digest 回查失败"; exit 1; }

gh release view "$TAG" -R "$REPO" --json tagName,isDraft,assets,url \
  --jq '{tag:.tagName,draft:.isDraft,url,assets:[.assets[]|{name,size,digest}]}'
echo "✅ Draft Release 已创建；正式发布前需再次确认三个资产与固定入口"
