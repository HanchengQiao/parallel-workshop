// 逐平台附件注入接受度矩阵（通道级验证，不发送真实消息）：
// - input 平台（适配器有文件输入框选择器）：WB_INJECT noSend 文件赋值路径
// - cdp 平台（无选择器）：WB_ATTACH CDP 拖放路径
// 证据：drop 事件监听（files/name/trusted）、帧 body 是否出现文件名（平台接受并展示上传卡）、
//       document.hasFocus()（检测点击 openSelector 是否弹出了原生文件对话框）。
// 前置：Edge 以 --load-extension=Windows/edge-extension --remote-debugging-port=9223 运行（见 edge-e2e.mjs）。
// 用法：node scripts/edge-attach-matrix.mjs [扩展ID] [--full]
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const EXT_ID = process.argv[2] || 'eeppnjgcjioaohaaoaknkkafhodccmmf';
const FULL = process.argv.includes('--full');
const PORT = 9223;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

const B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

async function cdp(wsUrl, expression, timeoutMs = 20000, attempts = 3) {
  let lastErr;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await new Promise((resolve, reject) => {
        const ws = new WebSocket(wsUrl);
        const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error('cdp timeout')); }, timeoutMs);
        ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }));
        ws.onmessage = (e) => {
          const m = JSON.parse(e.data);
          if (m.id === 1) {
            clearTimeout(timer);
            try { ws.close(); } catch {}
            if (m.error) reject(new Error(JSON.stringify(m.error)));
            else resolve(m.result?.result?.value);
          }
        };
        ws.onerror = () => { clearTimeout(timer); reject(new Error('ws error')); };
      });
    } catch (e) { lastErr = e; await sleep(1200); }
  }
  throw lastErr;
}

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const adaptersDir = join(root, 'Windows/edge-extension', 'lib', 'adapters');
const adapters = readdirSync(adaptersDir).filter(f => f.endsWith('.json') && f !== 'index.json')
  .map(f => JSON.parse(readFileSync(join(adaptersDir, f), 'utf8')));
const byId = Object.fromEntries(adapters.map(a => [a.id, a]));
console.log(`适配器: ${adapters.map(a => a.id).join(', ')}`);

// —— 1. 工作台页面 ——
let page = null;
{
  const ts = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
  page = ts.find(t => t.type === 'page' && t.url.includes('workbench'));
}
if (!page) {
  await fetch(`http://127.0.0.1:${PORT}/json/new?chrome-extension%3A%2F%2F${EXT_ID}%2Fworkbench.html`, { method: 'PUT' }).catch(() => {});
  for (let i = 0; i < 25 && !page; i++) {
    await sleep(1000);
    const ts = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
    page = ts.find(t => t.type === 'page' && t.url.includes('workbench'));
  }
}
if (!page) { console.log('❌ 工作台页面未就绪'); process.exit(1); }
// 激活到前台（避免后台标签页定时器节流影响注入/探测）
await fetch(`http://127.0.0.1:${PORT}/json/activate/${page.id}`, { method: 'PUT' }).catch(() => {});
console.log('工作台页面就绪');

// —— 2. 等待各窗格就绪（就绪/未登录/需人工验证 视为可测；超时也继续）——
let badges = [];
try {
  for (let i = 0; i < 45; i++) {
    await sleep(2000);
    badges = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify([...document.querySelectorAll('.badge')].map(b => b.textContent))`, 8000));
    if (badges.length === adapters.length && badges.every(b => b !== '加载中' && b !== '无响应' && b !== '未找到输入框')) break;
    if (i % 4 === 3) console.log(`等待窗格就绪… ${badges.join(' / ')}`);
  }
} catch (e) { console.log('徽章读取异常（继续）:', e.message); }
console.log(`窗格状态: ${badges.join(' / ') || '(未读到)'}`);

// —— 3. iframe 目标映射 ——
const ts = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const frameTargets = {};
for (const t of ts) {
  if (t.type !== 'iframe' || !t.url) continue;
  try { frameTargets[new URL(t.url).hostname] = t; } catch {}
}
console.log('iframe 目标:', Object.keys(frameTargets).join(', '));

const frameOf = (a) => {
  const host = new URL(a.origin).hostname;
  const t = frameTargets[host] || Object.values(frameTargets).find(t =>
    (a.homeHosts || []).some(h => t.url.includes(h)));
  return t || null;
};

// —— 4. 每帧安装 drop 证据监听 ——
for (const a of adapters) {
  const t = frameOf(a);
  if (!t) { console.log(`⚠️ ${a.id} 无 frame 目标`); continue; }
  try {
    await cdp(t.webSocketDebuggerUrl, `window.__wbDropEv = [];
['dragenter','dragover','drop'].forEach(ty => document.addEventListener(ty, (e) => {
  const dt = e.dataTransfer;
  window.__wbDropEv.push({ ty, files: dt ? dt.files.length : 0, name: dt && dt.files[0] ? dt.files[0].name : null,
    trusted: e.isTrusted, tag: e.target.tagName, cls: (typeof e.target.className === 'string' ? e.target.className : '').slice(0, 40) });
}, true)); 'ok'`);
  } catch (e) { console.log(`⚠️ ${a.id} drop 监听安装失败: ${e.message}`); }
}
console.log('drop 证据监听已安装');

// —— 5. 各帧文件输入框清单（WB_ATTACH_CHECK names=[] 即仅报告）——
const fileInputReport = {};
for (const a of adapters) {
  const t = frameOf(a);
  if (!t) continue;
  const expr = `(new Promise((resolve) => {
    const chk = 'mx' + Date.now();
    const h = (ev) => { const d = ev.data; if (d && d.checkId === chk) { window.removeEventListener('message', h); resolve(d.result || null); } };
    window.addEventListener('message', h);
    const w = document.getElementById('frame-${a.id}') && document.getElementById('frame-${a.id}').contentWindow;
    if (!w) { resolve(null); return; }
    w.postMessage({ type: 'WB_ATTACH_CHECK', frameId: '${a.id}', checkId: chk, names: [] }, '*');
    setTimeout(() => { window.removeEventListener('message', h); resolve(null); }, 5000);
  }))`;
  try { fileInputReport[a.id] = await cdp(page.webSocketDebuggerUrl, expr, 9000); }
  catch (e) { fileInputReport[a.id] = { error: e.message }; }
}
console.log('\n文件输入框清单:');
for (const a of adapters) {
  const r = fileInputReport[a.id];
  if (!r) { console.log(`  ${a.id}: (无 frame)`); continue; }
  if (r.error) { console.log(`  ${a.id}: 页面无响应: ${r.error}`); continue; }
  console.log(`  ${a.id}: ${r.fileInputs.length ? r.fileInputs.map(i => (i.cls || i.id || '(无类)')).join(' | ') : '(无)'}`);
}

// —— 6. 通道级矩阵 ——
const matrix = [];
// cdp 平台在前，kimi（openSelector 可能弹原生对话框）放最后
const order = adapters.filter(a => !(a.attachment && a.attachment.selectors && a.attachment.selectors.length))
  .concat(adapters.filter(a => a.attachment && a.attachment.selectors && a.attachment.selectors.length));

for (const a of order) {
  const t = frameOf(a);
  const plan = (a.attachment && a.attachment.selectors && a.attachment.selectors.length) ? 'input' : 'cdp';
  const row = { id: a.id, plan };
  if (!t) { row.error = 'no-frame'; matrix.push(row); console.log(`\n=== ${a.id}：无 frame，跳过 ===`); continue; }
  // 环境检查：frame 是否停在登录页
  try {
    row.frameURL = (await cdp(t.webSocketDebuggerUrl, 'location.href', 8000)) || '';
  } catch {}
  console.log(`\n=== ${a.id}（${plan} 通道）frame: ${row.frameURL || '?'} ===`);
  try {
    if (plan === 'input') {
      const cfg = {
        input: { selectors: a.input.selectors }, send: a.send, probe: a.probe || {},
        text: '', noSend: true,
        attachments: [{ name: 'tiny.png', mime: 'image/png', data: B64 }],
        attachment: a.attachment
      };
      const expr = `(new Promise((resolve) => {
        const chk = 'mx' + Date.now();
        const h = (ev) => { const d = ev.data; if (d && d.checkId === chk) { window.removeEventListener('message', h); resolve(d.result || null); } };
        window.addEventListener('message', h);
        const w = document.getElementById('frame-${a.id}') && document.getElementById('frame-${a.id}').contentWindow;
        if (!w) { resolve(null); return; }
        w.postMessage({ type: 'WB_INJECT', frameId: '${a.id}', checkId: chk, cfg: ${JSON.stringify(cfg)} }, '*');
        setTimeout(() => { window.removeEventListener('message', h); resolve(null); }, 20000);
      }))`;
      row.channel = await cdp(page.webSocketDebuggerUrl, expr, 25000);
      console.log('  WB_INJECT 回执:', JSON.stringify(row.channel));
    } else {
      const hostsJs = JSON.stringify([new URL(a.origin).hostname, ...(a.homeHosts || [])]);
      const expr = `(new Promise((resolve) => {
        const done = (v) => resolve(JSON.stringify(v));
        chrome.tabs.getCurrent(async (tab) => {
          if (!tab) return done({ ok: false, error: 'no-tab' });
          const fs = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
          const f = fs.find(x => {
            try {
              let h = ''; try { h = new URL(x.url || '').hostname; } catch {}
              return ${hostsJs}.some(k => h === k || h.endsWith('.' + k) || (x.url || '').includes(k));
            } catch { return false; }
          });
          if (!f) return done({ ok: false, error: 'no-frame' });
          const rect = await new Promise((r) => {
            chrome.scripting.executeScript({
              target: { tabId: tab.id, frameIds: [f.frameId] },
              func: () => {
                const el = document.querySelector('[contenteditable="true"], textarea');
                if (!el) return null;
                const b = el.getBoundingClientRect();
                if (!b || (b.width === 0 && b.height === 0)) return null;
                return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
              }
            }, (res) => r(res && res[0] ? res[0].result : null));
          });
          if (!rect) return done({ ok: false, error: 'no-editor' });
          const ifr = document.getElementById('frame-${a.id}');
          if (!ifr) return done({ ok: false, error: 'no-iframe' });
          // 离屏窗格临时移入视口左上角（命中测试需要视口内坐标）
          const pane = ifr.closest('.pane');
          const wasOff = pane && pane.classList.contains('offscreen');
          if (wasOff) {
            pane.style.position = 'fixed'; pane.style.left = '0px'; pane.style.top = '0px';
            pane.style.zIndex = '9999'; pane.style.opacity = '0.01';
          }
          const r = ifr.getBoundingClientRect();
          const restore = () => {
            if (!wasOff) return;
            pane.style.position = ''; pane.style.left = ''; pane.style.top = '';
            pane.style.zIndex = ''; pane.style.opacity = '';
          };
          chrome.runtime.sendMessage({ type: 'WB_ATTACH', tabId: tab.id, x: r.x + rect.x, y: r.y + rect.y,
            items: [{ mime: 'image/png', data: '${B64}', name: 'tiny.png' }] }, (res) => {
            restore();
            done({ ok: !!(res && res.ok), error: (res && res.error) || '', x: r.x + rect.x, y: r.y + rect.y, frameId: f.frameId });
          });
          setTimeout(() => { restore(); done({ ok: false, error: '页面侧超时' }); }, 20000);
        });
      }))`;
      const raw = await cdp(page.webSocketDebuggerUrl, expr, 25000);
      row.channel = { raw: JSON.parse(raw || '{}') };
      console.log('  WB_ATTACH 回执:', raw);
      await sleep(2500);
      const chkExpr = `(new Promise((resolve) => {
        const chk = 'mx' + Date.now();
        const h = (ev) => { const d = ev.data; if (d && d.checkId === chk) { window.removeEventListener('message', h); resolve(d.result || null); } };
        window.addEventListener('message', h);
        const w = document.getElementById('frame-${a.id}') && document.getElementById('frame-${a.id}').contentWindow;
        if (!w) { resolve(null); return; }
        w.postMessage({ type: 'WB_ATTACH_CHECK', frameId: '${a.id}', checkId: chk, names: ['tiny.png'] }, '*');
        setTimeout(() => { window.removeEventListener('message', h); resolve(null); }, 6000);
      }))`;
      row.channel.check = await cdp(page.webSocketDebuggerUrl, chkExpr, 10000);
      console.log('  接受度检查:', JSON.stringify(row.channel.check));
    }
  } catch (e) {
    row.error = String(e.message || e);
    console.log('  通道调用异常:', row.error);
  }

  // 证据采集（平台消化附件）
  try {
    await sleep(3000);
    // 注入前基线：文件名是否在注入前就已存在（排除历史文本假阳性）
    const base = JSON.parse(await cdp(t.webSocketDebuggerUrl, `JSON.stringify({
      visibleBefore: (document.body ? document.body.innerText : '').includes('tiny.png')
    })`, 10000));
    row.visibleBefore = base.visibleBefore;
    const ev = JSON.parse(await cdp(t.webSocketDebuggerUrl, `JSON.stringify({
      visible: (document.body ? document.body.innerText : '').includes('tiny.png'),
      focus: document.hasFocus(),
      dropEv: window.__wbDropEv || []
    })`, 10000));
    row.visible = ev.visible; row.focus = ev.focus; row.dropEv = ev.dropEv;
    console.log(`  可见: ${ev.visible}  焦点: ${ev.focus}  drop事件数: ${ev.dropEv.length}${ev.dropEv.length ? '（最后: ' + JSON.stringify(ev.dropEv[ev.dropEv.length - 1]) + '）' : ''}`);
    if (!ev.focus) console.log('  ⚠️ frame 失去焦点 —— 可能弹出了原生文件对话框');
  } catch (e) {
    row.error = (row.error ? row.error + '; ' : '') + '证据采集失败: ' + e.message;
  }
  matrix.push(row);
}

// —— 7. 清理：重载所有 frame（清掉残留附件/对话框）——
try {
  await cdp(page.webSocketDebuggerUrl, `(function(){
    for (const a of ${JSON.stringify(adapters.map(x => x.id))}) {
      const f = document.getElementById('frame-' + a);
      if (f) f.src = f.src;
    }
    return 'reloading';
  })()`);
} catch {}

// —— 8. 结果汇总 ——
console.log('\n========== 附件接受度矩阵 ==========');
for (const m of matrix) {
  const ok = m.visible === true && m.visibleBefore !== true;
  console.log(`${byId[m.id].name.padEnd(8)} 通道=${m.plan.padEnd(6)} 接受=${ok ? '✅' : '❌'} 焦点=${m.focus ? '✓' : '✗'} drop事件=${(m.dropEv || []).length}${m.error ? ' 异常=' + m.error.slice(0, 60) : ''}${ok || m.error ? '' : ' 详情=' + JSON.stringify(m.channel).slice(0, 140)}`);
}
try {
  const ensureLog = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify(window.__wbEnsureLog || [])`, 8000));
  console.log('\n注入日志:', ensureLog.join(' → '));
} catch {}
writeFileSync('/tmp/wb-attach-matrix.json', JSON.stringify({ adapters, fileInputReport, matrix }, null, 2));
console.log('\n矩阵已保存 /tmp/wb-attach-matrix.json');
const hardErrors = matrix.filter(m => m.error).map(m => m.id);
if (hardErrors.length) {
  console.log('\n⚠️ 存在通道硬错误（页面无响应等）:', hardErrors.join(', '));
  console.log('（no-editor/no-frame 属环境未登录态，需人工登录后复测）');
}

// —— 9.（可选 --full）真实端到端：附件+文本 全平台发送 ——
if (FULL) {
  console.log('\n== --full：真实发送（附件+文本）==');
  const expr = `(async function(){
    const q = document.getElementById('question');
    const bytes = Uint8Array.from(atob('${B64}'), c => c.charCodeAt(0));
    const f = new File([bytes], 'tiny.png', { type: 'image/png' });
    const dt = new DataTransfer();
    dt.items.add(f);
    const inp = document.getElementById('file-input');
    inp.files = dt.files;
    inp.dispatchEvent(new Event('change'));
    await new Promise(r => setTimeout(r, 500));
    q.value = '附件通道端到端测试，请忽略这条消息';
    q.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise(r => setTimeout(r, 300));
    document.getElementById('send').click();
    return 'sent';
  })()`;
  try {
    await cdp(page.webSocketDebuggerUrl, expr, 20000);
    console.log('已触发全平台发送，等待 25 秒…');
    await sleep(25000);
    const toasts = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify([...document.querySelectorAll('.toast')].filter(t => t.style.display !== 'none').map(t => t.textContent))`));
    console.log('窗格 toasts:', JSON.stringify(toasts, null, 2));
    const log = JSON.parse(await cdp(page.webSocketDebuggerUrl, `JSON.stringify(window.__wbAttachLog || [])`));
    console.log('附件日志:', JSON.stringify(log, null, 2));
  } catch (e) {
    console.log('--full 执行异常:', e.message);
  }
}

console.log('\n完成');
