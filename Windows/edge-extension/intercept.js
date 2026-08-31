// 主世界拦截脚本（manifest content_scripts：document_start + MAIN world + 全帧）：
// 仅在「嵌入平行工作台的帧」内激活（ancestorOrigins 检查），普通标签页完全不受影响。
// 作用：把 window.open 与 target=_blank/_top 的导航圈禁在本 frame 内，
// 防止扫码登录等新窗口流程把用户带离平行工作台。
// 顶层导航（top.location / target=_top 表单）由工作台 iframe 的 sandbox（缺省 allow-top-navigation）从源头阻止。
(() => {
  // 仅当父链顶端是平行工作台扩展页时激活
  let insideWorkbench = false;
  try {
    const ancestors = window.location.ancestorOrigins || [];
    for (let i = 0; i < ancestors.length; i++) {
      if (String(ancestors[i]).startsWith('chrome-extension://')) { insideWorkbench = true; break; }
    }
  } catch {}
  if (!insideWorkbench) return;

  // DeepSeek 的微信 QR 页在用户确认授权后会执行 window.top.location = callback。
  // 外层平台 iframe 必须保留 sandbox，不能允许 QR 子帧导航整个工作台；因此在 MAIN world
  // 读取微信长轮询写入的 wx_errcode/wx_code，并把严格限定的 callback 交给隔离世界桥接。
  (() => {
    try {
      const here = new URL(location.href);
      if (here.origin !== 'https://open.weixin.qq.com' || here.pathname !== '/connect/qrconnect') return;
      const rawRedirect = here.searchParams.get('redirect_uri') || '';
      const redirect = new URL(rawRedirect);
      if (redirect.origin !== 'https://chat.deepseek.com' ||
          redirect.pathname !== '/api/v0/users/oauth/wechat/callback') return;

      let delivered = false;
      const timer = setInterval(() => {
        if (delivered || Number(window.wx_errcode) !== 405) return;
        const code = typeof window.wx_code === 'string' ? window.wx_code : '';
        if (!code || code.length > 512) return;
        const callback = new URL(redirect.href);
        callback.searchParams.set('code', code);
        callback.searchParams.set('state', here.searchParams.get('state') || '');
        delivered = true;
        clearInterval(timer);
        window.postMessage({
          channel: 'parallel-workbench-auth-v1',
          type: 'DEEPSEEK_WECHAT_CALLBACK',
          url: callback.href
        }, here.origin);
      }, 50);
      window.addEventListener('pagehide', () => clearInterval(timer), { once: true });
    } catch {}
  })();

  if (window.__wb_open_intercepted) return;
  window.__wb_open_intercepted = true;

  const stayInFrame = (url) => {
    try {
      if (typeof url === 'string' && url && !url.startsWith('javascript:')) {
        location.href = url;
        return true;
      }
    } catch {}
    return false;
  };

  try {
    const origOpen = window.open;
    window.open = function (url, name, features) {
      if (stayInFrame(url)) return window;
      return origOpen.apply(this, arguments);
    };
  } catch {}

  // 捕获 target=_blank / _top 链接（跨域 iframe 里同样会逃逸成新标签页或整页跳转）
  document.addEventListener('click', (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[target="_blank"], a[target="_top"]') : null;
    if (a) {
      e.preventDefault();
      stayInFrame(a.href);
    }
  }, true);

  // 捕获 target=_top 表单提交（sandbox 会直接拦掉顶层提交，改为帧内提交）
  document.addEventListener('submit', (e) => {
    const f = e.target;
    if (f && f.tagName === 'FORM' && f.target === '_top') {
      e.preventDefault();
      f.target = '_self';
      f.submit();
    }
  }, true);
})();
