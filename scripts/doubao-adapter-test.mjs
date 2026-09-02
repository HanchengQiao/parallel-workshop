import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = decodeURIComponent(new URL('..', import.meta.url).pathname);
const sourcePath = `${root}/Sources/WorkbenchCore/Resources/adapters/doubao.json`;
const builtPath = `${root}/Windows/edge-extension/lib/adapters/doubao.json`;
const adapter = JSON.parse(readFileSync(sourcePath, 'utf8'));
const builtAdapter = JSON.parse(readFileSync(builtPath, 'utf8'));

assert.deepEqual(builtAdapter, adapter, 'Edge 豆包适配器必须与共享核心字节语义一致');
assert.equal(adapter.id, 'doubao');
assert.equal(adapter.name, '豆包');
assert.equal(adapter.origin, 'https://www.doubao.com/chat/');
assert.deepEqual(adapter.homeHosts, ['www.doubao.com', 'doubao.com']);
assert.equal(adapter.send.type, 'button');
assert.equal(adapter.input.selectors[0], "div.tiptap.ProseMirror[contenteditable='true'][role='textbox']");
assert.equal(adapter.send.selectors[0], 'button#flow-end-msg-send');

const manifest = JSON.parse(readFileSync(`${root}/Windows/edge-extension/manifest.json`, 'utf8'));
for (const match of ['https://www.doubao.com/*', 'https://doubao.com/*']) {
  assert.ok(manifest.host_permissions.includes(match), `host_permissions 缺少 ${match}`);
  assert.ok(manifest.content_scripts.some((entry) => entry.js?.includes('intercept.js') && entry.matches?.includes(match)),
    `MAIN world 导航拦截缺少 ${match}`);
}

const background = readFileSync(`${root}/Windows/edge-extension/background.js`, 'utf8');
for (const host of ['www.doubao.com', 'doubao.com']) {
  assert.ok(background.includes(`'${host}'`), `后台白名单缺少 ${host}`);
}

// 取自 2026-09-02 官方未登录页的公开 DOM 形状。此回归仅锁定已验证的
// 稳定属性，不加载站点、不登录，也绝不会触发发送。
const fixture = `<!doctype html><html><body>
  <button>登录</button>
  <div contenteditable="true" role="textbox" translate="no" class="tiptap ProseMirror">
    <p data-placeholder="发消息..." class="is-empty is-editor-empty"><br></p>
  </div>
  <button id="flow-end-msg-send" aria-disabled="false"></button>
</body></html>`;
assert.ok(fixture.includes('contenteditable="true" role="textbox"'));
assert.ok(fixture.includes('class="tiptap ProseMirror"'));
assert.ok(fixture.includes('id="flow-end-msg-send"'));
assert.deepEqual(adapter.probe.loggedOut, ["xpath://button[normalize-space()='登录']"]);

const inject = readFileSync(`${root}/Sources/WorkbenchCore/Resources/injection/inject.js`, 'utf8');
assert.ok(inject.includes("if (cfg.noSend)"), '共享注入核心必须保留只注入不发送分支');
assert.ok(inject.includes("cfg.send.type === 'button'"), '共享注入核心必须支持豆包按钮发送方式');

console.log('✅ 豆包适配器回归通过（域名白名单/公开 DOM 形状/只注入能力）');
