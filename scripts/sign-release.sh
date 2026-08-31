#!/bin/bash
# 签名 + 公证（对外分发必需，否则其他 Mac 会被 Gatekeeper 拦截）
# 前置：Apple Developer Program 账号（$99/年）
# 环境变量：
#   DEVELOPER_ID_APPLICATION  "Developer ID Application" 证书名
#   APPLE_ID                  Apple 账号邮箱
#   APPLE_TEAM_ID             团队 ID（developer.apple.com → Membership）
#   APP_APP_PASSWORD          App 专用密码（appleid.apple.com 生成）
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID_APPLICATION:?请设置 DEVELOPER_ID_APPLICATION}"
: "${APPLE_ID:?请设置 APPLE_ID}"
: "${APPLE_TEAM_ID:?请设置 APPLE_TEAM_ID}"
: "${APP_APP_PASSWORD:?请设置 APP_APP_PASSWORD}"

APP="build/ParallelWorkbench.app"
bash scripts/package-app.sh > /dev/null

echo "==> 代码签名（Developer ID + 硬化运行时）"
codesign --deep --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"

echo "==> 提交公证（数分钟内完成）"
rm -f build/notarize.zip
ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APP_APP_PASSWORD" --wait

echo "==> 装订公证票据"
xcrun stapler staple "$APP"

echo "✅ 签名公证完成。运行 scripts/package-dmg.sh 生成分发 DMG"
