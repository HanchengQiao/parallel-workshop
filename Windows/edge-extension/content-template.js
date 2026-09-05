// 内容脚本模板：由 build-edge-extension.sh 生成 content.js。
// 共享核心（inject.js/probe.js）在构建时转换为普通函数（__wbInject/__wbProbe）内嵌进来，
// 不使用 eval —— 内容脚本的 eval 受宿主页面 CSP 约束（'unsafe-eval' 会被拒绝）。
(async () => {
  if (window.__wb_content_installed) return;
  const HOSTS = [
    'www.doubao.com', 'doubao.com', 'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
    'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
  ];
  if (!HOSTS.some(h => location.hostname === h || location.hostname.endsWith('.' + h))) return;
  window.__wb_content_installed = true;
  document.documentElement.setAttribute('data-wb-content', '1');

  // __WB_FUNCTIONS__ 由构建脚本替换为 __wbInject/__wbProbe 两个函数定义

  const workbenchURL = chrome.runtime.getURL('workbench.html');

  chrome.runtime.onMessage.addListener((d, sender, sendResponse) => {
    if (!d || typeof d !== 'object' || !d.frameId) return false;
    if (sender.id !== chrome.runtime.id || sender.url !== workbenchURL) return false;
    if (!['WB_INJECT', 'WB_PROBE', 'WB_ATTACH_CHECK'].includes(d.type)) return false;
    document.documentElement.setAttribute('data-wb-last-msg', d.type + '@' + Date.now());

    (async () => {
      try {
        if (d.type === 'WB_INJECT') {
          const result = await __wbInject(d.cfg);
          sendResponse({ frameId: d.frameId, rid: d.rid, result });
        } else if (d.type === 'WB_PROBE') {
          const result = __wbProbe(d.cfg);
          sendResponse({ frameId: d.frameId, result });
        } else if (d.type === 'WB_ATTACH_CHECK') {
        // 隔离世界可读宿主 DOM（跨域 frame 也可读）：验证附件是否被平台接受（上传卡/文件名可见），
        // 并报告页面里可用的文件输入框（供适配器补全选择器、供诊断）。
        const bodyText = (document.body ? document.body.innerText : '') || '';
        const names = d.names || [];
        let fileInputs = [];
        try {
          fileInputs = Array.from(document.querySelectorAll('input[type=file]')).slice(0, 8).map((i) => ({
            cls: (typeof i.className === 'string' ? i.className : '').slice(0, 60),
            id: i.id || '',
            accept: i.accept || '',
            name: i.name || ''
          }));
        } catch {}
          sendResponse({
            frameId: d.frameId,
            result: { attached: names.some((n) => bodyText.includes(n)), fileInputs }
          });
        }
      } catch (e) {
        sendResponse({ frameId: d.frameId, rid: d.rid, result: { ok: false, error: String(e) } });
      }
    })();
    return true;
  });
})();
