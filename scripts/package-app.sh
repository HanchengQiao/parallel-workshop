#!/bin/bash
# 打包 ParallelWorkbench.app（未签名，本地/信任来源分发用）
# 用法: bash scripts/package-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ParallelWorkbench.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 release 版（Apple 芯片 + Intel 通用）"
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM=".build/arm64-apple-macosx/release/ParallelWorkbench"
X64=".build/x86_64-apple-macosx/release/ParallelWorkbench"
if [ ! -f "$ARM" ]; then
  echo "❌ release 二进制缺失: $ARM"
  exit 1
fi
if [ -f "$X64" ]; then
  echo "==> 合并通用二进制（arm64 + x86_64）"
  lipo -create "$ARM" "$X64" -output "$ARM.universal"
  mv "$ARM.universal" "$ARM"
  lipo -info "$ARM"
fi
cp "$ARM" "$APP/Contents/MacOS/ParallelWorkbench"
chmod +x "$APP/Contents/MacOS/ParallelWorkbench"

echo "==> 复制资源 bundle"
for b in .build/arm64-apple-macosx/release/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

echo "==> 生成图标"
if [ ! -f "build/AppIcon.icns" ]; then
  swift scripts/icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>平行工作台</string>
	<key>CFBundleDisplayName</key>
	<string>平行工作台</string>
	<key>CFBundleExecutable</key>
	<string>ParallelWorkbench</string>
	<key>CFBundleIdentifier</key>
	<string>ParallelWorkbench</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>用于将你的语音转成文字并填入提问输入框</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>用于语音输入提问</string>
</dict>
</plist>
PLIST

echo ""
echo "✅ 已生成 ${APP}（未签名，仅限本机或信任来源使用）"
echo "   双击运行：open \"${APP}\""
