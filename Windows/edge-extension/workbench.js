// 工作台页面：与 macOS 版对齐 —— 平台勾选（参与显示与发送）、最多同时显示 3 个窗格
// （超出分页导航）、发送给全部勾选平台（不可见的窗格以离屏方式保持活跃）、错误可见化。
(async () => {
  const adapters = await fetch(chrome.runtime.getURL('lib/adapters/index.json')).then(r => r.json());
  const MAX_VISIBLE = 3;

  // 平台主域名映射（WB_ATTACH CDP 拖放按 host 定位 frame）
  const FRAME_HOSTS = {};
  for (const a of adapters) {
    try { FRAME_HOSTS[a.id] = new URL(a.origin).hostname; } catch {}
  }

  const panesEl = document.getElementById('panes');
  const checksEl = document.getElementById('checks');
  const pagingEl = document.getElementById('paging');
  const pageIndEl = document.getElementById('page-ind');
  const pageLeftEl = document.getElementById('page-left');
  const pageRightEl = document.getElementById('page-right');
  const progressEl = document.getElementById('progress');
  const questionEl = document.getElementById('question');
  const sendEl = document.getElementById('send');

  const enabled = new Set(adapters.map(a => a.id));
  const attachBtnEl = document.getElementById('attach-btn');
  const attachChipsEl = document.getElementById('attach-chips');
  const fileInputEl = document.getElementById('file-input');
  const attachments = [];   // { name, mime, data(base64), size }
  let windowStart = 0;
  const frames = {};    // id -> { frame, adapter }
  const lastSeen = {};  // id -> 最近一次探测响应时间戳
  const zooms = {};     // id -> 缩放倍数（CSS zoom 缩放 iframe，解决平台界面裁切）
  const authChannelToken = crypto.randomUUID();
  let workbenchTab = null;
  let sending = false;

  function applyZoom(id, z) {
    zooms[id] = Math.min(1.3, Math.max(0.6, z));
    const f = frames[id]?.frame;
    if (f) f.style.zoom = String(zooms[id]);
    const el = document.getElementById('zoom-' + id);
    if (el) el.textContent = Math.round(zooms[id] * 100) + '%';
  }

  panesEl.addEventListener('click', (e) => {
    const btn = e.target.closest('.zoom-btn');
    if (!btn) return;
    const id = btn.dataset.id;
    const cur = zooms[id] ?? 1;
    if (btn.classList.contains('zoom-in')) applyZoom(id, cur + 0.1);
    else applyZoom(id, cur - 0.1);
  });
  panesEl.addEventListener('click', (e) => {
    if (!e.target.classList?.contains('zoom-val')) return;
    applyZoom(e.target.id.replace('zoom-', ''), 1);
  });

  const enabledList = () => adapters.filter(a => enabled.has(a.id));

  // —— 勾选框 ——
  function renderChecks() {
    checksEl.innerHTML = '';
    for (const a of adapters) {
      const label = document.createElement('label');
      label.className = 'check';
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = enabled.has(a.id);
      cb.addEventListener('change', () => {
        if (cb.checked) enabled.add(a.id); else enabled.delete(a.id);
        windowStart = Math.min(windowStart, Math.max(enabledList().length - MAX_VISIBLE, 0));
        renderPanes();
      });
      const span = document.createElement('span');
      span.textContent = a.name;
      label.appendChild(cb);
      label.appendChild(span);
      checksEl.appendChild(label);
    }
  }

  // —— 窗格渲染 ——
  // 增量策略：勾选集合变化时只增删对应窗格；翻页只调整可见/离屏布局（不重建 iframe，
  // 平台页面状态、回答位置、草稿全部保留）。

  function makePane(a) {
    const pane = document.createElement('div');
    pane.className = 'pane offscreen';
    pane.innerHTML = `
      <header>
        <span class="name">${a.name}</span>
        <span class="badge loading" id="badge-${a.id}">加载中</span>
        <span class="spacer"></span>
        <button class="zoom-btn zoom-out" data-id="${a.id}" title="缩小页面（适应窗格宽度）">−</button>
        <span class="zoom-val" id="zoom-${a.id}" title="点击恢复 100%">100%</span>
        <button class="zoom-btn zoom-in" data-id="${a.id}" title="放大页面">＋</button>
      </header>
      <iframe id="frame-${a.id}" src="${a.origin}" sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-downloads allow-modals"></iframe>
      <div class="toast" id="toast-${a.id}" style="display:none"></div>`;
    return pane;
  }

  // 勾选集合变化时同步窗格（保留未变化的 iframe；被取消勾选的窗格销毁并清理状态）
  function syncPanes() {
    const list = enabledList();
    const wanted = new Set(list.map(a => a.id));
    // 清理已取消勾选的窗格
    for (const [id, p] of Object.entries(frames)) {
      if (!wanted.has(id)) {
        p.frame.closest('.pane').remove();
        delete frames[id];
        delete lastSeen[id];
      }
    }
    // 清理空态提示
    panesEl.querySelectorAll('.empty').forEach(e => e.remove());
    if (list.length === 0) {
      const d = document.createElement('div');
      d.className = 'empty';
      d.textContent = '未勾选任何模型 — 在上方勾选要参与的平台';
      panesEl.appendChild(d);
      return;
    }
    // 新建缺失的窗格
    for (const a of list) {
      if (frames[a.id]) continue;
      const pane = makePane(a);
      panesEl.appendChild(pane);
      frames[a.id] = { frame: pane.querySelector('iframe'), adapter: a };
      lastSeen[a.id] = 0;
      applyZoom(a.id, zooms[a.id] ?? 1);
    }
  }

  // 翻页布局：只改 CSS，绝不 remove/append iframe；重挂 DOM 会销毁浏览上下文。
  function layoutPanes() {
    const list = enabledList();
    const start = Math.min(windowStart, Math.max(list.length - MAX_VISIBLE, 0));
    const visibleIds = new Set(list.slice(start, start + MAX_VISIBLE).map(a => a.id));
    for (let index = 0; index < list.length; index += 1) {
      const a = list[index];
      const p = frames[a.id];
      if (!p) continue;
      const paneEl = p.frame.closest('.pane');
      paneEl.classList.toggle('offscreen', !visibleIds.has(a.id));
      paneEl.style.order = String(index);
    }
    updatePaging();
  }

  function renderPanes() {
    syncPanes();
    layoutPanes();
  }

  function updatePaging() {
    const n = enabledList().length;
    const show = n > MAX_VISIBLE;
    pagingEl.style.display = show ? '' : 'none';
    if (!show) return;
    const start = Math.min(windowStart, Math.max(n - MAX_VISIBLE, 0));
    pageIndEl.textContent = `${start + 1}-${Math.min(start + MAX_VISIBLE, n)} / ${n}`;
    pageLeftEl.disabled = windowStart === 0;
    pageRightEl.disabled = windowStart >= n - MAX_VISIBLE;
  }

  pageLeftEl.addEventListener('click', () => { windowStart = Math.max(0, windowStart - 1); layoutPanes(); });
  pageRightEl.addEventListener('click', () => { windowStart += 1; layoutPanes(); });

  // —— 附件交互 ——
  function renderChips() {
    attachChipsEl.innerHTML = '';
    for (const a of attachments) {
      const chip = document.createElement('span');
      chip.className = 'chip';
      const name = document.createElement('span');
      name.textContent = '📄 ' + a.name;
      const remove = document.createElement('button');
      remove.textContent = '✕';
      remove.addEventListener('click', () => {
        const i = attachments.indexOf(a);
        if (i >= 0) attachments.splice(i, 1);
        renderChips();
        sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
      });
      chip.append(name, remove);
      attachChipsEl.appendChild(chip);
    }
  }
  async function addFile(file) {
    if (!file) return;
    if (file.size > 25 * 1024 * 1024 ||
        attachments.reduce((sum, item) => sum + (item.size || 0), 0) + file.size > 50 * 1024 * 1024) {
      progressEl.textContent = '⚠️ 单个附件上限 25MB，总附件上限 50MB';
      setTimeout(() => { progressEl.textContent = ''; }, 5000);
      return;
    }
    const data = await new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(',')[1] || '');
      r.onerror = () => reject(r.error || new Error('文件读取失败'));
      r.readAsDataURL(file);
    }).catch(() => '');
    if (!data) {
      progressEl.textContent = '⚠️ 文件读取失败：' + file.name;
      return;
    }
    attachments.push({ name: file.name, mime: file.type || 'application/octet-stream', data, size: file.size });
    renderChips();
    sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
  }
  attachBtnEl.addEventListener('click', () => fileInputEl.click());
  fileInputEl.addEventListener('change', async () => {
    for (const f of Array.from(fileInputEl.files || [])) await addFile(f);
    fileInputEl.value = '';
  });
  questionEl.addEventListener('dragover', (e) => { e.preventDefault(); });
  questionEl.addEventListener('drop', async (e) => {
    e.preventDefault();
    for (const f of Array.from(e.dataTransfer?.files || [])) await addFile(f);
  });
  document.addEventListener('paste', async (e) => {
    const items = Array.from(e.clipboardData?.items || []);
    for (const it of items) {
      if (it.type.startsWith('image/')) {
        const f = it.getAsFile();
        if (f) {
          if (!f.name) {
            const named = new File([f], '粘贴图片-' + Date.now() + '.png', { type: f.type });
            await addFile(named);
          } else await addFile(f);
        }
      }
    }
  });

  // —— 语音输入（Web Speech API，Edge/Chrome 内置）——
  const micEl = document.getElementById('mic');
  let recognition = null;
  let voiceBaseline = '';
  micEl.addEventListener('click', () => {
    if (recognition) {
      recognition.stop();
      recognition = null;
      micEl.classList.remove('rec');
      return;
    }
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) {
      progressEl.textContent = '⚠️ 当前浏览器不支持语音识别';
      setTimeout(() => { progressEl.textContent = ''; }, 4000);
      return;
    }
    recognition = new SR();
    recognition.lang = 'zh-CN';
    recognition.interimResults = true;
    recognition.continuous = true;
    voiceBaseline = questionEl.value;
    recognition.onresult = (e) => {
      let t = '';
      for (const r of e.results) t += r[0].transcript;
      questionEl.value = voiceBaseline + (voiceBaseline.trim() ? ' ' : '') + t;
      questionEl.dispatchEvent(new Event('input', { bubbles: true }));
    };
    recognition.onerror = (e) => {
      if (e.error === 'not-allowed') {
        progressEl.textContent = '⚠️ 请允许麦克风权限';
        setTimeout(() => { progressEl.textContent = ''; }, 4000);
      }
      recognition = null;
      micEl.classList.remove('rec');
    };
    recognition.onend = () => {
      recognition = null;
      micEl.classList.remove('rec');
    };
    recognition.start();
    micEl.classList.add('rec');
  });

  // —— 输入与发送 ——
  questionEl.addEventListener('input', () => { sendEl.disabled = !questionEl.value.trim() && attachments.length === 0; });
  questionEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
  });
  sendEl.addEventListener('click', send);

  // —— 注入保障：扩展页面直接注入（不经后台消息往返，杜绝 MV3 worker 休眠导致的挂起）——
  const HOSTS = [
    'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
    'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
  ];

  let ensureInFlight = null;
  async function ensureFrames() {
    // 互斥：多轮探测可能重叠触发 ensure，串行化避免并发注入风暴
    if (ensureInFlight) return ensureInFlight;
    ensureInFlight = (async () => {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      window.__wbEnsureLog = window.__wbEnsureLog || [];
      window.__wbEnsureLog.push('getAllFrames…');
      const frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
      window.__wbEnsureLog.push('frames:' + frames.length);
      let injected = 0;
      const errors = [];
      for (const f of frames) {
        let host = '';
        try { host = new URL(f.url || '').hostname; } catch {}
        window.__wbEnsureLog.push('frame:' + (host || '(空)') + ':' + f.frameId);
        if (!HOSTS.some(h => host === h || host.endsWith('.' + h))) continue;
        window.__wbEnsureLog.push('inject:' + host);
        const exec = (file, world) => new Promise((res, rej) => {
          const opts = { target: { tabId: tab.id, frameIds: [f.frameId] }, files: [file] };
          if (world) opts.world = world;
          try {
            chrome.scripting.executeScript(opts, (r) => {
              const err = chrome.runtime.lastError;
              if (err) rej(new Error(err.message)); else res(r);
            });
          } catch (e) { rej(e); }
        });
        const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('注入超时')), ms))]);
        // 功能脚本（隔离世界）：核心功能，单次带超时（互斥已防并发风暴）
        try {
          await withTimeout(exec('content.js', null), 4000);
          injected += 1;
          window.__wbEnsureLog.push('ok:' + host);
        } catch (e) {
          errors.push(host + ':' + String(e).slice(0, 50));
          window.__wbEnsureLog.push('err:' + host + ':' + String(e).slice(0, 60));
        }
      }
      if (errors.length) {
        progressEl.textContent = '⚠️ 注入异常: ' + errors.join('；');
        setTimeout(() => { progressEl.textContent = ''; }, 8000);
      }
      return { ok: errors.length === 0, injected, errors };
    } catch (e) {
      return null;
    }
    })();
    try {
      return await ensureInFlight;
    } finally {
      ensureInFlight = null;
    }
  }

  const probeCfg = (a) => ({ input: { selectors: a.input.selectors }, send: a.send, probe: a.probe || {}, text: '' });
  const sendCfg = (a, text, atts) => {
    const c = probeCfg(a);
    c.text = text;
    c.attachments = atts;
    if (a.attachment) c.attachment = a.attachment;
    return c;
  };

  function updateBadge(id, r) {
    const badge = document.getElementById('badge-' + id);
    if (!badge) return;
    let cls = 'ready', label = '就绪';
    if (r.challenge) { cls = 'challenge'; label = '需人工验证'; }
    else if (r.loggedOut || r.loginModal) { cls = 'loggedOut'; label = '未登录'; }
    else if (!r.input) { cls = 'inputMissing'; label = '未找到输入框'; }
    badge.className = 'badge ' + cls;
    badge.textContent = label;
  }

  function showToast(id, text) {
    const t = document.getElementById('toast-' + id);
    if (!t) return;
    t.textContent = text;
    t.style.display = '';
    setTimeout(() => { t.style.display = 'none'; }, 4000);
  }

  async function probeAll() {
    await ensureFrames();
    await Promise.all(Object.entries(frames).map(async ([id, p]) => {
      try {
        const reply = await sendFrameMessage(id, 'WB_PROBE', { cfg: probeCfg(p.adapter) }, 5000);
        if (reply?.result && reply.result.input !== undefined) {
          lastSeen[id] = Date.now();
          updateBadge(id, reply.result);
        }
      } catch {}
    }));
    // 空白/加载失败可见化：超过 25 秒无任何探测响应 → 标记「无响应」
    const now = Date.now();
    for (const id of Object.keys(frames)) {
      const badge = document.getElementById('badge-' + id);
      if (badge && lastSeen[id] > 0 && now - lastSeen[id] > 25000) {
        badge.className = 'badge dead';
        badge.textContent = '无响应';
      }
    }
  }

  async function postAndWait(id, msg, timeoutMs) {
    const reply = await sendFrameMessage(id, msg.type, msg, timeoutMs);
    return reply?.result || null;
  }

  // 按 host 列表查 OOPIF 帧 ID（webNavigation 全帧可见，含跨域 iframe）。
  // origin host 与实际帧 URL 可能不一致（重定向：tongyi.com → qianwen.com、yiyan → wenxin），按 homeHosts 兜底匹配。
  async function frameIdOfHosts(hosts) {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      const fs = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
      const matches = [];
      for (const f of fs) {
        let h = '';
        try { h = new URL(f.url || '').hostname; } catch {}
        if (hosts.some(x => h === x || h.endsWith('.' + x))) matches.push(f);
      }
      const outer = matches.find(f => f.parentFrameId === 0);
      return outer?.frameId ?? matches[0]?.frameId ?? null;
    } catch {}
    return null;
  }

  // 按适配器查帧 ID（origin host + homeHosts 全尝试）
  function frameIdOfAdapter(id) {
    const a = frames[id] && frames[id].adapter;
    if (!a) return Promise.resolve(null);
    const hosts = [];
    try { hosts.push(new URL(a.origin).hostname); } catch {}
    hosts.push(...(a.homeHosts || []));
    return frameIdOfHosts(hosts);
  }

  async function sendFrameMessage(id, type, payload = {}, timeoutMs = 6000) {
    const frameId = await frameIdOfAdapter(id);
    if (frameId == null) throw new Error('no-frame');
    workbenchTab = workbenchTab || await chrome.tabs.getCurrent();
    if (!workbenchTab?.id) throw new Error('no-tab');
    const message = { ...payload, type, frameId };
    return await Promise.race([
      chrome.tabs.sendMessage(workbenchTab.id, message, { frameId }),
      new Promise((_, reject) => setTimeout(() => reject(new Error('frame-message-timeout')), timeoutMs))
    ]);
  }

  // 帧内编辑器中心（帧坐标）。executeScript func 在目标帧的隔离世界执行，DOM 共享可查询。
  async function editorCenterInFrame(frameId) {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      return await new Promise((resolve) => {
        chrome.scripting.executeScript({
          target: { tabId: tab.id, frameIds: [frameId] },
          func: () => {
            const el = document.querySelector('[contenteditable="true"], textarea');
            if (!el) return null;
            const r = el.getBoundingClientRect();
            if (!r || (r.width === 0 && r.height === 0)) return null;
            return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
          }
        }, (res) => {
          const err = chrome.runtime.lastError;
          if (err) resolve(null);
          else resolve(res && res[0] ? res[0].result : null);
        });
      });
    } catch {}
    return null;
  }

  // CDP 拖放坐标：iframe 框（含 CSS zoom）换算帧内编辑器中心为页面坐标；
  // 离屏窗格临时移入视口左上角（命中测试需要视口内坐标），拖放后恢复。
  async function attachCoordsFor(id) {
    const ifr = document.getElementById('frame-' + id);
    if (!ifr) return { ok: false, error: 'no-iframe' };
    const frameId = await frameIdOfAdapter(id);
    if (!frameId) return { ok: false, error: 'no-frame' };
    const center = await editorCenterInFrame(frameId);
    if (!center) return { ok: false, error: 'no-editor' };
    const pane = ifr.closest('.pane');
    const wasOff = pane && pane.classList.contains('offscreen');
    if (wasOff) {
      pane.style.position = 'fixed';
      pane.style.left = '0px';
      pane.style.top = '0px';
      pane.style.zIndex = '9999';
      pane.style.opacity = '0.01';
    }
    const r = ifr.getBoundingClientRect();
    const zoom = zooms[id] ?? 1;
    const x = r.x + center.x * zoom;
    const y = r.y + center.y * zoom;
    return {
      ok: true, x, y,
      restore: wasOff ? () => {
        pane.style.position = ''; pane.style.left = ''; pane.style.top = '';
        pane.style.zIndex = ''; pane.style.opacity = '';
      } : null
    };
  }

  async function send() {
    if (sending) return;
    window.__wbAttachLog = window.__wbAttachLog || [];
    window.__wbAttachLog.push({ step: 'send-start', atts: attachments.length, text: questionEl.value.trim().slice(0, 10) });
    const text = questionEl.value.trim();
    if (!text && attachments.length === 0) return;   // 附件-only 允许发送
    sending = true;
    sendEl.disabled = true;
    attachBtnEl.disabled = true;
    const rid = crypto.randomUUID();
    const sentText = questionEl.value;
    const sentAtts = attachments.slice();
    await ensureFrames();
    window.__wbAttachLog.push({ step: 'after-ensure', atts: sentAtts.length });
    // —— 附件通道规划：有文件输入框选择器的平台走内容脚本文件赋值；其余走 CDP 拖放 ——
    // 两条通道按平台互斥，杜绝同一附件被注入两次。
    const attPlan = {};        // id -> 'input' | 'cdp'
    const cdpDispatched = {};  // id -> bool（仅 cdp 平台）
    const attNames = sentAtts.map(a => a.name);
    for (const [id, p] of Object.entries(frames)) {
      const sel = p.adapter.attachment && p.adapter.attachment.selectors;
      attPlan[id] = sel && sel.length ? 'input' : 'cdp';
    }
    const cdpAccepted = {};
    const attachmentBlocked = new Set();
    if (sentAtts.length > 0) {
      try {
        const tab = await chrome.tabs.getCurrent();
        if (tab) {
          const items = sentAtts.map(a => ({ mime: a.mime, data: a.data, name: a.name }));
          for (const [id, p] of Object.entries(frames)) {
            if (!enabled.has(id)) continue;
            const host = FRAME_HOSTS[id];
            if (!host || attPlan[id] !== 'cdp') continue;
            let restore = null;
            try {
              const coords = await attachCoordsFor(id);
              if (!coords.ok) throw new Error(coords.error);
              restore = coords.restore;
              const res = await Promise.race([
                chrome.runtime.sendMessage({ type: 'WB_ATTACH', tabId: tab.id, x: coords.x, y: coords.y, items }),
                new Promise((_, rej) => setTimeout(() => rej(new Error('附件注入超时')), 10000))
              ]);
              cdpDispatched[id] = !!(res && res.ok);
              window.__wbAttachLog.push({ id, plan: 'cdp', dispatched: cdpDispatched[id], error: res?.error || '' });
              if (!cdpDispatched[id]) {
                if (restore) restore();
                showToast(id, '附件拖放失败: ' + (res?.error || 'UNKNOWN'));
                continue;
              }
              // 派发完成立刻恢复离屏窗格位置（缩短遮挡窗口期）
              if (restore) { restore(); restore = null; }
              // 等平台消化后询问内容脚本是否真正接受（上传卡/文件名可见），诚实反馈
              await new Promise(r => setTimeout(r, 2000));
              const chk = await postAndWait(id, { type: 'WB_ATTACH_CHECK', frameId: id, names: attNames }, 3000);
              const accepted = !!(chk && chk.attached);
              cdpAccepted[id] = accepted;
              window.__wbAttachLog.push({ id, plan: 'cdp', accepted });
              showToast(id, accepted ? '附件已注入' : '附件未被平台接受，请手动添加');
              if (!accepted) attachmentBlocked.add(id);
            } catch (e) {
              cdpDispatched[id] = false;
              window.__wbAttachLog.push({ id, plan: 'cdp', dispatched: false, error: e.message });
              showToast(id, '附件失败: ' + e.message);
            }
            if (restore) restore();
            await new Promise(r => setTimeout(r, 600));
          }
        }
      } catch (e) {
        progressEl.textContent = '⚠️ 附件注入异常: ' + e;
      }
    }
    const now = Date.now();
    const jobs = [];
    let skipped = 0;
    // 发送前帧域名复核：帧若已漂移到非本平台域名，绝不把问题/附件发过去
    let frameUrlByFrameId = {};
    try {
      const tab2 = await chrome.tabs.getCurrent();
      if (tab2) {
        const fs = await chrome.webNavigation.getAllFrames({ tabId: tab2.id });
        for (const f of fs) {
          if (f && f.frameId !== undefined && f.url) frameUrlByFrameId[f.frameId] = f.url;
        }
      }
    } catch {}
    for (const [id, p] of Object.entries(frames)) {
      try {
        if (!enabled.has(id)) continue;
        if (!p.frame.contentWindow) {
          showToast(id, '失败: 页面未就绪');
          skipped += 1;
          continue;
        }
        // 域名复核：当前帧 URL 必须仍属于该平台
        if (Object.keys(frameUrlByFrameId).length > 0) {
          const fid = await frameIdOfAdapter(id);
          const curUrl = fid != null ? frameUrlByFrameId[fid] : null;
          if (curUrl) {
            const hosts = [];
            try { hosts.push(new URL(p.adapter.origin).hostname); } catch {}
            hosts.push(...(p.adapter.homeHosts || []));
            let host = '';
            try { host = new URL(curUrl).hostname; } catch {}
            if (!hosts.some(x => host === x || host.endsWith('.' + x))) {
              showToast(id, '窗格已跳转到其他页面，已跳过');
              skipped += 1;
              continue;
            }
          }
        }
        // 诚实性检查：最近 20 秒无探测响应的窗格可能尚未加载/注入，明确提示而非静默
        if (lastSeen[id] === 0 || now - lastSeen[id] > 20000) {
          showToast(id, '未就绪（页面加载中），已跳过');
          skipped += 1;
          continue;
        }
        if (attachmentBlocked.has(id)) {
          showToast(id, '附件未被接受，已跳过发送以避免漏附件');
          skipped += 1;
          continue;
        }
        const cfg = sendCfg(p.adapter, text, sentAtts);
        // 附件：仅让规划通道对应的帧保留附件（input 平台走内容脚本；cdp 平台仅在拖放派发失败时兜底）
        if (sentAtts.length > 0) {
          const keep = attPlan[id] === 'input' || (attPlan[id] === 'cdp' && !cdpDispatched[id]);
          if (!keep) { delete cfg.attachments; delete cfg.attachment; }
        }
        jobs.push((async () => {
          try {
            const reply = await sendFrameMessage(id, 'WB_INJECT', { rid, cfg }, 12000);
            const result = reply?.result || { ok: false, error: 'EMPTY_RESULT' };
            let suffix = '';
            const ai = result.attInfo;
            if (ai && ai !== 'none') {
              suffix = ai.startsWith('fileInput') ? ' · 附件已添加'
                : ai.startsWith('drop') ? ' · 附件已拖放'
                : ' · 附件: ' + ai;
            }
            showToast(id, result.ok ? ('已提交' + suffix) : ('失败: ' + (result.error || 'UNKNOWN')));
            return { id, ok: result.ok === true };
          } catch (error) {
            showToast(id, '失败: ' + String(error));
            return { id, ok: false };
          }
        })());
      } catch (e) {
        showToast(id, '失败: ' + e);
        skipped += 1;
      }
    }
    const results = await Promise.all(jobs);
    const succeeded = results.filter(r => r.ok).length;
    const failed = results.length - succeeded;
    if (succeeded > 0) {
      if (questionEl.value === sentText) questionEl.value = '';
      for (const sent of sentAtts) {
        const index = attachments.indexOf(sent);
        if (index >= 0) attachments.splice(index, 1);
      }
      renderChips();
      progressEl.textContent = `已提交 ${succeeded}/${results.length} 个窗口` +
        (failed || skipped ? `，${failed + skipped} 个失败或跳过` : '');
    } else {
      progressEl.textContent = '⚠️ 本轮没有窗口发送成功，问题与附件已保留';
    }
    setTimeout(() => { progressEl.textContent = ''; }, 6000);
    sending = false;
    attachBtnEl.disabled = false;
    sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
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

  async function verifyDeepSeekLogin() {
    for (let attempt = 0; attempt < 30; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 1000));
      await ensureFrames();
      try {
        const pane = frames.deepseek;
        if (!pane) return false;
        const reply = await sendFrameMessage('deepseek', 'WB_PROBE', { cfg: probeCfg(pane.adapter) }, 5000);
        const result = reply?.result;
        if (!result) continue;
        lastSeen.deepseek = Date.now();
        updateBadge('deepseek', result);
        if (result.input && !result.loggedOut && !result.loginModal && !result.challenge) {
          progressEl.textContent = '✅ DeepSeek 登录状态已同步';
          setTimeout(() => { progressEl.textContent = ''; }, 5000);
          return true;
        }
      } catch {}
    }
    progressEl.textContent = '⚠️ 已接收微信回调，但尚未确认 DeepSeek 登录状态；请刷新该窗格重试';
    setTimeout(() => { progressEl.textContent = ''; }, 8000);
    return false;
  }

  chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!msg || msg.type !== 'WB_AUTH_CALLBACK_TRUSTED') return false;
    if (sender.id !== chrome.runtime.id || msg.channelToken !== authChannelToken ||
        msg.tabId !== workbenchTab?.id || msg.provider !== 'deepseek-wechat') return false;
    const callback = validatedDeepSeekCallback(msg.url);
    const pane = frames.deepseek;
    if (!callback || !pane) return false;
    progressEl.textContent = '微信授权完成，正在同步 DeepSeek 登录状态…';
    lastSeen.deepseek = 0;
    const badge = document.getElementById('badge-deepseek');
    if (badge) { badge.className = 'badge loading'; badge.textContent = '登录同步中'; }
    pane.frame.src = callback;
    verifyDeepSeekLogin();
    return false;
  });

  async function registerWorkbenchChannel() {
    workbenchTab = await chrome.tabs.getCurrent();
    if (!workbenchTab?.id) throw new Error('无法识别工作台标签页');
    const result = await chrome.runtime.sendMessage({
      type: 'WB_REGISTER_WORKBENCH',
      channelToken: authChannelToken
    });
    if (!result?.ok || result.tabId !== workbenchTab.id) throw new Error('工作台认证通道注册失败');
  }

  // —— 版本更新（GitHub Releases；侧载扩展无法全自动重载，做到「一键下载 + 两步引导」）——
  const UPDATE_REPO = 'HanchengQiao/parallel-workshop';
  const bannerEl = document.getElementById('update-banner');

  function isNewer(a, b) {
    const pa = String(a).split('.').map(Number);
    const pb = String(b).split('.').map(Number);
    if (!pa.length || !pb.length) return a !== b;
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const av = i < pa.length ? pa[i] : 0;
      const bv = i < pb.length ? pb[i] : 0;
      if (av !== bv) return av > bv;
    }
    return false;
  }

  async function checkUpdate() {
    try {
      const resp = await fetch(`https://api.github.com/repos/${UPDATE_REPO}/releases/latest`);
      if (!resp.ok) return;
      const rel = await resp.json();
      const latest = String(rel.tag_name || '').replace(/^v/, '');
      const current = chrome.runtime.getManifest().version;
      if (!latest || !isNewer(latest, current)) return;
      bannerEl.style.display = '';
      bannerEl.innerHTML = `🆕 新版本 v${latest} 已发布 <button id="update-btn">立即更新</button>`;
      document.getElementById('update-btn').addEventListener('click', async () => {
        bannerEl.innerHTML = '正在下载新版本…';
        try {
          const zrel = await (await fetch(`https://api.github.com/repos/${UPDATE_REPO}/releases/latest`)).json();
          const asset = (zrel.assets || []).find(a => String(a.name).endsWith('.zip'));
          if (!asset) throw new Error('无 zip 资产');
          const blob = await (await fetch(asset.browser_download_url)).blob();
          const a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = asset.name;
          a.click();
          bannerEl.innerHTML = `已下载 ${asset.name} 到「下载」文件夹：①解压并双击 install.bat ②在 edge://extensions 点「重新加载」`;
        } catch (e) {
          bannerEl.innerHTML = '下载失败，请稍后重试或到 GitHub Releases 手动下载';
        }
      });
    } catch {}
  }

  // —— 启动 ——
  await registerWorkbenchChannel();
  renderChecks();
  renderPanes();
  setInterval(probeAll, 8000);
  setTimeout(probeAll, 3000);
  setTimeout(checkUpdate, 5000);
  setInterval(checkUpdate, 6 * 3600 * 1000);
})();
