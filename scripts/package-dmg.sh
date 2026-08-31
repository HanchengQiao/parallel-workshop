#!/bin/bash
# 生成分发包 DMG（用户下载 → 拖入 Applications → 双击即用）
# 依赖：scripts/package-app.sh 产物 build/ParallelWorkbench.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ParallelWorkbench.app"
[ -d "$APP" ] || bash scripts/package-app.sh > /dev/null

STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

: "${VERSION:?请通过 VERSION=X.Y.Z 指定 DMG 版本}"
DMG="build/ParallelWorkbench-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "平行工作台" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

echo "✅ DMG 已生成：$DMG"
echo "   用户安装：打开 DMG → 把「平行工作台」拖进 Applications → 双击运行"
