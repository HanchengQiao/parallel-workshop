import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { JSDOM } = require(process.env.PWB_JSDOM_MODULE || 'jsdom');

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const html = readFileSync(base + 'Windows/edge-extension/workbench.html', 'utf8');
const workbenchSource = readFileSync(base + 'Windows/edge-extension/workbench.js', 'utf8');
const KEY = 'parallelWorkbench.preferences.v1';
const ABSENT = Symbol('absent');

const makeAdapter = (id, name = id.toUpperCase()) => ({
  id,
  name,
  origin: `https://${id}.example.test/`,
  input: { selectors: ['textarea'] },
  send: { type: 'enter' },
  probe: {},
  homeHosts: [`${id}.example.test`]
});

const clone = value => structuredClone(value);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function waitFor(predicate, label, timeout = 1500) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (predicate()) return;
    await delay(5);
  }
  throw new Error(`等待超时：${label}`);
}

async function boot({ adapters, stored = ABSENT, width = 640 }) {
  const dom = new JSDOM(html, {
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    url: 'chrome-extension://test/workbench.html'
  });
  const { window } = dom;
  Object.defineProperty(window, 'innerWidth', { configurable: true, value: width, writable: true });
  if (!window.crypto.randomUUID) window.crypto.randomUUID = () => '00000000-0000-4000-8000-000000000000';

  const writes = [];
  const state = stored === ABSENT ? {} : { [KEY]: clone(stored) };
  window.fetch = async () => ({ ok: true, json: async () => clone(adapters) });
  window.setInterval = () => 0;
  const nativeSetTimeout = window.setTimeout.bind(window);
  window.setTimeout = (fn, ms, ...args) => ms >= 1000 ? 0 : nativeSetTimeout(fn, ms, ...args);
  window.chrome = {
    runtime: {
      id: 'test',
      getURL: path => `chrome-extension://test/${path}`,
      getManifest: () => ({ version: '0.0.0' }),
      onMessage: { addListener() {} },
      sendMessage: async message => message?.type === 'WB_REGISTER_WORKBENCH'
        ? { ok: true, tabId: 7 }
        : { ok: false }
    },
    storage: {
      local: {
        get: async key => Object.prototype.hasOwnProperty.call(state, key)
          ? { [key]: clone(state[key]) }
          : {},
        set: async update => {
          Object.assign(state, clone(update));
          writes.push(clone(update[KEY]));
        }
      }
    },
    tabs: {
      getCurrent: async () => ({ id: 7 }),
      sendMessage: async () => ({ result: null })
    },
    webNavigation: { getAllFrames: async () => [] },
    scripting: { executeScript(_options, callback) { callback?.([]); } }
  };

  window.eval(workbenchSource);
  await waitFor(() => writes.length > 0, '启动偏好规范化写入');
  return {
    dom,
    window,
    writes,
    latest: () => writes.at(-1),
    waitForWrite: async predicate => waitFor(() => predicate(writes.at(-1)), '偏好写入')
  };
}

function checkedIDs(window) {
  return [...window.document.querySelectorAll('#checks input')]
    .filter(input => input.checked)
    .map(input => input.parentElement.textContent.trim().toLowerCase());
}

function checkboxFor(window, name) {
  return [...window.document.querySelectorAll('#checks label')]
    .find(label => label.textContent.trim().toLowerCase() === name.toLowerCase())
    ?.querySelector('input');
}

function changeCheckbox(app, id, checked) {
  const input = checkboxFor(app.window, id);
  if (!input) throw new Error(`缺少 ${id} 勾选框`);
  input.checked = checked;
  input.dispatchEvent(new app.window.Event('change', { bubbles: true }));
}

const initialAdapters = ['a', 'b', 'c'].map(id => makeAdapter(id));

// First use: every adapter is selected and a canonical v1 record is created.
const first = await boot({ adapters: initialAdapters });
if (checkedIDs(first.window).join(',') !== 'a,b,c') throw new Error('首次使用没有默认全选');
if (first.latest().version !== 1 || first.latest().enabledAdapterIDs.join(',') !== 'a,b,c' ||
    first.latest().pageAnchorAdapterID !== 'a') {
  throw new Error('首次使用没有写入合法 v1 偏好');
}

// Pagination and zoom actions persist. Toggling an adapter never removes/recreates its iframe.
const frameA = first.window.document.getElementById('frame-a');
const contentA = frameA.contentWindow;
changeCheckbox(first, 'a', false);
await first.waitForWrite(value => value.enabledAdapterIDs.join(',') === 'b,c');
if (first.window.document.getElementById('frame-a') !== frameA || frameA.contentWindow !== contentA ||
    !frameA.closest('.pane').classList.contains('offscreen')) {
  throw new Error('取消勾选销毁了 iframe/contentWindow，或没有将其离屏');
}
changeCheckbox(first, 'a', true);
await first.waitForWrite(value => value.enabledAdapterIDs.join(',') === 'a,b,c');
if (first.window.document.getElementById('frame-a') !== frameA || frameA.contentWindow !== contentA) {
  throw new Error('重新勾选后 iframe/contentWindow 发生变化');
}

first.window.document.querySelector('.zoom-in[data-id="a"]').click();
await first.waitForWrite(value => value.zoomByAdapterID.a === 1.1);
first.window.document.getElementById('page-left').click();
await first.waitForWrite(value => value.pageAnchorAdapterID === 'a');
first.window.document.getElementById('page-right').click();
await first.waitForWrite(value => value.pageAnchorAdapterID === 'b');
const remembered = clone(first.latest());
first.dom.window.close();

// Existing preferences survive restart. A newly introduced adapter is deliberately opt-in.
const withNewAdapter = [...initialAdapters, makeAdapter('new')];
const restored = await boot({ adapters: withNewAdapter, stored: remembered });
if (checkedIDs(restored.window).join(',') !== 'a,b,c' || checkboxFor(restored.window, 'new').checked) {
  throw new Error('已有偏好错误地自动勾选了新 adapter');
}
if (!restored.window.document.getElementById('frame-b') ||
    restored.window.document.getElementById('frame-b').closest('.pane').classList.contains('offscreen')) {
  throw new Error('重启后没有恢复分页锚点');
}
if (restored.window.document.getElementById('frame-a').style.zoom !== '1.1') {
  throw new Error('重启后没有恢复缩放');
}
restored.dom.window.close();

// Unknown IDs, duplicate IDs and invalid zooms are filtered without selecting new adapters.
const dirty = await boot({
  adapters: withNewAdapter,
  stored: {
    version: 1,
    enabledAdapterIDs: ['b', 'removed', 'b', 42],
    pageAnchorAdapterID: 'removed',
    zoomByAdapterID: { b: 1.25, a: 1.31, c: 0.59, removed: 1, new: '1.2' }
  }
});
if (checkedIDs(dirty.window).join(',') !== 'b') throw new Error('未知或损坏 adapter ID 未被过滤');
if (dirty.latest().pageAnchorAdapterID !== 'b' || dirty.latest().zoomByAdapterID.b !== 1.25 ||
    'a' in dirty.latest().zoomByAdapterID || 'c' in dirty.latest().zoomByAdapterID ||
    'removed' in dirty.latest().zoomByAdapterID || 'new' in dirty.latest().zoomByAdapterID) {
  throw new Error('未知 ID、无效锚点或越界/非数字缩放未被规范化');
}
dirty.dom.window.close();

// Structurally corrupt data falls back to safe first-use defaults; a valid empty choice stays empty.
const corrupt = await boot({
  adapters: initialAdapters,
  stored: { version: 1, enabledAdapterIDs: 'a', pageAnchorAdapterID: null, zoomByAdapterID: {} }
});
if (checkedIDs(corrupt.window).join(',') !== 'a,b,c') throw new Error('损坏偏好没有回退到全选默认值');
corrupt.dom.window.close();

const empty = await boot({
  adapters: initialAdapters,
  stored: { version: 1, enabledAdapterIDs: [], pageAnchorAdapterID: null, zoomByAdapterID: {} }
});
if (checkedIDs(empty.window).length !== 0 || empty.window.document.querySelectorAll('.pane').length !== 0 ||
    !empty.window.document.querySelector('#panes .empty')) {
  throw new Error('用户主动取消全部平台的偏好没有被保留');
}
empty.dom.window.close();

if (!/if \(!enabled\.has\(id\)\) continue;/.test(workbenchSource)) {
  throw new Error('发送链路缺少 enabled 防线');
}
if (/delete frames\[|\.closest\('\.pane'\)\.remove\(\)/.test(workbenchSource)) {
  throw new Error('工作台仍包含取消勾选时销毁 iframe 的路径');
}

console.log('✅ Edge 偏好 v1：首次默认、恢复、过滤、缩放、分页与 iframe 保活全部通过');
