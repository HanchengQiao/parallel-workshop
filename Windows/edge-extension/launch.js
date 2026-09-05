(() => {
  'use strict';
  if (window.self !== window.top) return;
  const PENDING_KEY = 'wb-pending-extension-reload';
  const progress = document.getElementById('launch-progress');
  const status = document.getElementById('launch-status');
  const version = document.getElementById('launch-version');
  const retry = document.getElementById('launch-retry');
  const help = document.getElementById('launch-help');
  let launching = false;

  function show(step, message) {
    progress.value = step;
    status.textContent = message;
  }

  async function launch() {
    if (launching) return;
    launching = true;
    retry.hidden = true;
    help.hidden = true;
    let timer;
    try {
      const runningVersion = chrome.runtime.getManifest().version;
      version.textContent = `v${runningVersion}`;
      show(1, '正在确认已安装版本…');
      const controller = new AbortController();
      timer = setTimeout(() => controller.abort(), 8000);
      const response = await fetch(chrome.runtime.getURL('manifest.json'), { cache: 'no-store', signal: controller.signal });
      if (!response.ok) throw new Error('无法读取已安装版本');
      const installed = await response.json();
      clearTimeout(timer);
      if (!/^\d+\.\d+\.\d+(?:\.\d+)?$/.test(installed.version || '')) throw new Error('安装文件尚未就绪');
      if (installed.version !== runningVersion) {
        const stored = await chrome.storage.local.get(PENDING_KEY);
        const previous = stored[PENDING_KEY];
        if (previous?.version === installed.version && Date.now() - previous.createdAt < 120000) {
          throw new Error('Edge 还未载入更新，请重新加载扩展后再试');
        }
        const tab = await chrome.tabs.getCurrent();
        if (!Number.isInteger(tab?.id)) throw new Error('无法恢复当前窗口');
        const contexts = await chrome.runtime.getContexts({ contextTypes: ['TAB'] });
        const entryURLs = [chrome.runtime.getURL('workbench.html'), chrome.runtime.getURL('launch.html')];
        const tabIds = contexts.filter(context => context.frameId === 0 && entryURLs.includes(context.documentUrl))
          .map(context => context.tabId).filter(Number.isInteger).slice(0, 30);
        await chrome.storage.local.set({ [PENDING_KEY]: { tabId: tab.id, tabIds, version: installed.version, createdAt: Date.now() } });
        show(2, `正在启用 v${installed.version}…`);
        chrome.runtime.reload();
        return;
      }
      show(3, '已就绪，正在进入工作台…');
      // The background focuses a running workbench, or navigates this exact tab.
      // It never opens an empty warming tab or creates an extra window first.
      const reply = await chrome.runtime.sendMessage({ type: 'WB_LAUNCH_READY' });
      if (!reply?.ok) throw new Error('启动尚未完成，请重试');
    } catch (error) {
      show(0, error?.name === 'AbortError' ? '读取安装信息超时，请重试' : (error?.message || '暂时无法打开智囊'));
      retry.hidden = false;
      help.hidden = false;
    } finally {
      clearTimeout(timer);
      launching = false;
    }
  }

  retry.addEventListener('click', launch);
  launch();
})();
