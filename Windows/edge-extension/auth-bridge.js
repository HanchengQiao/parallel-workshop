// 隔离世界认证桥：页面 MAIN world 无法访问 chrome.runtime。
// 这里只转发经过严格 origin/path/code 校验的 DeepSeek 微信 callback 候选。
(() => {
  const CHANNEL = 'parallel-workbench-auth-v1';
  let delivered = false;

  function validatedCallback(raw) {
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

  window.addEventListener('message', (event) => {
    if (delivered || event.source !== window || event.origin !== 'https://open.weixin.qq.com') return;
    const data = event.data;
    if (!data || data.channel !== CHANNEL || data.type !== 'DEEPSEEK_WECHAT_CALLBACK') return;
    const url = validatedCallback(data.url);
    if (!url) return;
    delivered = true;
    chrome.runtime.sendMessage({
      type: 'WB_AUTH_CALLBACK_CANDIDATE',
      provider: 'deepseek-wechat',
      url
    }).catch(() => { delivered = false; });
  });
})();
