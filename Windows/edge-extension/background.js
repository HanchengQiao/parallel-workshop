// 后台：点击图标打开工作台窗口；按需把 content.js 精准注入各平台 frame
chrome.action.onClicked.addListener(() => {
  // 先开空白窗口再导航：避免"导航先于扩展注册"被 ERR_BLOCKED_BY_CLIENT
  chrome.windows.create({ url: 'about:blank', type: 'popup', width: 1500, height: 950 }, (win) => {
    if (win?.tabs?.[0]?.id) {
      chrome.tabs.update(win.tabs[0].id, { url: chrome.runtime.getURL('workbench.html') });
    }
  });
});

// 平台主域名清单（content.js 内也有一份，注入时按帧 URL 过滤）
const HOSTS = [
  'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
  'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
];

// 可信附件注入：CDP Input.dispatchDragEvent 在「页面坐标」派发拖放。
// 坐标由工作台页面算好传入（iframe 框位置 × CSS zoom + 帧内编辑器中心），
// 浏览器命中测试会跨 OOPIF 把事件投进对应 frame 的编辑器。
// 注意：Edge 152 下 Page.getFrameTree 对 chrome-extension 页面里的跨域 iframe（OOPIF）
// 不返回子帧，帧树发现不可用，因此这里完全不依赖帧树/执行上下文发现。
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type !== 'WB_ATTACH') return false;
  const { tabId, x, y, items, mask } = msg;
  if (typeof x !== 'number' || typeof y !== 'number' || !Array.isArray(items)) {
    sendResponse({ ok: false, error: 'bad-args' });
    return false;
  }
  (async () => {
    const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('超时')), ms))]);
    try {
      await withTimeout(new Promise((resolve, reject) => {
        chrome.debugger.attach({ tabId }, '1.3', () => {
          if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
          else resolve(true);
        });
      }), 5000);
      const send = (method, params) => new Promise((res, rej) => {
        chrome.debugger.sendCommand({ tabId }, method, params, (result) => {
          if (chrome.runtime.lastError) rej(new Error(chrome.runtime.lastError.message));
          else res(result);
        });
      });
      try {
        await send('Page.enable');
        // 注意：CDP 拖放只能投递 MIME 数据项；真实 File 需要 DragData.files（磁盘路径），
        // 扩展无文件系统权限无法提供。因此本通道是「尽力而为」，平台不接受时由工作台诚实降级提示。
        const data = {
          items: items.map(it => ({ mimeType: it.mime, data: it.data, title: it.name || 'attachment' })),
          dragOperationsMask: typeof mask === 'number' ? mask : 1
        };
        // 事件间留间隔：浏览器拖放状态机与页面处理器（拖入高亮/布局变化）需要时间消化
        const sleep = (ms) => new Promise(r => setTimeout(r, ms));
        await send('Input.dispatchDragEvent', { type: 'dragEnter', x, y, data });
        await sleep(150);
        await send('Input.dispatchDragEvent', { type: 'dragOver', x, y, data });
        await sleep(100);
        await send('Input.dispatchDragEvent', { type: 'dragOver', x, y, data });
        await sleep(150);
        await send('Input.dispatchDragEvent', { type: 'drop', x, y, data });
        sendResponse({ ok: true });
      } finally {
        chrome.debugger.detach({ tabId }, () => {});
      }
    } catch (e) {
      sendResponse({ ok: false, error: String(e) });
    }
  })();
  return true; // 异步 sendResponse
});
