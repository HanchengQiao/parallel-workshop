import { readFileSync } from 'node:fs';

const root = decodeURIComponent(process.env.BASE || new URL('..', import.meta.url).pathname);
const fail = [];
const requireText = (condition, message) => { if (!condition) fail.push(message); };
const readBuffer = (path) => readFileSync(`${root}/${path}`);
const read = (path) => readBuffer(path).toString('utf8').replace(/^\uFEFF/, '');

const psFiles = [
  'install-windows.ps1',
  'Windows/edge-extension/install.ps1',
  'Windows/edge-extension/launch.ps1',
];

for (const path of psFiles) {
  const bytes = readBuffer(path);
  const source = read(path);
  requireText(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf,
    `${path} 必须带 UTF-8 BOM，确保 Windows PowerShell 5.1 正确读取中文`);
  requireText(source.includes('Set-StrictMode -Version 2.0') && source.includes("$ErrorActionPreference = 'Stop'"),
    `${path} 缺少严格错误处理`);
  for (const ps7Only of ['??', '?.', 'ForEach-Object -Parallel', 'ConvertFrom-Json -AsHashtable']) {
    requireText(!source.includes(ps7Only), `${path} 使用了 Windows PowerShell 5.1 不支持的语法：${ps7Only}`);
  }
}

const bootstrap = read('install-windows.ps1');
requireText(bootstrap.includes('/releases/latest'), '固定入口必须读取最新稳定 Release');
requireText(!/releases\/download\/v?\d/.test(bootstrap), '固定入口不得硬编码下载版本号');
requireText(bootstrap.includes("$_.name -eq 'edge-extension.zip'"), '固定入口必须精确选择用户安装包');
requireText(bootstrap.includes('Invoke-WithRetry') && bootstrap.includes('Get-FileHash'),
  '固定入口缺少重试或 SHA-256 强校验');
requireText(bootstrap.includes('$release.draft -or $release.prerelease'), '固定入口未拒绝草稿或预发布版本');
requireText(bootstrap.includes('Expand-Archive -LiteralPath'), '固定入口没有安全处理含空格的压缩包路径');
requireText(bootstrap.includes('[switch]$VerifyOnly') && bootstrap.includes('[switch]$NoLaunch') &&
  bootstrap.includes('[switch]$NoShortcuts'), '固定入口缺少无人值守/仅验证参数');

const installer = read('Windows/edge-extension/install.ps1');
requireText(installer.includes("GetFolderPath('LocalApplicationData')"), '默认安装位置必须是当前用户目录');
requireText(!/Start-Process[^\n]+-Verb\s+RunAs/i.test(installer) && !/net\s+session/i.test(installer),
  '安装器不得请求管理员权限');
requireText(installer.includes("[Guid]::NewGuid().ToString('N')") &&
  installer.includes('.edge-extension.new-') && installer.includes('.edge-extension.old-'),
  '安装器必须使用并发安全的同卷暂存/备份目录');
requireText(installer.includes('Test-IsSameOrChildPath $originalLocation $target') &&
  installer.includes('Set-Location -LiteralPath $targetRootFull'),
  '安装器未处理从已安装目录内执行更新的 Windows 目录锁');
requireText(installer.includes("$_.Name -ne '_metadata'"), '安装器必须剔除 Edge 的陈旧 _metadata 缓存');
requireText(installer.includes('恢复旧版本') && installer.includes('已保留原版本'), '原子替换失败时缺少回滚');
requireText(installer.includes('FromBase64String') && installer.includes('$derivedID -ne $expectedExtensionID'),
  '安装器必须校验 manifest 公钥确实导出固定扩展 ID');
requireText(installer.includes('$shortcut.TargetPath = $edgePath') &&
  installer.includes('$shortcut.Arguments = "--app=$workbenchURL"'),
  '快捷方式应直接启动 Edge 应用窗口，避免 PowerShell 窗口和 blank 预热');
requireText(!installer.includes('--user-data-dir'), '安装/启动不得切换 Edge 用户数据目录');

const launcher = read('Windows/edge-extension/launch.ps1');
requireText(launcher.includes('chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html'),
  '启动器必须指向固定侧载扩展 ID');
requireText(launcher.includes('Start-Process -FilePath $edge -ArgumentList "--app=$workbenchURL"'),
  '启动器必须直接打开应用窗口');
requireText(!launcher.includes('about:blank') && !launcher.includes('--user-data-dir') && !launcher.includes('Start-Sleep'),
  '启动器不得包含 blank 预热、独立 profile 或固定等待');

for (const path of ['Windows/edge-extension/install.bat', 'Windows/edge-extension/launch.bat']) {
  const bat = read(path);
  const psName = path.endsWith('install.bat') ? 'install.ps1' : 'launch.ps1';
  requireText(bat.includes(`-File "%~dp0${psName}" %*`), `${path} 未安全传递含空格路径和参数`);
  requireText(/exit \/b %ERRORLEVEL%/i.test(bat), `${path} 未向 Agent 返回真实退出码`);
  requireText(!/\bpause\b/i.test(bat) && !/\btimeout\b/i.test(bat), `${path} 不得阻塞或固定等待`);
}

const workflow = read('.github/workflows/ci.yml');
requireText(workflow.includes('runs-on: windows-latest') && workflow.includes('shell: powershell'),
  'CI 必须使用 Windows PowerShell 5.1 真机解析和安装');
requireText(workflow.includes('测试 用户\\Parallel Workbench'), 'CI 未覆盖中文与空格路径');
requireText(workflow.includes('source-in-target update'), 'CI 未覆盖从安装目录重复更新');
requireText(workflow.includes('Verify bounded fixed bootstrap command') &&
  workflow.includes('--retry-max-time 90 --connect-timeout 10 --max-time 60'),
  'CI 未执行带超时和重试上限的固定下载入口');

for (const path of ['README.md', 'Windows/README.md', 'Windows/edge-extension/README.md',
  'Windows/edge-extension/WINDOWS.md', 'AGENT_INSTALL_PROMPT.md']) {
  const doc = read(path);
  requireText(doc.includes("$pwbInstaller = Join-Path $env:TEMP ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N')") &&
    doc.includes('& curl.exe --fail --location --silent --show-error --retry 3') &&
    doc.includes('--connect-timeout 10 --max-time 60') &&
    doc.includes('releases/latest/download/install-windows.ps1') &&
    doc.includes('& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pwbInstaller'),
  `${path} 未使用可从现有 PowerShell 正确执行的固定 Latest 命令`);
  requireText(!doc.includes('raw.githubusercontent.com/porcelaintech/parallel-workshop/main/install-windows.ps1'),
    `${path} 仍从 main 取引导器，可能与 Latest Release 资产错配`);
  requireText(doc.includes('Remove-Item -LiteralPath $pwbInstaller -Force -ErrorAction SilentlyContinue'),
    `${path} 的固定入口没有清理一次性引导脚本`);
  requireText(!doc.includes('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p='),
    `${path} 仍含会被外层 PowerShell 提前展开变量的旧命令`);
}

const releaseScript = read('scripts/make-release.sh');
requireText(releaseScript.includes('"install-windows.ps1"') &&
  releaseScript.includes('SHA256 install-windows.ps1'),
  '发布脚本没有把与 Release 同步的 Windows 引导器作为 Latest 资产上传');

if (fail.length) {
  console.error(`❌ Windows 安装契约失败：\n- ${fail.join('\n- ')}`);
  process.exit(1);
}

console.log('✅ Windows 安装契约通过（PS 5.1 编码/最新版/校验/原子安装/路径/启动）');
