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

// 模拟扩展环境
window.chrome = { runtime: { getURL: (p) => 'chrome-extension://x/' + p } };
window.fetch = async (url) => ({ text: async () => String(url).includes('inject.js') ? injectSrc : probeSrc });

const results = [];
window.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'WB_RESULT') results.push(e.data);
});

window.eval(readFileSync(base + '/Windows/edge-extension/content.js', 'utf8'));
await new Promise(r => setTimeout(r, 400));

// 注入请求
const cfg = { input: { selectors: ['#react-input'] }, send: { type: 'enter' }, text: '扩展自检123' };
window.dispatchEvent(new window.MessageEvent('message', {
  data: { type: 'WB_INJECT', frameId: 'test', tok: 'glue-test', cfg },
  source: window,
  origin: 'chrome-extension://x'
}));
await new Promise(r => setTimeout(r, 2500));

const r = results.find(x => x.frameId === 'test');
console.log('注入结果:', JSON.stringify(r?.result));
const pass = r && r.result && r.result.ok === true
  && window.__log.reactValue === cfg.text
  && window.__log.reactEnter === true;
console.log(pass ? '✅ content.js 胶水层通过（模板拉取→注入→回传）' : '❌ content.js 失败');
process.exit(pass ? 0 : 1);
