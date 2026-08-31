// Edge 扩展端到端测试（macOS 上的 Edge 真机验证，与 Windows 行为一致）
// 前置：Edge 以调试模式运行并加载扩展：
//   pkill -f wb-edge-live; rm -rf /tmp/wb-edge-live
//   "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
//     --user-data-dir=/tmp/wb-edge-live \
//     --disable-extensions-except="$(cd Windows/edge-extension && pwd)" \
//     --load-extension="$(cd Windows/edge-extension && pwd)" \
//     --remote-debugging-port=9223 --no-first-run about:blank &
// 然后：curl -s -X PUT "http://127.0.0.1:9223/json/new?chrome-extension%3A%2F%2F<扩展ID>%2Fworkbench.html"
// 默认只做无副作用回归；显式加 --send 才向文心单个平台发送测试消息。
// 用法：node scripts/edge-e2e.mjs <扩展ID> [--send]
import { readFileSync } from 'node:fs';

const EXT_ID = process.argv[2] || 'eeppnjgcjioaohaaoaknkkafhodccmmf';
const SEND = process.argv.includes('--send');
const PORT = Number(process.env.PWB_EDGE_PORT || 9223);
const BASE = process.env.PWB_BASE || decodeURIComponent(new URL('..', import.meta.url).pathname);
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function cdp(wsUrl, expression) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }));
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.id === 1) { ws.close(); resolve(m.result?.result?.value); }
    };
    ws.onerror = () => reject(new Error('ws error'));
    setTimeout(() => reject(new Error('cdp timeout')), 20000);
  });
}

// 页面创建重试：导航与扩展注册存在竞态（被 blank），重试最多 3 次
let page = null;
for (let attempt = 0; attempt < 3 && !page; attempt++) {
  await fetch(`http://127.0.0.1:${PORT}/json/new?chrome-extension%3A%2F%2F${EXT_ID}%2Fworkbench.html`, { method: 'PUT' }).catch(() => {});
  for (let i = 0; i < 20 && !page; i++) {
    await sleep(1500);
    const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
    page = targets.find(t => t.type === 'page' && t.url.includes('workbench') && !t.url.includes('blocked'));
  }
}
if (!page) { console.log('❌ 工作台页面未就绪（3 次重试后仍被 blank），请检查扩展是否加载'); process.exit(1); }

// 0) 页面就绪轮询（全新 profile 下 5 个重 iframe 加载慢，页面可能尚未渲染完成）
let stable = false;
for (let i = 0; i < 30 && !stable; i++) {
  await sleep(1500);
  const n = parseInt(await cdp(page.webSocketDebuggerUrl, `document.querySelectorAll('.pane').length`) ?? '0');
  stable = n > 0;
}
console.log('页面就绪:', stable);

// 1) UI 对齐检查
const ui = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify({
  checks: document.querySelectorAll('#checks input[type=checkbox]').length,
  visiblePanes: document.querySelectorAll('.pane:not(.offscreen)').length,
  allPanes: document.querySelectorAll('.pane').length,
  pageInd: document.getElementById('page-ind').textContent,
  startupVisible: !!document.getElementById('startup-overlay')
})`));
console.log('UI 对齐:', JSON.stringify(ui));
if (ui.checks < 3 || ui.visiblePanes > 3 || ui.startupVisible) { console.log('❌ UI 初始化失败或加载层未退出'); process.exit(1); }

// 1.1 翻页不得重建任何 iframe 浏览上下文。
const preserved = JSON.parse(await cdp(page.webSocketDebuggerUrl, `(async()=>{
  const ids=['chatgpt','deepseek','kimi','tongyi','yiyan'];
  const refs=Object.fromEntries(ids.map(id=>[id,document.getElementById('frame-'+id).contentWindow]));
  document.getElementById('page-right').click();
  await new Promise(r=>setTimeout(r,150));
  document.getElementById('page-left').click();
  await new Promise(r=>setTimeout(r,150));
  return JSON.stringify(Object.fromEntries(ids.map(id=>[id,refs[id]===document.getElementById('frame-'+id).contentWindow])));
})()`));
console.log('翻页上下文保留:', JSON.stringify(preserved));
if (Object.values(preserved).some(v => !v)) { console.log('❌ 翻页重建了 iframe'); process.exit(1); }

// 2) 探测链路：等待角标更新
await sleep(15000);
const badges = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify([...document.querySelectorAll('.badge')].map(b => b.textContent))`));
console.log('角标:', JSON.stringify(badges));
if (badges.every(b => b === '加载中')) { console.log('❌ 探测无响应'); process.exit(1); }

if (!SEND) {
  console.log('✅ Edge 无副作用回归通过（UI + iframe 保活 + runtime 探测）');
  process.exit(0);
}

// 3) 发送链路：向游客平台（文心）真实发送
// 3.1 取消其他四个平台，只保留文心，避免测试脚本误广播。
await cdp(page.webSocketDebuggerUrl, `(()=>{for(const label of document.querySelectorAll('#checks label')){const cb=label.querySelector('input');if(cb&&cb.checked&&!label.textContent.includes('文心'))cb.click()}return true})()`);
await sleep(2500);
// 3.2 轮询等待文心角标就绪
let ready = false;
for (let i = 0; i < 60 && !ready; i++) {
  await sleep(1500);
  const badges = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify([...document.querySelectorAll('.badge')].map(b => b.textContent))`));
  ready = badges.length === 1 && badges[0] === '就绪';
}
console.log('文心窗格就绪:', ready);
const adapters = JSON.parse(readFileSync(BASE + 'Windows/edge-extension/lib/adapters/index.json', 'utf8'));
const yiyan = adapters.find(a => a.id === 'yiyan');
const text = 'Edge端到端测试：请用一句话介绍你自己';
// 发送前基线：文心帧页面文本量（回答判定需"增长"而非仅气泡存在）
let yfBaseline = null;
{
  const t0 = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
  const yf0 = t0.find(t => t.type === 'iframe' && (t.url.includes('wenxin') || t.url.includes('yiyan')));
  if (yf0) yfBaseline = parseInt(await cdp(yf0.webSocketDebuggerUrl, `(document.body ? document.body.innerText.length : 0)`));
  console.log('发送前文心文本基线:', yfBaseline);
}
await cdp(page.webSocketDebuggerUrl, `(async function(){
  const q = document.getElementById('question');
  const s = document.getElementById('send');
  q.value = ${JSON.stringify(text)};
  q.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 300));
  s.click();
  return 'clicked';
})()`);
console.log('已触发发送，等待回答…');
await sleep(25000);

const targets2 = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const yf = targets2.find(t => t.type === 'iframe' && (t.url.includes('wenxin') || t.url.includes('yiyan')));
if (!yf) { console.log('❌ 文心 iframe 不存在'); process.exit(1); }
const bubble = JSON.parse(await cdp(yf.webSocketDebuggerUrl, `(function(){
  const q = 'Edge端到端测试';
  const composer = document.querySelector('[contenteditable="true"], textarea');
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let n, found = false;
  while ((n = walker.nextNode())) { if (n.textContent.includes(q)) { if (composer && composer.contains(n)) continue; found = true; break; } }
  return JSON.stringify({
    bubble: found,
    composerTag: composer ? composer.tagName : null,
    composerValue: composer ? String(composer.value || composer.textContent || '').slice(0, 60) : null,
    bodyLen: document.body ? document.body.innerText.length : -1
  });
})()`));
console.log('消息气泡:', JSON.stringify(bubble));
if (!bubble.bubble) { console.log('❌ 消息未进入对话区'); process.exit(1); }
// 回答增长判定：页面文本必须比发送前增长（排除仅气泡存在、无回答的假阳性）
const grew = bubble.bodyLen - (yfBaseline ?? 0);
console.log('文本增长:', grew);
if (yfBaseline != null && grew < 20) { console.log('❌ 未观察到回答增长'); process.exit(1); }
console.log('✅ Edge 端到端测试全部通过（UI 对齐 + 探测 + 发送 + 回答增长）');
process.exit(0);
