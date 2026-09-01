#!/usr/bin/env node
// npm 启动器草案：已安装则启动；未安装时复用仓库的强校验 install.sh。
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');

const REPO = process.env.PARALLEL_WORKBENCH_REPO || 'porcelaintech/parallel-workshop';
const APP = '/Applications/ParallelWorkbench.app';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} 退出码 ${result.status}`);
}

function main() {
  if (process.platform !== 'darwin') {
    throw new Error('当前仅支持 macOS。Windows 请使用 Release 中的 Edge 扩展。');
  }
  if (fs.existsSync(APP)) {
    run('/usr/bin/open', [APP]);
    console.log('已启动平行工作台');
    return;
  }

  const installerURL = `https://raw.githubusercontent.com/${REPO}/main/install.sh`;
  const download = spawnSync('/usr/bin/curl', ['-fsSL', installerURL], { encoding: 'utf8' });
  if (download.error) throw download.error;
  if (download.status !== 0 || !download.stdout) throw new Error('下载安装脚本失败');
  run('/bin/bash', [], {
    input: download.stdout,
    stdio: ['pipe', 'inherit', 'inherit'],
    env: { ...process.env, PARALLEL_WORKBENCH_REPO: REPO }
  });
}

try {
  main();
} catch (error) {
  console.error('❌ ' + error.message);
  process.exit(1);
}
