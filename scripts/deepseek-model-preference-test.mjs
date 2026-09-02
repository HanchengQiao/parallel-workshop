import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { JSDOM } = require(process.env.PWB_JSDOM_MODULE || 'jsdom');
const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const source = readFileSync(base + 'Sources/WorkbenchCore/Resources/injection/model-preference.js', 'utf8');
const manifest = JSON.parse(readFileSync(base + 'Windows/edge-extension/manifest.json', 'utf8'));
const STORAGE_KEY = '__parallelWorkbench.deepseekModelPreference.v1';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function modelSwitcher(window) {
  const group = window.document.createElement('div');
  group.setAttribute('role', 'radiogroup');
  for (const [type, checked] of [['default', true], ['expert', false], ['vision', false]]) {
    const item = window.document.createElement('div');
    item.setAttribute('role', 'radio');
    item.dataset.modelType = type;
    item.setAttribute('aria-checked', String(checked));
    item.addEventListener('click', () => {
      for (const sibling of group.querySelectorAll('[role="radio"]')) {
        sibling.setAttribute('aria-checked', String(sibling === item));
      }
    });
    group.appendChild(item);
  }
  return group;
}

async function boot(saved) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', {
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    url: 'https://chat.deepseek.com/'
  });
  if (saved !== undefined) dom.window.localStorage.setItem(STORAGE_KEY, saved);
  dom.window.eval(source);
  dom.window.document.body.appendChild(modelSwitcher(dom.window));
  await delay(180);
  return dom;
}

const restored = await boot(JSON.stringify({ version: 1, modelType: 'expert' }));
if (restored.window.document.querySelector('[data-model-type="expert"]').getAttribute('aria-checked') !== 'true') {
  throw new Error('没有按稳定 data-model-type 恢复 DeepSeek 模型');
}

// DeepSeek creates a new session by resetting its in-memory model to default.
// The mutation guard must restore the remembered choice again.
restored.window.document.querySelector('[data-model-type="expert"]').setAttribute('aria-checked', 'false');
restored.window.document.querySelector('[data-model-type="default"]').setAttribute('aria-checked', 'true');
await delay(750);
if (restored.window.document.querySelector('[data-model-type="expert"]').getAttribute('aria-checked') !== 'true') {
  throw new Error('新会话默认重置后没有再次恢复 DeepSeek 模型');
}
restored.window.close();

for (const invalid of [
  '{broken',
  JSON.stringify({ version: 2, modelType: 'expert' }),
  JSON.stringify({ version: 1, modelType: '../expert' })
]) {
  const dom = await boot(invalid);
  if (dom.window.document.querySelector('[data-model-type="default"]').getAttribute('aria-checked') !== 'true') {
    throw new Error('损坏或未知 schema 的模型偏好不应触发恢复');
  }
  dom.window.close();
}

const modelScriptEntry = manifest.content_scripts.find(entry =>
  entry.world === 'MAIN' && entry.matches?.includes('https://chat.deepseek.com/*') &&
  entry.js?.includes('lib/model-preference.js'));
if (!modelScriptEntry || modelScriptEntry.all_frames !== true || modelScriptEntry.run_at !== 'document_start') {
  throw new Error('Edge manifest 没有把模型偏好桥注入工作台内的 DeepSeek frame');
}
const paneController = readFileSync(base + 'Sources/WorkbenchCore/PaneController.swift', 'utf8');
if (!source.includes('event.isTrusted') ||
    !paneController.includes('adapter.id == "deepseek"') ||
    !paneController.includes('InjectionScripts.modelPreferenceJS')) {
  throw new Error('模型偏好桥缺少可信用户选择约束或 macOS DeepSeek 限域接线');
}

console.log('✅ DeepSeek 模型偏好：语义 model_type、跨重启恢复与新会话重置恢复通过');
