// 内容脚本模板：由 build-edge-extension.sh 生成 content.js。
// 共享核心（inject.js/probe.js）在构建时转换为普通函数（__wbInject/__wbProbe）内嵌进来，
// 不使用 eval —— 内容脚本的 eval 受宿主页面 CSP 约束（'unsafe-eval' 会被拒绝）。
(async () => {
  if (window.__wb_content_installed) return;
  const HOSTS = [
    'chat.deepseek.com', 'www.kimi.com', 'kimi.moonshot.cn', 'www.moonshot.cn', 'www.tongyi.com', 'www.qianwen.com',
    'yiyan.baidu.com', 'wenxin.baidu.com', 'chatgpt.com', 'chat.openai.com'
  ];
  if (!HOSTS.some(h => location.hostname === h || location.hostname.endsWith('.' + h))) return;
  window.__wb_content_installed = true;
  document.documentElement.setAttribute('data-wb-content', '1');

  async function __wbInject(cfg) {

  
  try { window.__wbReqId = cfg.reqId || ''; } catch {}
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const $q = (sel) => {
    if (sel.startsWith('xpath:')) {
      try {
        const r = document.evaluate(sel.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
        return r.singleNodeValue;
      } catch { return null; }
    }
    try { return document.querySelector(sel); } catch { return null; }
  };
  const first = (sels) => { for (const s of sels || []) { const el = $q(s); if (el) return el; } return null; };

  const el = first(cfg.input.selectors);
  if (!el) {
    const candidates = [];
    document.querySelectorAll('textarea, [contenteditable="true"]').forEach((e) => {
      if (candidates.length < 8) {
        candidates.push({
          tag: e.tagName,
          id: e.id || null,
          cls: typeof e.className === 'string' ? e.className.slice(0, 100) : null,
          ph: e.getAttribute('placeholder') || e.getAttribute('aria-label') || null
        });
      }
    });
    return { ok: false, error: 'NO_INPUT', candidates };
  }

  // 若命中的是容器（div 等非输入元素），向内查找真正的输入元素
  let target = el;
  if (target.tagName !== 'TEXTAREA' && target.tagName !== 'INPUT') {
    const isCE0 = target.getAttribute('contenteditable') === 'true' || target.contentEditable === 'true';
    if (!isCE0) {
      try {
        const inner = target.querySelector('[contenteditable="true"], textarea, input[type="text"]');
        if (inner) target = inner;
      } catch {}
    }
  }

  const isCE = target.getAttribute('contenteditable') === 'true' || target.contentEditable === 'true';
  if (!cfg.skipText) {
  try { target.focus(); } catch {}
  // 关键：等框架（React/Slate/Lexical）异步同步焦点与选区
  await sleep(120);

  if (isCE) {
    // contenteditable 编辑器：选区必须落在文本节点内部，框架才会把插入视为真实输入
    const sel = window.getSelection();
    // 清空已有内容（防止框架回填/草稿残留导致重复）
    const range0 = document.createRange();
    range0.selectNodeContents(target);
    sel.removeAllRanges();
    sel.addRange(range0);
    try { document.execCommand('delete'); } catch {}
    // 定位最深文本节点末尾
    let endNode = null;
    const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = walker.nextNode())) endNode = n;
    const range = document.createRange();
    if (endNode) {
      range.setStart(endNode, endNode.textContent.length);
    } else {
      range.selectNodeContents(target);
    }
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
    document.execCommand('insertText', false, cfg.text);
  } else if (target.tagName === 'TEXTAREA' || target.tagName === 'INPUT') {
    // textarea/input：原生 setter 设值 + 事件，React/Vue 均能识别
    const proto = target.tagName === 'TEXTAREA'
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value');
    if (setter && setter.set) setter.set.call(target, cfg.text); else target.value = cfg.text;
    target.dispatchEvent(new Event('input', { bubbles: true }));
    target.dispatchEvent(new Event('change', { bubbles: true }));
  } else {
    // 兜底：直接 textContent + input 事件
    target.textContent = cfg.text;
    target.dispatchEvent(new Event('input', { bubbles: true }));
  }
  }

  // 等框架状态更新（如发送按钮从禁用变可用）
  await sleep(150);

  // —— 附件注入（多模态）：base64 → 页面内重建 File → 优先赋给文件输入框，否则对编辑器派发 drag-drop ——
  let attInfo = 'none';
  const attachments = (cfg.attachments || []).filter(a => a && a.data);
  if (attachments.length > 0) {
    const L = (s) => { try { (window.__wbAttLog = window.__wbAttLog || []).push(s); } catch {} };
    L('att0:raw=' + (cfg.attachments || []).length + ',fil=' + attachments.length);
    let attOK = 0;
    const dt = new DataTransfer();
    let dtErr = '';
    for (const a of attachments) {
      try {
        const bytes = Uint8Array.from(atob(a.data), c => c.charCodeAt(0));
        const file = new File([bytes], a.name || 'attachment', { type: a.mime || 'application/octet-stream' });
        dt.items.add(file);
      } catch (e) {
        dtErr = dtErr || ('[len=' + (a.data ? String(a.data).length : 'undef') + ' head=' + String(a.data).slice(0, 12) + '] ' + String(e).slice(0, 50));
      }
    }
    L('dt:' + dt.items.length + (dtErr ? ',err=' + dtErr : ''));
    if (dt.items.length === 0 && dtErr) attInfo = 'dt-empty:' + dtErr;
    // 诊断视图：附件块实际看到的数据形状（跨世界回传用）
    try {
      window.__wbAttachView = {
        raw: (cfg.attachments || []).length,
        filtered: attachments.length,
        d0: attachments[0] ? { name: String(attachments[0].name || '').slice(0, 20), len: attachments[0].data ? String(attachments[0].data).length : -1 } : null,
        dtItems: dt.items.length
      };
    } catch {}
    // 唤起动作：先点击打开按钮（如工具箱）让上传面板/文件输入框动态渲染
    const openSels = (cfg.attachment && cfg.attachment.openSelectors) || [];
    for (const os of openSels) {
      const opener = first([os]);
      if (opener) {
        try { opener.click(); } catch {}
        await sleep(600);
        break;
      }
    }
    // 目标：适配器配置的选择器 → 页面里任一 file input（优先可见；真实上传输入框多为隐藏元素，也兜底使用）
    const attSel = (cfg.attachment && cfg.attachment.selectors) || [];
    let attTarget = first(attSel);
    L('attSel:' + JSON.stringify(attSel) + ' → ' + (attTarget ? attTarget.tagName + '/' + attTarget.type : 'null'));
    const anyFileInput = (() => {
      const els = document.querySelectorAll('input[type=file]');
      let hiddenFallback = null;
      for (const el of els) {
        const r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        if (r && r.width > 0 && r.height > 0) return el;
        if (!hiddenFallback) hiddenFallback = el;
      }
      return hiddenFallback;
    })();
    const forceDrop = !!(cfg.attachment && cfg.attachment.forceDrop);
    const fileInput = forceDrop ? null : ((attTarget && attTarget.tagName === 'INPUT' && attTarget.type === 'file') ? attTarget
      : (attTarget ? attTarget.querySelector('input[type=file]') : null) || anyFileInput);
    L('fileInput:' + (fileInput ? fileInput.tagName + '/' + fileInput.type + ' visible=' + !!anyFileInput : 'null'));
    if (fileInput) {
      try {
        fileInput.files = dt.files;
        // 必须在派发 change 之前记录：平台的 change 处理器会立即消费并重置 input（files 清零）
        attOK = fileInput.files.length;
        attInfo = 'fileInput:' + attOK;
        L('assign:attOK=' + attOK + '（派发前）');
        fileInput.dispatchEvent(new Event('input', { bubbles: true }));
        fileInput.dispatchEvent(new Event('change', { bubbles: true }));
      } catch (e) {
        attInfo = 'fileInput-error:' + String(e).slice(0, 40);
        L('assign-err:' + String(e).slice(0, 60));
      }
    }
    if (attOK === 0) {
      L('drop-path:attOK=0,dt=' + dt.files.length);
      // 无可用文件输入框：对编辑器/目标区派发拖放事件（多数平台支持拖拽附件）
      const dropTarget = attTarget || target;
      const rect = dropTarget.getBoundingClientRect();
      const opts = {
        bubbles: true, cancelable: true, dataTransfer: dt,
        clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2
      };
      try {
        dropTarget.dispatchEvent(new DragEvent('dragenter', opts));
        L('drag-after-enter:dt=' + dt.files.length);
        dropTarget.dispatchEvent(new DragEvent('dragover', opts));
        dropTarget.dispatchEvent(new DragEvent('drop', opts));
        attOK = dt.files.length;
        attInfo = 'drop:' + dt.files.length;
        L('drag-after-drop:dt=' + dt.files.length);
      } catch (e) {
        attInfo = 'drop-error:' + String(e).slice(0, 40);
      }
    }
    // 等平台消化附件（上传/预览）
    await sleep(700);
    // 若通过打开动作唤起了面板（如工具箱弹层），附件赋值后按 Escape 关闭，避免遮挡/干扰发送
    if (openSels.length > 0) {
      try {
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
        document.dispatchEvent(new KeyboardEvent('keyup', { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true }));
      } catch {}
      await sleep(500);
    }
  }

  if (cfg.noSend) {
    return { ok: true, sent: 'none', attInfo, editorHTML: target.innerHTML ? target.innerHTML.slice(0, 300) : '' };
  }

  if (cfg.send && cfg.send.type === 'button') {
    const chain = cfg.send.selectors || (cfg.send.selector ? [cfg.send.selector] : []);
    const matches = [];
    for (const s of chain) {
      let els = [];
      try { els = Array.from(document.querySelectorAll(s)); } catch {}
      for (const b of els) {
        const r = b.getBoundingClientRect ? b.getBoundingClientRect() : null;
        matches.push({
          cls: (typeof b.className === 'string' ? b.className : '').slice(0, 60),
          disabled: !!b.disabled,
          ariaDisabled: b.getAttribute('aria-disabled') || null,
          visible: !!(r && r.width > 0 && r.height > 0)
        });
      }
    }
    const visibleEnabled = (b) => !b.disabled && b.getAttribute('aria-disabled') !== 'true'
      && (() => { const r = b.getBoundingClientRect ? b.getBoundingClientRect() : null; return !!(r && r.width > 0 && r.height > 0); })();
    let btn = null;
    for (const s of chain) {
      let els = [];
      try { els = Array.from(document.querySelectorAll(s)); } catch {}
      for (const b of els) {
        if (visibleEnabled(b)) { btn = b; break; }
      }
      if (btn) break;
    }
    if (btn) {
      const state = { disabled: !!btn.disabled, ariaDisabled: btn.getAttribute('aria-disabled') || null };
      btn.click();
      return {
        ok: true, sent: 'button', attInfo, buttonState: state, matchedCount: matches.length, matches: matches,
        editorHTML: target.innerHTML ? target.innerHTML.slice(0, 200) : ''
      };
    }
    return { ok: false, error: 'NO_ENABLED_BUTTON', attInfo, matchedCount: matches.length, matches: matches };
  }

  if (cfg.send && cfg.send.type === 'combo') {
    // 按钮点击 + 合成回车双保险（调试定位用）
    const chain = cfg.send.selectors || (cfg.send.selector ? [cfg.send.selector] : []);
    const btn = chain.flatMap((s) => { try { return Array.from(document.querySelectorAll(s)); } catch { return []; } })
      .find((b) => {
        const r = b.getBoundingClientRect ? b.getBoundingClientRect() : null;
        return !b.disabled && b.getAttribute('aria-disabled') !== 'true' && !!(r && r.width > 0 && r.height > 0);
      }) || null;
    const btnState = btn ? { disabled: !!btn.disabled, ariaDisabled: btn.getAttribute('aria-disabled') || null } : null;
    if (btn) { btn.click(); }
    await sleep(200);
    const key2 = (type) => target.dispatchEvent(new KeyboardEvent(type, {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
    }));
    key2('keydown');
    key2('keypress');
    key2('keyup');
    return {
      ok: true, sent: 'combo', buttonState: btnState ?? {},
      editorHTML: target.innerHTML ? target.innerHTML.slice(0, 200) : ''
    };
  }

  if (cfg.send && cfg.send.type === 'pointer') {
    // 完整指针事件序列（有些框架监听 pointerup/mouseup 而非 click）
    const chain = cfg.send.selectors || (cfg.send.selector ? [cfg.send.selector] : []);
    const btn = chain.flatMap((s) => { try { return Array.from(document.querySelectorAll(s)); } catch { return []; } })
      .find((b) => {
        const r = b.getBoundingClientRect ? b.getBoundingClientRect() : null;
        return !b.disabled && b.getAttribute('aria-disabled') !== 'true' && !!(r && r.width > 0 && r.height > 0);
      }) || null;
    if (btn) {
      const r = btn.getBoundingClientRect();
      const x = r ? r.x + r.width / 2 : 0;
      const y = r ? r.y + r.height / 2 : 0;
      const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0, buttons: 1 };
      const fire = (type, ctor) => btn.dispatchEvent(new ctor(type, opts));
      fire('pointerdown', PointerEvent);
      fire('mousedown', MouseEvent);
      fire('pointerup', PointerEvent);
      fire('mouseup', MouseEvent);
      fire('click', MouseEvent);
      return {
        ok: true, sent: 'pointer',
        buttonState: { disabled: !!btn.disabled, ariaDisabled: btn.getAttribute('aria-disabled') || null }
      };
    }
    return { ok: false, error: 'NO_ENABLED_BUTTON', attInfo };
  }

  if (cfg.send && cfg.send.type === 'paragraph') {
    let ok = false;
    try { ok = document.execCommand('insertParagraph'); } catch {}
    return ok ? { ok: true, attInfo, sent: 'paragraph' }
      : { ok: false, error: 'PARAGRAPH_NOT_ACCEPTED', attInfo };
  }

  const key = (type) => target.dispatchEvent(new KeyboardEvent(type, {
    key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
  }));
  key('keydown');
  key('keypress');
  key('keyup');

  return { ok: true, sent: 'enter', attInfo };
  try { if (window.__wbReqId) result.reqId = window.__wbReqId; } catch {}
}

function __wbProbe(cfg) {

  
  const has = (sels) => (sels || []).some((s) => {
    try {
      if (s.startsWith('xpath:')) {
        const r = document.evaluate(s.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
        return !!r.singleNodeValue;
      }
      return !!document.querySelector(s);
    } catch { return false; }
  });
  return {
    input: has(cfg.input.selectors),
    challenge: has(cfg.probe && cfg.probe.challenge),
    loggedOut: has(cfg.probe && cfg.probe.loggedOut),
    loginModal: has(cfg.probe && cfg.probe.loginModal),
    url: location.href
  };

}

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
