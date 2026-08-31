const DISPOSABLE_TOP_LEVEL_URLS = new Set([
  'about:blank',
  'edge://newtab/',
  'edge://new-tab-page/',
  'chrome://newtab/',
  'chrome://new-tab-page/'
]);

const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

export function isDisposableTopLevelTarget(target) {
  return target?.type === 'page' && DISPOSABLE_TOP_LEVEL_URLS.has(target.url || '');
}

export async function listEdgeTargets(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json`);
  if (!response.ok) throw new Error(`Edge target list failed: HTTP ${response.status}`);
  return await response.json();
}

export async function cdpCommand(wsUrl, method, params = {}, timeoutMs = 15000) {
  return await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error(`CDP ${method} timeout`));
    }, timeoutMs);
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method, params }));
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== 1) return;
      clearTimeout(timer);
      try { ws.close(); } catch {}
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result || {});
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error(`CDP ${method} websocket error`));
    };
  });
}

function isWorkbenchTarget(target, workbenchURL) {
  return target?.type === 'page' && target.url === workbenchURL;
}

function isBlockedWorkbenchTarget(target, workbenchURL) {
  return target?.type === 'page' && target.url === 'chrome-error://chromewebdata/' &&
    (target.title === workbenchURL || (target.title || '').includes('/workbench.html'));
}

async function closeTarget(port, targetId) {
  await fetch(`http://127.0.0.1:${port}/json/close/${targetId}`, { method: 'PUT' }).catch(() => {});
}

export async function assertCleanWorkbenchTargets({ port, extId }) {
  const workbenchURL = `chrome-extension://${extId}/workbench.html`;
  const targets = await listEdgeTargets(port);
  const pages = targets.filter(target => target.type === 'page');
  const workbenches = pages.filter(target => isWorkbenchTarget(target, workbenchURL));
  const blanks = pages.filter(isDisposableTopLevelTarget);
  const blocked = pages.filter(target => isBlockedWorkbenchTarget(target, workbenchURL));
  if (workbenches.length !== 1 || blanks.length || blocked.length) {
    throw new Error(`顶层页面不干净：workbench=${workbenches.length}, blank=${blanks.length}, blocked=${blocked.length}`);
  }
  return { workbench: workbenches[0], workbenchCount: 1, blankCount: 0, blockedCount: 0 };
}

export async function ensureSingleWorkbenchPage({ port, extId, timeoutMs = 90000 }) {
  const workbenchURL = `chrome-extension://${extId}/workbench.html`;
  const deadline = Date.now() + timeoutMs;
  let candidate = null;
  let createdFallback = false;
  let nextNavigationAt = 0;

  while (Date.now() < deadline) {
    const targets = await listEdgeTargets(port);
    const pages = targets.filter(target => target.type === 'page');
    const ready = pages.find(target => isWorkbenchTarget(target, workbenchURL));

    if (ready) {
      // 测试运行在隔离 profile：清掉浏览器默认空白页、竞态错误页和重复工作台，避免 QA 自己制造误导。
      const leftovers = pages.filter(target => target.id !== ready.id && (
        isDisposableTopLevelTarget(target) ||
        isBlockedWorkbenchTarget(target, workbenchURL) ||
        isWorkbenchTarget(target, workbenchURL)
      ));
      for (const target of leftovers) await closeTarget(port, target.id);
      await sleep(250);
      return (await assertCleanWorkbenchTargets({ port, extId })).workbench;
    }

    if (candidate) {
      candidate = pages.find(target => target.id === candidate.id) ||
        pages.find(target => isBlockedWorkbenchTarget(target, workbenchURL)) || null;
    }
    if (!candidate) {
      candidate = pages.find(isDisposableTopLevelTarget) ||
        pages.find(target => isBlockedWorkbenchTarget(target, workbenchURL)) || null;
    }

    if (!candidate && !createdFallback) {
      // 无可复用 target 时只创建一次，并直接请求工作台 URL；后续竞态重试始终复用同一个 target。
      const response = await fetch(
        `http://127.0.0.1:${port}/json/new?${encodeURIComponent(workbenchURL)}`,
        { method: 'PUT' }
      );
      if (response.ok) candidate = await response.json();
      createdFallback = true;
    }

    if (candidate?.webSocketDebuggerUrl && Date.now() >= nextNavigationAt) {
      await cdpCommand(candidate.webSocketDebuggerUrl, 'Page.navigate', { url: workbenchURL }).catch(() => {});
      nextNavigationAt = Date.now() + 1800;
    }
    await sleep(750);
  }

  throw new Error('工作台页面未在限定时间内就绪（始终复用同一 target，未反复新建标签）');
}
