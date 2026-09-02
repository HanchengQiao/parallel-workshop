// Trusted-event live test for the DeepSeek model preference bridge.
// It injects a semantic fixture into an isolated DeepSeek page and never logs in,
// sends a prompt, or reads authentication storage.
import { readFileSync } from 'node:fs';
import { cdpCommand } from './edge-workbench-target.mjs';

const port = Number(process.env.PWB_EDGE_PORT || 9223);
const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const source = readFileSync(base + 'Sources/WorkbenchCore/Resources/injection/model-preference.js', 'utf8');
const storageKey = '__parallelWorkbench.deepseekModelPreference.v1';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const page = targets.find(item => ['page', 'iframe'].includes(item.type) && item.url.includes('chat.deepseek.com'));
if (!page) throw new Error('没有找到隔离的 DeepSeek 页面或工作台 iframe');

async function evaluate(expression) {
  const result = await cdpCommand(page.webSocketDebuggerUrl, 'Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true
  });
  if (result?.exceptionDetails) throw new Error(result.exceptionDetails.text || '页面执行失败');
  return result?.result?.value;
}

await evaluate(`(() => {
  localStorage.removeItem(${JSON.stringify(storageKey)});
  delete window.__pwbModelPreferenceBridgeInstalled;
  (0, eval)(${JSON.stringify(source)});
  const old = document.getElementById('pwb-model-fixture');
  if (old) old.remove();
  const group = document.createElement('div');
  group.id = 'pwb-model-fixture';
  group.setAttribute('role', 'radiogroup');
  Object.assign(group.style, { position:'fixed', left:'20px', top:'20px', zIndex:'2147483647', display:'flex' });
  for (const [type, checked] of [['default', true], ['expert', false]]) {
    const item = document.createElement('button');
    item.type = 'button';
    item.dataset.modelType = type;
    item.setAttribute('role', 'radio');
    item.setAttribute('aria-checked', String(checked));
    item.textContent = type;
    Object.assign(item.style, { width:'120px', height:'44px' });
    item.addEventListener('click', () => {
      for (const sibling of group.querySelectorAll('[role="radio"]')) {
        sibling.setAttribute('aria-checked', String(sibling === item));
      }
    });
    group.appendChild(item);
  }
  document.body.appendChild(group);
  return true;
})()`);

const rect = JSON.parse(await evaluate(`JSON.stringify((() => {
  const r = document.querySelector('#pwb-model-fixture [data-model-type="expert"]').getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
})())`));
await cdpCommand(page.webSocketDebuggerUrl, 'Input.dispatchMouseEvent', {
  type: 'mousePressed', x: rect.x, y: rect.y, button: 'left', clickCount: 1
});
await cdpCommand(page.webSocketDebuggerUrl, 'Input.dispatchMouseEvent', {
  type: 'mouseReleased', x: rect.x, y: rect.y, button: 'left', clickCount: 1
});
await delay(250);
const saved = JSON.parse(await evaluate(`localStorage.getItem(${JSON.stringify(storageKey)})`));
if (saved?.version !== 1 || saved?.modelType !== 'expert') {
  throw new Error('真实受信点击没有保存 expert model_type');
}

await delay(1300);
await evaluate(`(() => {
  document.querySelector('[data-model-type="expert"]').setAttribute('aria-checked', 'false');
  document.querySelector('[data-model-type="default"]').setAttribute('aria-checked', 'true');
})()`);
await delay(250);
const restored = await evaluate(`document.querySelector('[data-model-type="expert"]').getAttribute('aria-checked')`);
await evaluate(`document.getElementById('pwb-model-fixture')?.remove(); localStorage.removeItem(${JSON.stringify(storageKey)});`);
if (restored !== 'true') throw new Error('DeepSeek 页面重置默认模型后没有恢复 expert');

console.log('✅ DeepSeek 模型偏好真实浏览器测试通过（可信点击保存 + 页面重置恢复）');
