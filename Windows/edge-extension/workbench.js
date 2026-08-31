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
  const paneTokens = {}; // id -> 随机令牌（消息协议认证）
  const lastSeen = {};  // id -> 最近一次探测响应时间戳
  const zooms = {};     // id -> 缩放倍数（CSS zoom 缩放 iframe，解决平台界面裁切）

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
        delete paneTokens[id];
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
      paneTokens[a.id] = Math.random().toString(36).slice(2) + Date.now().toString(36);
      lastSeen[a.id] = 0;
      applyZoom(a.id, zooms[a.id] ?? 1);
    }
  }

  // 翻页布局：仅调整可见/离屏类与 DOM 顺序（iframe 不重建）
  function layoutPanes() {
    const list = enabledList();
    const start = Math.min(windowStart, Math.max(list.length - MAX_VISIBLE, 0));
    const visibleIds = new Set(list.slice(start, start + MAX_VISIBLE).map(a => a.id));
    const ordered = [];
    for (const a of list) {
      const p = frames[a.id];
      if (!p) continue;
      const paneEl = p.frame.closest('.pane');
      paneEl.classList.toggle('offscreen', !visibleIds.has(a.id));
      ordered.push(paneEl);
    }
    // 可见窗格排前（按适配器顺序），离屏排后；appendChild 移动节点不触发 iframe 重载
    for (const el of ordered) panesEl.appendChild(el);
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
      chip.innerHTML = `<span>📄 ${a.name}</span><button data-name="${a.name}">✕</button>`;
      chip.querySelector('button').addEventListener('click', () => {
        const i = attachments.findIndex(x => x.name === a.name);
        if (i >= 0) attachments.splice(i, 1);
        renderChips();
        sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
      });
      attachChipsEl.appendChild(chip);
    }
  }
  async function addFile(file) {
    if (!file || file.size > 25 * 1024 * 1024) return;
    const data = await new Promise((res) => {
      const r = new FileReader();
      r.onload = () => res(String(r.result).split(',')[1] || '');
      r.readAsDataURL(file);
    });
    attachments.push({ name: file.name, mime: file.type || 'application/octet-stream', data });
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
  const sendCfg = (a, text) => {
    const c = probeCfg(a);
    c.text = text;
    c.attachments = attachments;
    if (a.attachment) c.attachment = a.attachment;
    return c;
  };

  window.addEventListener('message', (event) => {
    const d = event.data;
    if (!d || d.type !== 'WB_RESULT' || !d.frameId) return;
    const pane = frames[d.frameId];
    if (!pane) return;
    // 消息协议认证：回执必须来自对应窗格，且携带该窗格令牌
    if (pane.frame.contentWindow !== event.source) return;
    if (!d.tok || d.tok !== paneTokens[d.frameId]) return;
    if (d.result && d.result.input !== undefined) {
      lastSeen[d.frameId] = Date.now();
      updateBadge(d.frameId, d.result);
    } else if (d.result && d.result.ok !== undefined) {
      let suffix = '';
      const ai = d.result.attInfo;
      if (ai && ai !== 'none') {
        suffix = ai.startsWith('fileInput') ? ' · 附件已添加'
          : ai.startsWith('drop') ? ' · 附件已拖放'
          : ai.startsWith('already') ? ' · 附件已在输入框'
          : ' · 附件: ' + ai;
      }
      showToast(d.frameId, d.result.ok ? ('已提交' + suffix) : ('失败: ' + (d.result.error || 'UNKNOWN')));
      // 本轮状态机：成功即清空一次；全部尝试都失败则回填
      if (d.rid && d.rid === roundState.rid) {
        if (d.result.ok) {
          roundState.succeeded += 1;
          roundClearOnce();
        } else {
          roundState.failed += 1;
        }
        if (roundState.attempted > 0 &&
            roundState.failed + roundState.succeeded >= roundState.attempted &&
            roundState.succeeded === 0) {
          roundRestore();
        }
      }
    }
  });

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
    ensureFrames(); // 不阻塞：先发探测，注入保障并行进行（未就绪的 frame 下一轮补上）
    for (const [id, p] of Object.entries(frames)) {
      try {
        if (p.frame.contentWindow) {
          p.frame.contentWindow.postMessage({ type: 'WB_PROBE', frameId: id, tok: paneTokens[id], cfg: probeCfg(p.adapter) }, '*');
        }
      } catch {}
    }
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

  // 向指定窗格发消息并等待内容脚本回执（带超时，用于附件接受度检查等询问）
  function postAndWait(id, msg, timeoutMs) {
    return new Promise((resolve) => {
      let settled = false;
      const checkId = 'chk' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
      const h = (ev) => {
        const d = ev.data;
        if (d && d.checkId === checkId && d.frameId === id) {
          settled = true;
          window.removeEventListener('message', h);
          resolve(d.result || null);
        }
      };
      window.addEventListener('message', h);
      try {
        const w = frames[id] && frames[id].frame && frames[id].frame.contentWindow;
        if (!w) throw new Error('no-window');
        w.postMessage({ ...msg, checkId, tok: paneTokens[id] }, '*');
      } catch (e) {
        settled = true;
        window.removeEventListener('message', h);
        resolve(null);
      }
      setTimeout(() => {
        if (!settled) { window.removeEventListener('message', h); resolve(null); }
      }, timeoutMs);
    });
  }

  // 按 host 列表查 OOPIF 帧 ID（webNavigation 全帧可见，含跨域 iframe）。
  // origin host 与实际帧 URL 可能不一致（重定向：tongyi.com → qianwen.com、yiyan → wenxin），按 homeHosts 兜底匹配。
  async function frameIdOfHosts(hosts) {
    try {
      const tab = await chrome.tabs.getCurrent();
      if (!tab) return null;
      const fs = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
      for (const f of fs) {
        let h = '';
        try { h = new URL(f.url || '').hostname; } catch {}
        if (hosts.some(x => h === x || h.endsWith('.' + x) || (f.url || '').includes(x))) return f.frameId;
      }
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

  // 本轮发送状态：成功回执到达才清空；全部尝试失败则回填（防数据丢失）
  let roundState = { rid: 0, attempted: 0, failed: 0, succeeded: 0, sentText: '', sentAtts: [] };
  let roundCleared = false;

  function roundClearOnce() {
    if (roundCleared) return;
    roundCleared = true;
    questionEl.value = '';
    attachments.length = 0;
    renderChips();
    sendEl.disabled = true;
  }

  function roundRestore() {
    if (roundCleared) return;
    questionEl.value = roundState.sentText;
    attachments.splice(0, attachments.length, ...roundState.sentAtts);
    renderChips();
    sendEl.disabled = !questionEl.value.trim() && attachments.length === 0;
    progressEl.textContent = '⚠️ 本轮全部窗格发送失败，问题与附件已回填';
    setTimeout(() => { progressEl.textContent = ''; }, 6000);
  }

  async function send() {
    window.__wbAttachLog = window.__wbAttachLog || [];
    window.__wbAttachLog.push({ step: 'send-start', atts: attachments.length, text: questionEl.value.trim().slice(0, 10) });
    const text = questionEl.value.trim();
    if (!text && attachments.length === 0) return;   // 附件-only 允许发送
    // 开新一轮：rid 自增，回执按 rid 归属本轮
    roundState = {
      rid: roundState.rid + 1,
      attempted: 0, failed: 0, succeeded: 0,
      sentText: questionEl.value,
      sentAtts: attachments.slice()
    };
    roundCleared = false;
    ensureFrames(); // 不阻塞发送：并行保障注入，未就绪帧由诚实检查兜底
    window.__wbAttachLog.push({ step: 'after-ensure', atts: attachments.length });
    // —— 附件通道规划：有文件输入框选择器的平台走内容脚本文件赋值；其余走 CDP 拖放 ——
    // 两条通道按平台互斥，杜绝同一附件被注入两次。
    const attPlan = {};        // id -> 'input' | 'cdp'
    const cdpDispatched = {};  // id -> bool（仅 cdp 平台）
    const attNames = attachments.map(a => a.name);
    for (const [id, p] of Object.entries(frames)) {
      const sel = p.adapter.attachment && p.adapter.attachment.selectors;
      attPlan[id] = sel && sel.length ? 'input' : 'cdp';
    }
    if (attachments.length > 0) {
      try {
        const tab = await chrome.tabs.getCurrent();
        if (tab) {
          const items = attachments.map(a => ({ mime: a.mime, data: a.data, name: a.name }));
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
              window.__wbAttachLog.push({ id, plan: 'cdp', accepted });
              showToast(id, accepted ? '附件已注入' : '附件未被平台接受，请手动添加');
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
    let count = 0;
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
        const cfg = sendCfg(p.adapter, text);
        // 附件：仅让规划通道对应的帧保留附件（input 平台走内容脚本；cdp 平台仅在拖放派发失败时兜底）
        if (attachments.length > 0) {
          const keep = attPlan[id] === 'input' || (attPlan[id] === 'cdp' && !cdpDispatched[id]);
          if (!keep) { delete cfg.attachments; delete cfg.attachment; }
        }
        p.frame.contentWindow.postMessage({ type: 'WB_INJECT', frameId: id, tok: paneTokens[id], rid: roundState.rid, cfg }, '*');
        count += 1;
      } catch (e) {
        showToast(id, '失败: ' + e);
        skipped += 1;
      }
    }
    progressEl.textContent = '已向 ' + count + ' 个窗口提交' + (skipped > 0 ? '，' + skipped + ' 个未就绪跳过' : '');
    setTimeout(() => { progressEl.textContent = ''; }, 4000);
    roundState.attempted = count;
    if (count === 0) roundRestore();   // 一个都没发出去：立即回填
    sendEl.disabled = true;
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
  renderChecks();
  renderPanes();
  setInterval(probeAll, 8000);
  setTimeout(probeAll, 3000);
  setTimeout(checkUpdate, 5000);
  setInterval(checkUpdate, 6 * 3600 * 1000);
})();
