#!/bin/bash
# 发布到 GitHub Releases（前置：brew install gh && gh auth login；仓库已推到 GitHub）
# 流程：统一版本号 → 构建产物 → QA 门禁（失败即中止）→ 生成 SHA256 清单 → 打 tag → 发布（draft，需人工确认转正）
# 用法：bash scripts/make-release.sh X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: bash scripts/make-release.sh X.Y.Z}"
TAG="v${VERSION}"
REPO="porcelaintech/parallel-workshop"

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区不干净，发布前请先提交或清理改动"
  exit 1
fi

echo "==> 统一版本号 $VERSION（扩展/npm/Info.plist/cask）"
bash scripts/bump-version.sh "$VERSION"
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 版本文件已更新。请审阅并提交这些变更，然后重新运行发布脚本"
  git status --short
  exit 2
fi

echo "==> 构建产物"
VERSION="$VERSION" bash scripts/package-app.sh > /dev/null
VERSION="$VERSION" bash scripts/package-dmg.sh > /dev/null
bash scripts/build-edge-extension.sh > /dev/null

echo "==> QA 门禁（失败即中止）"
bash scripts/qa.sh

echo "==> 生成 SHA256 清单（写入 Release Notes，供更新器校验）"
DMG_SHA=$(shasum -a 256 "build/ParallelWorkbench-${VERSION}.dmg" | awk '{print $1}')
ZIP_SHA=$(shasum -a 256 "build/edge-extension.zip" | awk '{print $1}')
NOTES="平行工作台 v${VERSION}（macOS DMG + Edge 扩展）

安装方式：
- macOS：curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash
- Windows：下载 edge-extension.zip 解压后按 WINDOWS.md 侧载

校验和（macOS 更新器自动强校验）：
SHA256 ParallelWorkbench-${VERSION}.dmg ${DMG_SHA}
SHA256 edge-extension.zip ${ZIP_SHA}"

echo "==> 打 tag（要求工作区干净，防止 tag 与构建提交不一致）"
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 构建或 QA 改写了工作区，拒绝发布"
  exit 1
fi
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "==> 创建 draft Release（确认后转正：gh release edit $TAG --draft=false）"
gh release create "$TAG" \
  "build/ParallelWorkbench-${VERSION}.dmg" \
  "build/edge-extension.zip" \
  --title "平行工作台 ${VERSION}" \
  --notes "$NOTES" \
  --draft --verify-tag -R "$REPO"

echo "✅ Draft Release 已创建：${REPO}/releases/tag/${TAG}"
echo "   请确认无误后执行：gh release edit ${TAG} --draft=false"
