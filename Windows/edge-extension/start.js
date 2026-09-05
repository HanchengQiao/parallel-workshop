(() => {
  'use strict';
  // This local file paints before Edge finishes loading extensions. It waits for
  // the actual extension resource, never a fixed warm-up delay or an empty tab.
  // workbench.html was already public in older releases, so this also upgrades
  // an installed 0.3.x extension whose in-memory manifest does not know launch.
  const launchURL = 'chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html';
  const status = document.getElementById('launch-status');
  const progress = document.getElementById('launch-progress');
  const retry = document.getElementById('launch-retry');
  const help = document.getElementById('launch-help');
  let active = false;

  async function connect() {
    if (active) return;
    active = true;
    retry.hidden = true;
    help.hidden = true;
    progress.value = 1;
    status.textContent = '正在连接 Edge 中的智囊…';
    const deadline = Date.now() + 15000;
    do {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 1500);
      try {
        const response = await fetch(launchURL, { cache: 'no-store', signal: controller.signal });
        if (response.ok) {
          progress.value = 2;
          status.textContent = '智囊已就绪，正在打开…';
          window.location.replace(`${launchURL}#launch`);
          return;
        }
      } catch { /* Retry only until extension registration is ready. */ }
      finally { clearTimeout(timer); }
      await new Promise(resolve => setTimeout(resolve, 200));
    } while (Date.now() < deadline);
    progress.value = 0;
    status.textContent = '暂未连接到智囊，请确认当前 Edge 用户已启用扩展';
    retry.hidden = false;
    help.hidden = false;
    active = false;
  }

  retry.addEventListener('click', connect);
  connect();
})();
