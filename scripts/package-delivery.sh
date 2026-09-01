#!/bin/bash
# 完整交付包打包：macOS 应用（通用二进制）+ Windows/Edge 扩展 + 源代码 + 产品说明文档
# 用法：bash scripts/package-delivery.sh X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?用法: bash scripts/package-delivery.sh X.Y.Z}"

echo "==> 1/5 打包 macOS 应用（通用二进制）"
VERSION="$V" bash scripts/package-app.sh >/dev/null 2>&1
echo "    ✅ build/ParallelWorkbench.app"
VERSION="$V" bash scripts/package-dmg.sh >/dev/null
echo "    ✅ build/ParallelWorkbench-${V}.dmg"

echo "==> 2/5 打包 Edge 扩展"
bash scripts/build-edge-extension.sh >/dev/null 2>&1
echo "    ✅ build/edge-extension.zip"

echo "==> 3/5 组装交付目录"
STAGE="build/delivery/平行工作台-v${V}"
rm -rf "$STAGE"
mkdir -p "$STAGE/macOS" "$STAGE/Windows" "$STAGE/源代码"

# macOS
cp -R build/ParallelWorkbench.app "$STAGE/macOS/"
if [ -f "build/ParallelWorkbench-${V}.dmg" ]; then
  cp "build/ParallelWorkbench-${V}.dmg" "$STAGE/macOS/"
fi

# Windows/Edge
cp build/edge-extension.zip "$STAGE/Windows/"
mkdir -p "$STAGE/Windows/edge-extension"
(cd Windows/edge-extension && tar --exclude='_metadata' --exclude='.DS_Store' -cf - .) | (cd "$STAGE/Windows/edge-extension" && tar -xf -)

# 源代码（排除构建产物）
rsync -a --exclude '.build' --exclude 'node_modules' --exclude '.tester-bin' --exclude 'test-output' \
  --exclude '.DS_Store' --exclude 'build' --exclude '__pycache__' \
  Sources scripts Windows/edge-extension Package.swift README.md DELIVERY.md RELEASE.md install.sh LICENSE \
  homebrew npm-launcher .gitignore "$STAGE/源代码/" 2>/dev/null || \
  (cd "$(pwd)" && tar --exclude='.build' --exclude='node_modules' --exclude='.tester-bin' --exclude='test-output' --exclude='.DS_Store' --exclude='build' --exclude='__pycache__' -cf - Sources scripts Windows/edge-extension Package.swift README.md DELIVERY.md RELEASE.md install.sh LICENSE homebrew npm-launcher .gitignore | (cd "$STAGE/源代码" && tar -xf -))

# 主文档（单独文件）
cp "交付说明/产品说明与代码解读.md" "$STAGE/产品说明与代码解读.md"
cp README.md "$STAGE/README.md" 2>/dev/null || true

echo "==> 4/5 生成交付 zip"
rm -f "build/平行工作台-v${V}-交付包.zip"
(cd build/delivery && zip -rq "../平行工作台-v${V}-交付包.zip" "平行工作台-v${V}")
echo "==> 5/5 完成"
ls -lh "build/平行工作台-v${V}-交付包.zip"
echo ""
echo "交付包内容："
(cd "$STAGE" && find . -maxdepth 2 | head -20)
