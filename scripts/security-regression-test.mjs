import { readFileSync } from 'node:fs';

const base = decodeURIComponent(process.env.BASE || new URL('..', import.meta.url).pathname);
const read = (path) => readFileSync(base + '/' + path, 'utf8');
const fail = [];
const requireText = (condition, message) => { if (!condition) fail.push(message); };

const workbench = read('Windows/edge-extension/workbench.js');
const content = read('Windows/edge-extension/content-template.js');
const background = read('Windows/edge-extension/background.js');
const launcher = read('Windows/edge-extension/launch.bat');
const intercept = read('Windows/edge-extension/intercept.js');
const manifest = JSON.parse(read('Windows/edge-extension/manifest.json'));
const qa = read('scripts/qa.sh');
const delivery = read('scripts/package-delivery.sh');
const release = read('scripts/make-release.sh');
const updaterCaller = read('Sources/ParallelWorkbench/WorkbenchModel.swift');
const installer = read('install.sh');
const workbenchHTML = read('Windows/edge-extension/workbench.html');

const layoutBody = workbench.match(/function layoutPanes\(\)[\s\S]*?\n  }\n\n  function renderPanes/)?.[0] || '';
requireText(layoutBody && !layoutBody.includes('appendChild'), 'layoutPanes 仍会重挂 iframe DOM');
requireText(workbench.includes('chrome.tabs.sendMessage'), '工作台未迁移到 chrome.tabs.sendMessage');
requireText(!workbench.includes('paneTokens'), '仍保留页面可见 pane token');
requireText(!content.includes("window.addEventListener('message'"), '问答 content script 仍接收 window.postMessage');
requireText(content.includes('chrome.runtime.onMessage.addListener'), 'content script 未注册 runtime 通道');
requireText(background.includes('WB_AUTH_CALLBACK_CANDIDATE'), '后台缺少认证 callback 校验');
requireText(!background.includes("url: 'about:blank'") && !background.includes('chrome.tabs.update'),
  '工具栏启动仍通过 blank 窗口二次导航');
requireText(!launcher.includes('--no-startup-window') && !/timeout\s+\/t/i.test(launcher) && launcher.includes('--app='),
  'Windows 启动器仍包含 blank 预热或固定延迟');
requireText(workbenchHTML.includes('startup-overlay') && workbench.includes("startupOverlay?.classList.add('done')"),
  '工作台缺少可见加载状态或初始化完成收口');
requireText(intercept.includes('DEEPSEEK_WECHAT_CALLBACK'), '微信 MAIN world 缺少 callback 捕获');

const authBridge = manifest.content_scripts?.find(item => item.js?.includes('auth-bridge.js'));
requireText(!!authBridge && authBridge.world === 'ISOLATED', 'auth-bridge.js 未以隔离世界注册');
requireText(!manifest.declarative_net_request, 'manifest 仍启用了依赖固定扩展 ID 的静态 DNR');
requireText(background.includes('updateSessionRules') && background.includes('tabIds'),
  'DNR 未迁移到按工作台 tabId 限定的 session rule');

for (const [name, source] of [['qa.sh', qa], ['package-delivery.sh', delivery], ['make-release.sh', release]]) {
  requireText(!source.includes('build-Windows/edge-extension.sh'), `${name} 仍引用错误脚本路径`);
}
requireText(qa.includes('build-edge-extension.sh > /dev/null || FAIL=1'), 'QA 未记录扩展构建失败');
requireText(updaterCaller.includes('expectedSHA256: rel.dmgSHA256'), 'macOS 更新调用未传递 SHA-256');
requireText(installer.includes('SHA-256 校验通过') && installer.includes('shasum -a 256'),
  'install.sh 未强制校验 SHA-256');
requireText(installer.includes('当前没有可安装的稳定 Release'), 'install.sh 缺少无稳定版本的明确错误提示');

if (fail.length) {
  console.error('❌ 安全回归失败：\n- ' + fail.join('\n- '));
  process.exit(1);
}
console.log('✅ 安全回归通过（认证桥/runtime 通道/DNR/iframe/更新器/流水线）');
