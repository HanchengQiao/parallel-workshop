#!/bin/bash
# 一键安装平行工作台：读取 GitHub Release 元数据 → 强制 SHA-256 校验 → 原子安装。
set -euo pipefail

PWB_REPOSITORY="${PARALLEL_WORKBENCH_REPO:-HanchengQiao/parallel-workshop}"
PWB_REQUESTED_VERSION="${PARALLEL_WORKBENCH_VERSION:-}"
if [[ ! "$PWB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "❌ 仓库名格式无效"
  exit 1
fi
if [ -n "$PWB_REQUESTED_VERSION" ] && [[ ! "$PWB_REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ 版本号格式无效（应为 X.Y.Z）"
  exit 1
fi

PWB_INSTALL_TMP="$(mktemp -d)"
PWB_MOUNT=""
PWB_DEST="/Applications/ParallelWorkbench.app"
PWB_STAGED="/Applications/.ParallelWorkbench.app.new-$$"
PWB_BACKUP="/Applications/.ParallelWorkbench.app.old-$$"

cleanup() {
  if [ -n "$PWB_MOUNT" ]; then hdiutil detach "$PWB_MOUNT" >/dev/null 2>&1 || true; fi
  if [ -d "$PWB_BACKUP" ] && [ ! -d "$PWB_DEST" ]; then mv "$PWB_BACKUP" "$PWB_DEST" 2>/dev/null || true; fi
  rm -rf "$PWB_INSTALL_TMP" "$PWB_STAGED"
}
trap cleanup EXIT INT TERM

if [ -n "$PWB_REQUESTED_VERSION" ]; then
  PWB_RELEASE_API="https://api.github.com/repos/${PWB_REPOSITORY}/releases/tags/v${PWB_REQUESTED_VERSION}"
else
  PWB_RELEASE_API="https://api.github.com/repos/${PWB_REPOSITORY}/releases/latest"
fi

echo "==> 获取 Release 元数据"
curl -fsSL -H "Accept: application/vnd.github+json" "$PWB_RELEASE_API" -o "$PWB_INSTALL_TMP/release.json"

PWB_META="$(python3 - "$PWB_INSTALL_TMP/release.json" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
tag = str(data.get("tag_name") or "")
version = tag[1:] if tag.startswith("v") else tag
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Release tag 不是有效语义版本")
name = f"ParallelWorkbench-{version}.dmg"
asset = next((a for a in data.get("assets", []) if a.get("name") == name), None)
if not asset or not asset.get("browser_download_url"):
    raise SystemExit(f"Release 缺少 {name}")
digest = str(asset.get("digest") or "")
if digest.startswith("sha256:"):
    digest = digest[7:]
if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
    body = str(data.get("body") or "")
    match = re.search(rf"(?mi)^SHA256\s+{re.escape(name)}\s+([0-9a-f]{{64}})\s*$", body)
    digest = match.group(1) if match else ""
if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
    raise SystemExit("Release 未提供有效 SHA-256，拒绝安装")
print(version)
print(asset["browser_download_url"])
print(digest.lower())
PY
)"
PWB_VERSION="$(printf '%s\n' "$PWB_META" | sed -n '1p')"
PWB_URL="$(printf '%s\n' "$PWB_META" | sed -n '2p')"
PWB_EXPECTED_SHA="$(printf '%s\n' "$PWB_META" | sed -n '3p')"

echo "==> 下载 ParallelWorkbench-${PWB_VERSION}.dmg"
curl -fL --progress-bar -o "$PWB_INSTALL_TMP/app.dmg" "$PWB_URL"
PWB_ACTUAL_SHA="$(shasum -a 256 "$PWB_INSTALL_TMP/app.dmg" | awk '{print $1}')"
if [ "$PWB_ACTUAL_SHA" != "$PWB_EXPECTED_SHA" ]; then
  echo "❌ SHA-256 不匹配，拒绝安装"
  exit 1
fi
echo "    SHA-256 校验通过"
if [ "${PWB_VERIFY_ONLY:-0}" = "1" ]; then
  echo "✅ v${PWB_VERSION} 下载与校验链路正常（未安装）"
  exit 0
fi

echo "==> 只读挂载 DMG"
PWB_MOUNT="$(hdiutil attach "$PWB_INSTALL_TMP/app.dmg" -readonly -nobrowse | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
if [ -d "$PWB_MOUNT/ParallelWorkbench.app" ]; then
  PWB_SOURCE_APP="$PWB_MOUNT/ParallelWorkbench.app"
elif [ -d "$PWB_MOUNT/平行工作台.app" ]; then
  PWB_SOURCE_APP="$PWB_MOUNT/平行工作台.app"
else
  echo "❌ DMG 内未找到应用"
  exit 1
fi

PWB_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PWB_SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$PWB_BUNDLE_ID" != "ParallelWorkbench" ]; then
  echo "❌ 安装包 Bundle ID 不符"
  exit 1
fi

echo "==> 原子安装到 /Applications"
rm -rf "$PWB_STAGED" "$PWB_BACKUP"
/usr/bin/ditto "$PWB_SOURCE_APP" "$PWB_STAGED"
if [ ! -x "$PWB_STAGED/Contents/MacOS/ParallelWorkbench" ]; then
  echo "❌ 新版本复制不完整，旧版本未改动"
  exit 1
fi

PWB_HAD_OLD=0
if [ -d "$PWB_DEST" ]; then
  mv "$PWB_DEST" "$PWB_BACKUP"
  PWB_HAD_OLD=1
fi
if ! mv "$PWB_STAGED" "$PWB_DEST"; then
  if [ "$PWB_HAD_OLD" -eq 1 ] && [ -d "$PWB_BACKUP" ]; then mv "$PWB_BACKUP" "$PWB_DEST" || true; fi
  echo "❌ 安装失败，已尝试恢复旧版本"
  exit 1
fi
if [ "$PWB_HAD_OLD" -eq 1 ]; then rm -rf "$PWB_BACKUP"; fi
xattr -dr com.apple.quarantine "$PWB_DEST" 2>/dev/null || true

echo "==> 启动"
open "$PWB_DEST"
echo "✅ v${PWB_VERSION} 已校验、安装并启动"
