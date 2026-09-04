#!/bin/bash
# 生成分发包 DMG（用户下载 → 拖入 Applications → 双击即用）
# 依赖：scripts/package-app.sh 产物 build/ParallelWorkbench.app
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?请通过 VERSION=X.Y.Z 指定 DMG 版本}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ 无效版本号: $VERSION"; exit 1; }
APP="build/ParallelWorkbench.app"
[ -d "$APP" ] || VERSION="$VERSION" bash scripts/package-app.sh > /dev/null
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || {
  echo "❌ App 版本与 DMG 文件名不一致：App=$APP_VERSION DMG=$VERSION"
  exit 1
}

STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="build/ParallelWorkbench-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "平行工作台" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

echo "✅ DMG 已生成：$DMG"
echo "   用户安装：打开 DMG → 把「平行工作台」拖进 Applications → 双击运行"
