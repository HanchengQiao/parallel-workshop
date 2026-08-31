// 后台：点击图标打开工作台窗口；按需把 content.js 精准注入各平台 frame
chrome.action.onClicked.addListener(() => {
  // action 回调只会在扩展注册完成后触发，可直接打开工作台；不要展示 blank 预热页。
  chrome.windows.create({
    url: chrome.runtime.getURL('workbench.html'),
    type: 'popup',
    width: 1500,
    height: 950
  });
});

// 平台主域名清单（content.js 内也有一份，注入时按帧 URL 过滤）
const HOSTS = [
  'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
  'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
];

const WORKBENCH_URL = chrome.runtime.getURL('workbench.html');
const CHANNEL_PREFIX = 'wb-channel-';
const WORKBENCH_TABS_KEY = 'wb-workbench-tabs';
const FRAME_RULE_ID = 9001;
const FRAME_REQUEST_DOMAINS = [
  'appleid.apple.com', 'auth.openai.com', 'chat.deepseek.com', 'chat.openai.com',
  'chatgpt.com', 'kimi.moonshot.cn', 'open.weixin.qq.com', 'passport.baidu.com',
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
  return sender?.id === chrome.runtime.id && sender.url === WORKBENCH_URL && Number.isInteger(sender.tab?.id);
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
