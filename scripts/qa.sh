#!/bin/bash
# 一键质量门禁：构建 + 注入核心自检 + 扩展构建校验 + 胶水层冒烟测试
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0

echo "==> 1/4 Swift 构建"
swift build --arch arm64 2>&1 | tail -1 || { echo "❌ 构建失败"; exit 1; }

# 刷新测试器副本（SelfTest 等 Swift 代码编译进二进制，必须同步；inject.js 运行时从资源加载。
# 注意目标可执行名是 WorkbenchTester；改名保持单实例守护的进程名约定）
mkdir -p .tester-bin
cp -f .build/arm64-apple-macosx/debug/WorkbenchTester .tester-bin/ParallelWorkbench

echo "==> 2/4 注入核心自检（本地夹具，不触网）"
.tester-bin/ParallelWorkbench --selftest || FAIL=1

echo "==> 3/4 Edge 扩展构建与校验"
bash scripts/build-Windows/edge-extension.sh > /dev/null
for f in Windows/edge-extension/*.js Windows/edge-extension/lib/*.js; do
  node --check "$f" || FAIL=1
done
for f in Windows/edge-extension/manifest.json Windows/edge-extension/rules.json Windows/edge-extension/lib/adapters/index.json; do
  python3 -m json.tool "$f" > /dev/null || FAIL=1
done
echo "    语法与 JSON 校验通过"

echo "==> 4/4 扩展胶水层 jsdom 冒烟测试"
if (cd scripts && node -e "require.resolve('jsdom')" > /dev/null 2>&1); then
  node scripts/ext-glue-test.mjs || FAIL=1
else
  echo "❌ jsdom 未安装（cd scripts && npm i jsdom）——胶水层验证为必测项"
  FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✅ QA 门禁全部通过"
else
  echo "❌ QA 门禁存在失败项"
fi
exit $FAIL
