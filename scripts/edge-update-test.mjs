import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { JSDOM } = require(process.env.PWB_JSDOM_MODULE || 'jsdom');

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const html = readFileSync(base + 'Windows/edge-extension/workbench.html', 'utf8');
const workbenchSource = readFileSync(base + 'Windows/edge-extension/workbench.js', 'utf8');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function waitFor(predicate, label, timeout = 1500) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (predicate()) return;
    await delay(5);
  }
  throw new Error(`等待超时：${label}`);
}

function makeRelease(assets) {
  return { tag_name: 'v1.1.0', assets };
}

async function boot({ storeBuild, release, requestUpdateCheck }) {
  const dom = new JSDOM(html, {
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    url: 'chrome-extension://test/workbench.html'
  });
  const { window } = dom;
  if (!window.crypto.randomUUID) {
    window.crypto.randomUUID = () => '00000000-0000-4000-8000-000000000000';
  }

  const timers = [];
  const downloads = [];
  const fetchedURLs = [];
  let updateListener;
  let storageWrites = 0;
  let updateChecks = 0;
  let reloads = 0;
  let objectURLs = 0;

  window.setTimeout = (fn, ms, ...args) => {
    const timer = { active: true, ms, run: () => fn(...args) };
    timers.push(timer);
    return timers.length;
  };
  window.clearTimeout = id => {
    if (timers[id - 1]) timers[id - 1].active = false;
  };
  window.setInterval = () => 0;
  window.requestAnimationFrame = fn => { fn(0); return 1; };
  window.URL.createObjectURL = () => {
    objectURLs += 1;
    return `blob:edge-update-test-${objectURLs}`;
  };
  window.HTMLAnchorElement.prototype.click = function click() {
    downloads.push({ download: this.download, href: this.href });
  };

  window.fetch = async input => {
    const url = String(input);
    fetchedURLs.push(url);
    if (url === 'chrome-extension://test/lib/adapters/index.json') {
      return { ok: true, json: async () => [] };
    }
    if (url === 'https://api.github.com/repos/porcelaintech/parallel-workshop/releases/latest') {
      return { ok: true, json: async () => structuredClone(release) };
    }
    const asset = release.assets.find(item => item.browser_download_url === url);
    if (asset) {
      return { ok: true, blob: async () => new window.Blob([asset.name]) };
    }
    throw new Error(`测试中出现未声明的网络请求：${url}`);
  };

  window.chrome = {
    runtime: {
      id: 'test',
      getURL: path => `chrome-extension://test/${path}`,
      getManifest: () => storeBuild
        ? { version: '1.0.0' }
        : { version: '1.0.0', key: 'fixed-side-load-id-key' },
      onMessage: { addListener() {} },
      onUpdateAvailable: { addListener(listener) { updateListener = listener; } },
      sendMessage: async message => message?.type === 'WB_REGISTER_WORKBENCH'
        ? { ok: true, tabId: 7 }
        : { ok: false },
      requestUpdateCheck: async () => {
        updateChecks += 1;
        if (!requestUpdateCheck) throw new Error('侧载版不应请求 Edge 商店更新');
        return requestUpdateCheck();
      },
      reload: () => { reloads += 1; }
    },
    storage: {
      local: {
        get: async () => ({}),
        set: async () => { storageWrites += 1; }
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
  await waitFor(
    () => storageWrites > 0 && timers.some(timer => timer.active && timer.ms === 5000),
    '工作台初始化并安排更新检查'
  );

  return {
    dom,
    window,
    downloads,
    fetchedURLs,
    fireUpdateAvailable(details) {
      if (!updateListener) throw new Error('未注册 onUpdateAvailable 监听器');
      updateListener(details);
    },
    get updateChecks() { return updateChecks; },
    get reloads() { return reloads; },
    get objectURLs() { return objectURLs; },
    async runTimer(ms) {
      const timer = timers.find(item => item.active && item.ms === ms);
      if (!timer) throw new Error(`未找到 ${ms}ms 定时器`);
      timer.active = false;
      await timer.run();
      await delay(0);
    },
    timerCount(ms) {
      return timers.filter(item => item.active && item.ms === ms).length;
    }
  };
}

async function exposeUpdateBanner(app, expectedButtonText) {
  await app.runTimer(5000);
  await waitFor(
    () => app.window.document.querySelector('#update-banner #update-btn')?.textContent === expectedButtonText,
    `显示「${expectedButtonText}」更新按钮`
  );
  return app.window.document.getElementById('update-btn');
}

// Store build: a user click starts Edge's native check. The ready event is allowed to
// race with the Promise result, but the extension must schedule exactly one reload.
let resolveStoreCheck;
const storeCheckResult = new Promise(resolve => { resolveStoreCheck = resolve; });
const store = await boot({
  storeBuild: true,
  release: makeRelease([]),
  requestUpdateCheck: () => storeCheckResult
});
const storeButton = await exposeUpdateBanner(store, '立即更新');
storeButton.click();
await waitFor(() => store.updateChecks === 1, '商店版发起 requestUpdateCheck');
if (!store.window.document.getElementById('update-banner').textContent.includes('正在通过 Edge')) {
  throw new Error('商店版没有向用户显示更新进度');
}
store.fireUpdateAvailable({ version: '1.1.0' });
resolveStoreCheck({ status: 'update_available', version: '1.1.0' });
await delay(0);
if (store.timerCount(250) !== 1) {
  throw new Error('onUpdateAvailable 与 requestUpdateCheck 竞态导致重复安排重载');
}
await store.runTimer(250);
if (store.reloads !== 1) throw new Error('商店版没有通过 runtime.reload 完成一键更新');
if (store.downloads.length || store.objectURLs) {
  throw new Error('商店版错误地走了 ZIP 下载路径');
}
store.dom.window.close();

// Store fallback: even if the event is delayed, an update_available result completes
// the same one-click path instead of leaving the UI waiting indefinitely.
const storeResultOnly = await boot({
  storeBuild: true,
  release: makeRelease([]),
  requestUpdateCheck: async () => ({ status: 'update_available', version: '1.1.0' })
});
(await exposeUpdateBanner(storeResultOnly, '立即更新')).click();
await waitFor(() => storeResultOnly.timerCount(250) === 1, '商店检查结果安排重载');
await storeResultOnly.runTimer(250);
if (storeResultOnly.updateChecks !== 1 || storeResultOnly.reloads !== 1) {
  throw new Error('商店版 update_available 结果未完成单次重载');
}
storeResultOnly.dom.window.close();

// Side-loaded build: the store ZIP and arbitrary ZIPs deliberately precede the user
// ZIP. Only the exact edge-extension.zip URL may be handed to Edge's native downloader;
// its body must not be fetched through the extension origin (GitHub redirects lack CORS).
const storeAssetURL = 'https://downloads.example/edge-extension-store.zip';
const otherAssetURL = 'https://downloads.example/source.zip';
const userAssetURL = 'https://downloads.example/edge-extension.zip';
const sideLoaded = await boot({
  storeBuild: false,
  release: makeRelease([
    { name: 'edge-extension-store.zip', browser_download_url: storeAssetURL },
    { name: 'source.zip', browser_download_url: otherAssetURL },
    { name: 'edge-extension.zip', browser_download_url: userAssetURL }
  ])
});
(await exposeUpdateBanner(sideLoaded, '下载更新')).click();
await waitFor(() => sideLoaded.downloads.length === 1, '侧载版下载用户包');
if (sideLoaded.downloads[0].download !== 'edge-extension.zip' ||
    sideLoaded.downloads[0].href !== userAssetURL ||
    sideLoaded.fetchedURLs.includes(userAssetURL) || sideLoaded.fetchedURLs.includes(storeAssetURL) ||
    sideLoaded.fetchedURLs.includes(otherAssetURL)) {
  throw new Error('侧载版没有精确选择 edge-extension.zip');
}
if (sideLoaded.updateChecks !== 0 || sideLoaded.reloads !== 0 || sideLoaded.objectURLs !== 0) {
  throw new Error('侧载版与商店更新路径发生了串路');
}
sideLoaded.dom.window.close();

// Fail closed if a release contains only the store package.
const missingUserAsset = await boot({
  storeBuild: false,
  release: makeRelease([{ name: 'edge-extension-store.zip', browser_download_url: storeAssetURL }])
});
(await exposeUpdateBanner(missingUserAsset, '下载更新')).click();
await waitFor(
  () => missingUserAsset.window.document.getElementById('update-banner').textContent.includes('下载失败'),
  '缺少用户包时失败关闭'
);
if (missingUserAsset.downloads.length || missingUserAsset.fetchedURLs.includes(storeAssetURL)) {
  throw new Error('缺少用户包时错误下载了商店包');
}
missingUserAsset.dom.window.close();

console.log('✅ Edge 更新：商店原生检查/单次重载与侧载精确资产选择全部通过');
