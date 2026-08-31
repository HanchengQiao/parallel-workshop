#!/usr/bin/env node
// parallel-workbench CLI 启动器（npm 分发，仿 dsh 体验）：
//   npx parallel-workbench            # 已安装则直接启动
//   首次运行自动从 GitHub Releases 下载 DMG → 安装到 /Applications → 启动
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPO = process.env.PARALLEL_WORKBENCH_REPO || 'HanchengQiao/parallel-workshop';
const VERSION = process.env.PARALLEL_WORKBENCH_VERSION || '0.2.0';
const APP = '/Applications/ParallelWorkbench.app';

function sh(cmd) {
  return execSync(cmd, { stdio: 'inherit' });
}

async function main() {
  if (process.platform !== 'darwin') {
    console.error('当前仅支持 macOS。Windows 请使用 Edge 扩展：见仓库 edge-extension/WINDOWS.md');
    process.exit(1);
  }

  if (fs.existsSync(APP)) {
    sh('open ' + JSON.stringify(APP));
    console.log('已启动平行工作台');
    return;
  }

  const url = `https://github.com/${REPO}/releases/download/v${VERSION}/ParallelWorkbench-${VERSION}.dmg`;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pwb-'));
  const dmg = path.join(tmp, 'app.dmg');
  console.log('首次运行，下载 ' + url);
  sh(`curl -fL --progress-bar -o "${dmg}" "${url}"`);

  const out = execSync(`hdiutil attach "${dmg}" -nobrowse`).toString();
  const m = out.match(/\/Volumes\/[^\n]+/);
  const mount = m ? m[0].trim() : null;
  if (!mount) throw new Error('DMG 挂载失败');

  const src = fs.existsSync(path.join(mount, 'ParallelWorkbench.app'))
    ? path.join(mount, 'ParallelWorkbench.app')
    : path.join(mount, '平行工作台.app');

  sh(`rm -rf "${APP}"`);
  sh(`cp -R "${src}" "${APP}"`);
  try { sh(`xattr -dr com.apple.quarantine "${APP}"`); } catch {}
  sh(`hdiutil detach "${mount}"`);
  fs.rmSync(tmp, { recursive: true, force: true });

  sh('open ' + JSON.stringify(APP));
  console.log('✅ 安装并启动完成');
}

main().catch((e) => {
  console.error('❌ ' + e.message);
  process.exit(1);
});
