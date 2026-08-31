#!/bin/bash
# 一键安装平行工作台（CLI 下载 → 自动安装到 /Applications → 启动）
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/<你的用户>/<仓库>/main/install.sh | bash
# 或本地：
#   bash install.sh
set -euo pipefail

REPO="${PARALLEL_WORKBENCH_REPO:-HanchengQiao/parallel-workshop}"
# 未指定版本时自动拉取 GitHub Releases 最新版（下载即最新）
VERSION="${PARALLEL_WORKBENCH_VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "0.1.0")"
fi
URL="https://github.com/${REPO}/releases/download/v${VERSION}/ParallelWorkbench-${VERSION}.dmg"

echo "==> 下载 $URL"
TMP="$(mktemp -d)"
curl -fL --progress-bar -o "$TMP/app.dmg" "$URL"

echo "==> 挂载 DMG"
MOUNT="$(hdiutil attach "$TMP/app.dmg" -nobrowse | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"

if [ -d "$MOUNT/ParallelWorkbench.app" ]; then
  SRC="$MOUNT/ParallelWorkbench.app"
elif [ -d "$MOUNT/平行工作台.app" ]; then
  SRC="$MOUNT/平行工作台.app"
else
  echo "❌ DMG 内未找到应用"
  hdiutil detach "$MOUNT" > /dev/null || true
  exit 1
fi

echo "==> 安装到 /Applications"
rm -rf "/Applications/ParallelWorkbench.app"
cp -R "$SRC" "/Applications/ParallelWorkbench.app"
# 开源未签名分发：安装时移除下载隔离属性（与 Homebrew cask 同机制，用户主动执行本脚本即视为知情同意）
xattr -dr com.apple.quarantine "/Applications/ParallelWorkbench.app" 2>/dev/null || true

hdiutil detach "$MOUNT" > /dev/null
rm -rf "$TMP"

echo "==> 启动"
open "/Applications/ParallelWorkbench.app"
echo "✅ 安装完成并已启动"
