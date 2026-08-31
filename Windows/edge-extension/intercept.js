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
