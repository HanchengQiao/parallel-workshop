import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';

const base = decodeURIComponent(process.env.BASE || new URL('..', import.meta.url).pathname);
const injectSrc = readFileSync(base + '/Windows/edge-extension/lib/inject.js', 'utf8');
const probeSrc = readFileSync(base + '/Windows/edge-extension/lib/probe.js', 'utf8');

const dom = new JSDOM(readFileSync(base + '/Sources/WorkbenchTester/fixture.html', 'utf8'), {
  runScripts: 'dangerously',
  url: 'https://www.kimi.com/'
});
const { window } = dom;

// 模拟 chrome.tabs.sendMessage → content script 的不可被页面主世界拦截的 runtime 通道。
let runtimeListener = null;
window.chrome = {
  runtime: {
    id: 'x',
    getURL: (p) => 'chrome-extension://x/' + p,
    onMessage: { addListener: (listener) => { runtimeListener = listener; } }
  }
};

window.eval(readFileSync(base + '/Windows/edge-extension/content.js', 'utf8'));
await new Promise(r => setTimeout(r, 400));

if (!runtimeListener) throw new Error('content.js 未注册 runtime.onMessage');

// 非工作台发送者必须被拒绝。
const cfg = { input: { selectors: ['#react-input'] }, send: { type: 'enter' }, text: '扩展自检123' };
let forgedReply = false;
const forgedAccepted = runtimeListener(
  { type: 'WB_INJECT', frameId: 'test', cfg },
  { id: 'x', url: 'https://www.kimi.com/' },
  () => { forgedReply = true; }
);

const r = await new Promise((resolve) => {
  const keepAlive = runtimeListener(
    { type: 'WB_INJECT', frameId: 'test', rid: 'r1', cfg },
    { id: 'x', url: 'chrome-extension://x/workbench.html' },
    resolve
  );
  if (keepAlive !== true) throw new Error('异步 runtime listener 未保持消息通道');
});

console.log('注入结果:', JSON.stringify(r?.result));
const pass = r && r.result && r.result.ok === true
  && forgedAccepted === false && forgedReply === false
  && window.__log.reactValue === cfg.text
  && window.__log.reactEnter === true;
console.log(pass ? '✅ content.js runtime 胶水层通过（可信发送者→注入→直接回执）' : '❌ content.js 失败');
process.exit(pass ? 0 : 1);
