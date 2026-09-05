// 后台：点击图标打开工作台窗口；按需把 content.js 精准注入各平台 frame
const WORKBENCH_URL = chrome.runtime.getURL('workbench.html');
const LAUNCH_URL = chrome.runtime.getURL('launch.html');
const RELOAD_PENDING_KEY = 'wb-pending-extension-reload';
const REUSABLE_EMPTY_URLS = new Set([
  'about:blank',
  'edge://newtab/',
  'edge://new-tab-page/',
  'chrome://newtab/',
  'chrome://new-tab-page/'
]);

function isReusableEmptyTab(tab) {
  const url = tab?.pendingUrl || tab?.url || '';
  return Number.isInteger(tab?.id) && REUSABLE_EMPTY_URLS.has(url);
}

function isWorkbenchEntry(tab) {
  return [WORKBENCH_URL, LAUNCH_URL].includes(tab?.pendingUrl || tab?.url);
}

async function workbenchEntries() {
  // Edge omits tab.url even for extension-owned tabs without the broad tabs
  // permission. getContexts enumerates only this extension's own documents.
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['TAB'] });
  return contexts.filter(context => context.frameId === 0 &&
    [WORKBENCH_URL, LAUNCH_URL].includes(context.documentUrl) && Number.isInteger(context.tabId))
    .map(context => ({ id: context.tabId, windowId: context.windowId, url: context.documentUrl }));
}

function isReloadLandingURL(raw) {
  if (REUSABLE_EMPTY_URLS.has(raw)) return true;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' && ['ntp.msn.com', 'ntp.msn.cn'].includes(url.hostname) && url.pathname === '/edge/ntp';
  } catch { return false; }
}

async function canRestoreReloadTab(tab, entries) {
  if (entries.some(entry => entry.id === tab.id) || isReusableEmptyTab(tab)) return true;
  // The new worker can start before Edge has committed its replacement new-tab
  // page. Wait for that actual navigation rather than abandoning the original tab.
  const deadline = Date.now() + 5000;
  do {
    let frames;
    try { frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id }); } catch { frames = []; }
    const top = (frames || []).find(frame => frame.frameId === 0);
    const url = top?.url || tab.pendingUrl || tab.url;
    if (url) return isReloadLandingURL(url);
    await new Promise(resolve => setTimeout(resolve, 100));
  } while (Date.now() < deadline);
  return false;
}

async function focusWorkbench(tab) {
  await chrome.tabs.update(tab.id, { active: true });
  if (Number.isInteger(tab.windowId)) await chrome.windows.update(tab.windowId, { focused: true });
}

let openingWorkbench = null;
let entryQueue = Promise.resolve();
let pendingWorkbenchNavigation = null;
function serializeEntry(action) {
  const operation = entryQueue.then(action);
  entryQueue = operation.catch(() => {});
  return operation;
}

function openWorkbenchFromAction(tab) {
  if (openingWorkbench) return openingWorkbench;
  openingWorkbench = serializeEntry(() => openWorkbench(tab)).finally(() => { openingWorkbench = null; });
  return openingWorkbench;
}

async function openWorkbench(tab) {
  const existing = (await workbenchEntries())[0];
  if (existing) {
    await focusWorkbench(existing);
    return existing;
  }
  // 用户若正停在浏览器自动生成的空白/新标签页，就原地替换它，避免留下“空白页 + 工作台”双标签。
  if (isReusableEmptyTab(tab)) {
    await chrome.tabs.update(tab.id, { url: LAUNCH_URL, active: true });
    if (Number.isInteger(tab.windowId)) {
      await chrome.windows.update(tab.windowId, { focused: true });
    }
    return;
  }

  await chrome.windows.create({
    url: LAUNCH_URL,
    type: 'popup',
    width: 1500,
    height: 950
  });
}

chrome.action.onClicked.addListener((tab) => {
  openWorkbenchFromAction(tab).catch(() => {
    // 标签可能在点击后被用户关闭；此时退回直接创建工作台，不引入预热或固定延迟。
    chrome.windows.create({
      url: LAUNCH_URL,
      type: 'popup',
      width: 1500,
      height: 950
    });
  });
});

// runtime.reload invalidates the old extension pages. Keep a short-lived receipt in
// local storage (session storage is cleared on reload), and restore only our tab.
const reloadRecovery = (async () => {
  const pending = (await chrome.storage.local.get(RELOAD_PENDING_KEY))[RELOAD_PENDING_KEY];
  if (!pending) return false;
  if (!Number.isInteger(pending.tabId) || typeof pending.createdAt !== 'number' ||
      Date.now() - pending.createdAt < 0 || Date.now() - pending.createdAt > 120000) {
    await chrome.storage.local.remove(RELOAD_PENDING_KEY);
    return false;
  }
  const entries = await workbenchEntries();
  const tabIds = [...new Set([pending.tabId, ...(Array.isArray(pending.tabIds) ? pending.tabIds : [])])]
    .filter(Number.isInteger).slice(0, 30);
  const previousWorkbenchIds = new Set((Array.isArray(pending.workbenchTabIds)
    ? pending.workbenchTabIds : tabIds.filter(id => id !== pending.tabId)).filter(id => tabIds.includes(id)));
  // Restore and reserve the user's original workbench before any launcher is
  // allowed to become a new one. A resolved tabs.update does not mean its new
  // document is already visible to getContexts.
  const restorationOrder = [...tabIds.filter(id => previousWorkbenchIds.has(id)),
    ...tabIds.filter(id => !previousWorkbenchIds.has(id))];
  let restored = false;
  let restoredLauncher = false;
  for (const tabId of restorationOrder) {
    let tab;
    try { tab = await chrome.tabs.get(tabId); } catch { continue; }
    if (!tab || !await canRestoreReloadTab(tab, entries)) continue;
    // Edge changes extension pages into its new-tab page during runtime.reload.
    // Restore only the IDs recorded before reload, and never a user-navigated site.
    const restoreAsWorkbench = previousWorkbenchIds.has(tabId) && tabId !== pending.tabId;
    if (restoreAsWorkbench && !pendingWorkbenchNavigation) {
      pendingWorkbenchNavigation = { id: tabId, createdAt: Date.now() };
    }
    await chrome.tabs.update(tabId, { url: restoreAsWorkbench ? WORKBENCH_URL : LAUNCH_URL, active: tabId === pending.tabId });
    if (!restoreAsWorkbench) restoredLauncher = true;
    restored = true;
  }
  if (pendingWorkbenchNavigation) pendingWorkbenchNavigation.createdAt = Date.now();
  if (!restored) await openWorkbenchFromAction();
  else if (!restoredLauncher) await chrome.storage.local.remove(RELOAD_PENDING_KEY);
  return true;
})().catch(() => false);

chrome.runtime.onInstalled.addListener((details) => {
  reloadRecovery.then(recovered => {
    if (!recovered && details.reason === 'install') return openWorkbenchFromAction();
  }).catch(error => console.warn('无法打开智囊入口', error));
});

// 平台主域名清单（content.js 内也有一份，注入时按帧 URL 过滤）
const HOSTS = [
  'www.doubao.com', 'doubao.com', 'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
  'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
];

const CHANNEL_PREFIX = 'wb-channel-';
const WORKBENCH_TABS_KEY = 'wb-workbench-tabs';
const FRAME_RULE_ID = 9001;
const FRAME_REQUEST_DOMAINS = [
  'appleid.apple.com', 'auth.openai.com', 'chat.deepseek.com', 'chat.openai.com',
  'chatgpt.com', 'doubao.com', 'www.doubao.com', 'kimi.moonshot.cn', 'open.weixin.qq.com', 'passport.baidu.com',
  'wenxin.baidu.com', 'www.kimi.com', 'www.moonshot.cn', 'www.qianwen.com',
  'www.tongyi.com', 'yiyan.baidu.com'
];
let frameRuleUpdate = Promise.resolve();

function mutateWorkbenchTabs(mutator) {
  frameRuleUpdate = frameRuleUpdate.then(async () => {
    const stored = await chrome.storage.session.get(WORKBENCH_TABS_KEY);
    const tabs = new Set((stored[WORKBENCH_TABS_KEY] || []).filter(Number.isInteger));
    mutator(tabs);
    const tabIds = [...tabs];
    await chrome.storage.session.set({ [WORKBENCH_TABS_KEY]: tabIds });
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: [FRAME_RULE_ID],
      addRules: tabIds.length ? [{
        id: FRAME_RULE_ID,
        priority: 1,
        action: {
          type: 'modifyHeaders',
          responseHeaders: [
            { header: 'x-frame-options', operation: 'remove' },
            { header: 'content-security-policy', operation: 'remove' }
          ]
        },
        condition: {
          tabIds,
          requestDomains: FRAME_REQUEST_DOMAINS,
          resourceTypes: ['sub_frame']
        }
      }] : []
    });
  });
  return frameRuleUpdate;
}

function trustedWorkbenchSender(sender) {
  return sender?.id === chrome.runtime.id && sender.frameId === 0 && sender.url === WORKBENCH_URL && Number.isInteger(sender.tab?.id);
}

function validatedDeepSeekCallback(raw) {
  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || url.hostname !== 'chat.deepseek.com') return null;
    if (url.pathname !== '/api/v0/users/oauth/wechat/callback') return null;
    if (url.username || url.password || url.hash) return null;
    const code = url.searchParams.get('code') || '';
    const state = url.searchParams.get('state') || '';
    if (!code || code.length > 512 || state.length > 512) return null;
    return url.href;
  } catch {
    return null;
  }
}

async function attachDebugger(tabId, timeoutMs) {
  return await new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      settled = true;
      reject(new Error('调试器连接超时'));
    }, timeoutMs);
    chrome.debugger.attach({ tabId }, '1.3', () => {
      const error = chrome.runtime.lastError;
      if (settled) {
        if (!error) chrome.debugger.detach({ tabId }, () => {});
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (error) reject(new Error(error.message));
      else resolve(true);
    });
  });
}

async function dispatchAttachment(tabId, msg) {
  const { x, y, items, mask } = msg;
  if (typeof x !== 'number' || typeof y !== 'number' || !Array.isArray(items)) {
    return { ok: false, error: 'bad-args' };
  }
  await attachDebugger(tabId, 5000);
  const send = (method, params) => new Promise((resolve, reject) => {
    chrome.debugger.sendCommand({ tabId }, method, params, (result) => {
      const error = chrome.runtime.lastError;
      if (error) reject(new Error(error.message));
      else resolve(result);
    });
  });
  try {
    await send('Page.enable');
    // CDP 只能投递 MIME 数据；真实 File 需要本机文件路径，因此本通道始终是尽力而为。
    const data = {
      items: items.map(it => ({ mimeType: it.mime, data: it.data })),
      dragOperationsMask: typeof mask === 'number' ? mask : 1
    };
    const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
    await send('Input.dispatchDragEvent', { type: 'dragEnter', x, y, data });
    await sleep(150);
    await send('Input.dispatchDragEvent', { type: 'dragOver', x, y, data });
    await sleep(100);
    await send('Input.dispatchDragEvent', { type: 'drop', x, y, data });
    return { ok: true };
  } finally {
    chrome.debugger.detach({ tabId }, () => {});
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg !== 'object') return false;

  if (msg.type === 'WB_LAUNCH_READY') {
    if (sender?.id !== chrome.runtime.id || sender.frameId !== 0 || sender.url !== LAUNCH_URL || !Number.isInteger(sender.tab?.id)) {
      sendResponse({ ok: false });
      return false;
    }
    reloadRecovery.then(() => serializeEntry(async () => {
      const entries = await workbenchEntries();
      let existing = entries.find(tab => tab.id !== sender.tab.id && tab.url === WORKBENCH_URL);
      // tabs.update resolves before the new document context appears. Reserve
      // that own tab during the transition so simultaneous launches cannot both win.
      if (!existing && pendingWorkbenchNavigation?.id !== sender.tab.id &&
          Date.now() - (pendingWorkbenchNavigation?.createdAt || 0) < 5000) {
        try {
          const tab = await chrome.tabs.get(pendingWorkbenchNavigation.id);
          if (tab && entries.some(entry => entry.id === tab.id)) {
            existing = tab;
          } else if (tab) {
            const frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
            const topURL = (frames || []).find(frame => frame.frameId === 0)?.url || tab.pendingUrl || tab.url;
            if (!topURL || [WORKBENCH_URL, LAUNCH_URL].includes(topURL) || isReloadLandingURL(topURL)) existing = tab;
          }
        } catch { pendingWorkbenchNavigation = null; }
      }
      await chrome.storage.local.remove(RELOAD_PENDING_KEY);
      if (existing) {
        await focusWorkbench(existing);
        await chrome.tabs.remove(sender.tab.id);
      } else {
        pendingWorkbenchNavigation = { id: sender.tab.id, createdAt: Date.now() };
        await chrome.tabs.update(sender.tab.id, { url: WORKBENCH_URL, active: true });
      }
    })).then(() => sendResponse({ ok: true })).catch(() => sendResponse({ ok: false }));
    return true;
  }

  if (msg.type === 'WB_REGISTER_WORKBENCH') {
    if (!trustedWorkbenchSender(sender) || typeof msg.channelToken !== 'string' || msg.channelToken.length < 20) {
      sendResponse({ ok: false });
      return false;
    }
    Promise.all([
      chrome.storage.session.set({ [CHANNEL_PREFIX + sender.tab.id]: msg.channelToken }),
      mutateWorkbenchTabs(tabs => tabs.add(sender.tab.id))
    ])
      .then(() => sendResponse({ ok: true, tabId: sender.tab.id }))
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

  if (msg.type === 'WB_AUTH_CALLBACK_CANDIDATE') {
    const senderURL = (() => { try { return new URL(sender.url || ''); } catch { return null; } })();
    const callback = validatedDeepSeekCallback(msg.url);
    if (sender?.id !== chrome.runtime.id || senderURL?.origin !== 'https://open.weixin.qq.com' ||
        senderURL.pathname !== '/connect/qrconnect' || sender.tab?.url !== WORKBENCH_URL || !callback) {
      sendResponse({ ok: false });
      return false;
    }
    chrome.storage.session.get(CHANNEL_PREFIX + sender.tab.id).then((stored) => {
      const channelToken = stored[CHANNEL_PREFIX + sender.tab.id];
      if (!channelToken) { sendResponse({ ok: false }); return; }
      chrome.runtime.sendMessage({
        type: 'WB_AUTH_CALLBACK_TRUSTED',
        provider: 'deepseek-wechat',
        tabId: sender.tab.id,
        channelToken,
        url: callback
      }).catch(() => {});
      sendResponse({ ok: true });
    }).catch(() => sendResponse({ ok: false }));
    return true;
  }

  if (msg.type === 'WB_ATTACH') {
    if (!trustedWorkbenchSender(sender) || msg.tabId !== sender.tab.id) {
      sendResponse({ ok: false, error: 'untrusted-sender' });
      return false;
    }
    dispatchAttachment(sender.tab.id, msg)
      .then(sendResponse)
      .catch(error => sendResponse({ ok: false, error: String(error) }));
    return true;
  }

  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  chrome.storage.session.remove(CHANNEL_PREFIX + tabId).catch(() => {});
  mutateWorkbenchTabs(tabs => tabs.delete(tabId)).catch(() => {});
});
