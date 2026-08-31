import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const source = readFileSync(base + 'Windows/edge-extension/background.js', 'utf8');

async function runCase(tab) {
  const calls = [];
  let actionListener = null;
  const chrome = {
    runtime: {
      id: 'test-extension',
      getURL: path => `chrome-extension://test-extension/${path}`,
      onMessage: { addListener() {} },
      get lastError() { return null; }
    },
    action: { onClicked: { addListener(listener) { actionListener = listener; } } },
    tabs: {
      update: async (id, options) => { calls.push(['tabs.update', id, options]); },
      onRemoved: { addListener() {} }
    },
    windows: {
      update: async (id, options) => { calls.push(['windows.update', id, options]); },
      create: async options => { calls.push(['windows.create', options]); }
    },
    storage: { session: { get: async () => ({}), set: async () => {}, remove: async () => {} } },
    declarativeNetRequest: { updateSessionRules: async () => {} },
    debugger: { attach() {}, detach() {}, sendCommand() {} }
  };
  runInNewContext(source, { chrome, URL, Set, Number, Promise, setTimeout, clearTimeout, console });
  if (typeof actionListener !== 'function') throw new Error('action listener 未注册');
  actionListener(tab);
  await new Promise(resolve => setTimeout(resolve, 0));
  await new Promise(resolve => setTimeout(resolve, 0));
  return calls;
}

for (const url of ['about:blank', 'edge://newtab/', 'edge://new-tab-page/', 'chrome://newtab/', 'chrome://new-tab-page/']) {
  const calls = await runCase({ id: 7, windowId: 3, url });
  if (calls.filter(call => call[0] === 'tabs.update').length !== 1 || calls.some(call => call[0] === 'windows.create')) {
    throw new Error(`${url} 未被原地复用：${JSON.stringify(calls)}`);
  }
}

const normalCalls = await runCase({ id: 8, windowId: 4, url: 'https://example.com/' });
if (normalCalls.filter(call => call[0] === 'windows.create').length !== 1 || normalCalls.some(call => call[0] === 'tabs.update')) {
  throw new Error(`普通页面不应被覆盖：${JSON.stringify(normalCalls)}`);
}

console.log('✅ Edge 工具栏启动策略通过（空白页原地复用；普通页面独立打开）');
