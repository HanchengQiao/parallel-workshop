#!/bin/bash
# 生成上线前外部审计包：精确 Git 源码快照 + 双端候选产物 + QA/哈希/构建环境证据。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区不干净；外审包必须对应一个精确提交"
  git status --short
  exit 1
fi

COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short=12 HEAD)"
BRANCH="$(git branch --show-current)"
VERSION="$(python3 -c 'import json; print(json.load(open("Windows/edge-extension/manifest.json"))["version"])')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ manifest 版本号无效: $VERSION"; exit 1; }
TRACKED_COUNT="$(git ls-tree -r --name-only "$COMMIT" | wc -l | tr -d ' ')"
NAME="ParallelWorkbench-${VERSION}-prelaunch-external-audit-${SHORT}"
AUDIT_ROOT="build/external-audit"
STAGE="${AUDIT_ROOT}/${NAME}"
ARCHIVE="build/${NAME}.zip"
VERIFY_SIDECAR="build/${NAME}.VERIFY.log"

rm -rf "$STAGE"
rm -f "$ARCHIVE" "$VERIFY_SIDECAR"
mkdir -p "$STAGE/source" "$STAGE/artifacts" "$STAGE/audit"

echo "==> 1/7 运行完整 QA"
if ! bash scripts/qa.sh > "$STAGE/audit/QA.log" 2>&1; then
  cat "$STAGE/audit/QA.log"
  echo "❌ QA 失败，拒绝生成外审包"
  exit 1
fi

echo "==> 2/7 重建双端候选产物"
VERSION="$VERSION" bash scripts/package-app.sh > "$STAGE/audit/BUILD-macOS.log" 2>&1
VERSION="$VERSION" bash scripts/package-dmg.sh >> "$STAGE/audit/BUILD-macOS.log" 2>&1
bash scripts/build-edge-extension.sh > "$STAGE/audit/BUILD-Edge.log" 2>&1
hdiutil verify "build/ParallelWorkbench-${VERSION}.dmg" > "$STAGE/audit/VERIFY-DMG.log" 2>&1
MOUNT_DIR="$(mktemp -d /tmp/pwb-external-audit-mount.XXXXXX)"
cleanup_mount() {
  hdiutil detach "$MOUNT_DIR" > /dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" > /dev/null 2>&1 || true
}
trap cleanup_mount EXIT
hdiutil attach "build/ParallelWorkbench-${VERSION}.dmg" -readonly -nobrowse -mountpoint "$MOUNT_DIR" > /dev/null
DMG_APP="$MOUNT_DIR/ParallelWorkbench.app"
test -x "$DMG_APP/Contents/MacOS/ParallelWorkbench"
DMG_APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$DMG_APP/Contents/Info.plist")"
DMG_APP_ARCHS="$(lipo -archs "$DMG_APP/Contents/MacOS/ParallelWorkbench")"
test "$DMG_APP_VERSION" = "$VERSION"
if [[ " $DMG_APP_ARCHS " != *" arm64 "* || " $DMG_APP_ARCHS " != *" x86_64 "* ]]; then
  echo "❌ DMG 内 App 缺少通用架构：$DMG_APP_ARCHS"
  exit 1
fi
{
  printf 'CFBundleShortVersionString=%s\n' "$DMG_APP_VERSION"
  printf 'CFBundleIdentifier=%s\n' "$(plutil -extract CFBundleIdentifier raw "$DMG_APP/Contents/Info.plist")"
  printf 'LSMinimumSystemVersion=%s\n' "$(plutil -extract LSMinimumSystemVersion raw "$DMG_APP/Contents/Info.plist")"
  printf 'Architectures=%s\n\n' "$DMG_APP_ARCHS"
  printf '%s\n' '--- codesign metadata ---'
  codesign -dvv "$DMG_APP" 2>&1 || true
  printf '\n%s\n' '--- codesign verification ---'
  codesign --verify --deep --strict --verbose=2 "$DMG_APP" 2>&1 || true
  printf '\n%s\n' '--- Gatekeeper assessment (expected rejection for unsigned direct build) ---'
  spctl -a -vv -t execute "$DMG_APP" 2>&1 || true
} > "$STAGE/audit/VERIFY-macOS-app-and-signing.log"
cleanup_mount
trap - EXIT
APP_ZIP="$(pwd)/$STAGE/artifacts/ParallelWorkbench.app.zip"
(cd build && zip -qry -y "$APP_ZIP" ParallelWorkbench.app -x '*/.DS_Store' -x '__MACOSX/*')
cp "build/ParallelWorkbench-${VERSION}.dmg" "$STAGE/artifacts/"
cp build/edge-extension.zip build/edge-extension-store.zip "$STAGE/artifacts/"
cp install-windows.ps1 "$STAGE/artifacts/"
node scripts/generate-update-manifest.mjs "$VERSION" "$STAGE/artifacts/"

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 构建改写了受版本控制的文件，拒绝打包"
  git status --short
  exit 1
fi

echo "==> 3/7 导出精确源码快照"
git archive --format=tar "$COMMIT" | tar -xf - -C "$STAGE/source"
if git ls-tree -r "$COMMIT" | awk '$1 == "120000" { print }' | grep -q .; then
  echo "❌ 源码快照包含符号链接，需外审前逐项批准"
  exit 1
fi
git ls-tree -r --name-only "$COMMIT" > "$STAGE/audit/TRACKED_FILES.txt"
git ls-tree -r "$COMMIT" > "$STAGE/audit/TRACKED_TREE_WITH_MODES.txt"
git log -20 --date=iso-strict --pretty=format:'%H%x09%ad%x09%an%x09%s' > "$STAGE/audit/GIT_LOG_LAST_20.txt"
BASELINE_TAG="$(git tag --merged "$COMMIT" --list 'v[0-9]*' --sort=-version:refname | head -n 1)"
if [ -n "$BASELINE_TAG" ]; then
  git diff --binary "$BASELINE_TAG" "$COMMIT" > "$STAGE/audit/CHANGESET-${BASELINE_TAG}-to-candidate.diff"
  printf '%s\n' "$BASELINE_TAG" > "$STAGE/audit/BASELINE_TAG.txt"
fi

echo "==> 4/7 敏感文件与高置信密钥扫描"
SUSPECT_FILE="$AUDIT_ROOT/secret-scan-${SHORT}.tmp"
rm -f "$SUSPECT_FILE"
if find "$STAGE/source" -type f \( \
  -iname '*.pem' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.key' \
  -o -iname '*.mobileprovision' -o -iname '*.keystore' -o -iname '*.jks' \
  -o -iname '.env' -o -iname '.env.*' -o -iname '.npmrc' -o -iname '.netrc' \
  -o -iname '.git-credentials' \) -print | grep -q .; then
  echo "❌ 源码快照包含潜在敏感文件"
  find "$STAGE/source" -type f \( \
    -iname '*.pem' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.key' \
    -o -iname '*.mobileprovision' -o -iname '*.keystore' -o -iname '*.jks' \
    -o -iname '.env' -o -iname '.env.*' -o -iname '.npmrc' -o -iname '.netrc' \
    -o -iname '.git-credentials' \) -print
  exit 1
fi
if rg -n -I -g '!scripts/package-external-audit.sh' \
  '(-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{24,})' \
  "$STAGE/source" > "$SUSPECT_FILE"; then
  echo "❌ 检出疑似高置信密钥，拒绝打包"
  sed -n '1,40p' "$SUSPECT_FILE"
  exit 1
fi
rm -f "$SUSPECT_FILE"
printf '%s\n' 'PASS: 未发现私钥文件、.env 文件或高置信 API/token 模式。' > "$STAGE/audit/SECRET_SCAN.txt"

echo "==> 5/7 生成来源、环境与 SHA-256 清单"
{
  printf 'Package: %s\n' "$NAME"
  printf 'Candidate status: prelaunch external audit; not a public release\n'
  printf 'Manifest version: %s\n' "$VERSION"
  printf 'Git commit: %s\n' "$COMMIT"
  printf 'Git branch: %s\n' "$BRANCH"
  printf 'Generated UTC: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'Tracked source files: %s\n' "$TRACKED_COUNT"
} > "$STAGE/audit/PROVENANCE.txt"

{
  sw_vers
  printf '\n'
  xcodebuild -version
  printf '\n'
  swift --version
  printf '\nNode %s\n' "$(node --version)"
  printf 'npm %s\n' "$(npm --version)"
  git --version
} > "$STAGE/audit/BUILD_ENVIRONMENT.txt" 2>&1

(cd "$STAGE/source" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done) \
  > "$STAGE/audit/SOURCE_SHA256.txt"
(cd "$STAGE/artifacts" && shasum -a 256 ./*) > "$STAGE/audit/ARTIFACTS_SHA256.txt"
lipo -archs build/ParallelWorkbench.app/Contents/MacOS/ParallelWorkbench \
  > "$STAGE/audit/MACOS_ARCHITECTURES.txt"
unzip -t build/edge-extension.zip > "$STAGE/audit/VERIFY-Edge-user-zip.log"
unzip -t build/edge-extension-store.zip > "$STAGE/audit/VERIFY-Edge-store-zip.log"

cat > "$STAGE/README-EXTERNAL-AUDIT.md" <<EOF
# 智囊 · Braintrust · 上线前外部审计包

本包对应 Git commit \`${COMMIT}\`，候选状态为 **prelaunch**，不是公开 Release。
manifest 当前版本字段为 \`${VERSION}\`；请以 commit 与 SHA-256 清单识别本候选，避免与同版本号的历史公开资产混淆。

## 目录

- \`source/\`：由 \`git archive ${COMMIT}\` 导出的全部 ${TRACKED_COUNT} 个受版本控制文件。
- \`artifacts/\`：macOS App ZIP、DMG、Edge 用户侧载 ZIP、Edge 商店 ZIP、Windows Latest 引导器、备用更新索引。
- \`audit/\`：来源、跟踪文件列表、源码/产物 SHA-256、QA、构建与完整性验证日志。

## 重要边界

- macOS 候选为未签名、未公证的开源直发构建；彻底消除 Gatekeeper 警告需要 Apple Developer 签名与公证。
- Edge 用户包带顶层 \`edge-extension/\` 目录；商店包的 \`manifest.json\` 位于 ZIP 根目录。
- 包内不含 \`.git\`、\`.build\`、\`node_modules\`、浏览器 profile、登录态、二维码、截图或本机环境变量。
- 工作台外壳采用三色设计；嵌入的第三方平台页面保留其自身颜色与代码。

## 建议审计顺序

1. 核对 \`audit/PROVENANCE.txt\` 与两份 SHA-256 清单。
2. 阅读 \`source/README.md\`、\`source/交付说明/产品说明与代码解读.md\`。
3. 执行 \`cd source && npm ci --prefix scripts --ignore-scripts --no-audit --no-fund && bash scripts/qa.sh\`。
4. 重点审计 Edge 的 \`background.js\`、认证桥、runtime 消息通道、DNR session rule 与单 target 启动策略。
5. 重点审计 macOS 的 WKWebView 登录围栏、注入核心、更新器 SHA-256 fail-closed 路径。
EOF

echo "==> 6/7 组装单一 ZIP"
(cd "$AUDIT_ROOT" && zip -qry "../${NAME}.zip" "$NAME")
unzip -t "$ARCHIVE" > "$STAGE/audit/VERIFY-ASSEMBLY-ZIP.log"

# 内部日志验证组装结构；加入该日志后重建最终 ZIP，并把最终字节验证写入同目录 sidecar。
rm -f "$ARCHIVE"
(cd "$AUDIT_ROOT" && zip -qry "../${NAME}.zip" "$NAME")
unzip -t "$ARCHIVE" > "$VERIFY_SIDECAR"
if unzip -Z1 "$ARCHIVE" | rg '/(\.git|\.build|node_modules|_metadata|auth-backup|test-output)(/|$)' > /dev/null; then
  echo "❌ 外审 ZIP 含禁止目录，拒绝交付"
  exit 1
fi

echo "==> 7/7 完成"
printf 'PATH=%s\n' "$(pwd)/$ARCHIVE"
printf 'VERIFY_PATH=%s\n' "$(pwd)/$VERIFY_SIDECAR"
printf 'SIZE_BYTES=%s\n' "$(stat -f %z "$ARCHIVE")"
printf 'SHA256=%s\n' "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
