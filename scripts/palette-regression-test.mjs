import { readFileSync } from 'node:fs';

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const read = path => readFileSync(base + path, 'utf8');
const css = read('Windows/edge-extension/workbench.css');
const html = read('Windows/edge-extension/workbench.html');
const contentView = read('Sources/ParallelWorkbench/ContentView.swift');
const paneView = read('Sources/ParallelWorkbench/PaneView.swift');

const expectedHex = new Set(['#252A2E', '#7E9283', '#F7F5F0']);
const actualHex = new Set(css.match(/#[0-9a-fA-F]{6}\b/g) || []);
if (actualHex.size !== expectedHex.size || [...actualHex].some(value => !expectedHex.has(value.toUpperCase()))) {
  throw new Error(`Edge 色板超出三色：${[...actualHex].join(', ')}`);
}

const allowedRGB = new Set(['37,42,46', '126,146,131', '247,245,240']);
for (const match of css.matchAll(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/g)) {
  const rgb = `${match[1]},${match[2]},${match[3]}`;
  if (!allowedRGB.has(rgb)) throw new Error(`Edge rgba 超出三色：${match[0]}`);
}
if (/linear-gradient|radial-gradient/i.test(css)) throw new Error('Edge 外壳仍包含渐变');
if (/brand-symbol|startup-mark|>PW</.test(html + css)) throw new Error('PW 方块 logo 尚未彻底移除');

const swift = contentView + '\n' + paneView;
for (const required of [
  '247.0 / 255.0, green: 245.0 / 255.0, blue: 240.0 / 255.0',
  '37.0 / 255.0, green: 42.0 / 255.0, blue: 46.0 / 255.0',
  '126.0 / 255.0, green: 146.0 / 255.0, blue: 131.0 / 255.0'
]) {
  if (!contentView.includes(required)) throw new Error(`macOS 缺少统一色板：${required}`);
}
for (const forbidden of [
  'LinearGradient', '.ultraThinMaterial', '.regularMaterial', 'Color.accentColor',
  'return .red', 'return .orange', 'return .blue', 'return .purple', 'return .green'
]) {
  if (swift.includes(forbidden)) throw new Error(`macOS 外壳仍含额外色彩/材质：${forbidden}`);
}
if (swift.includes('square.stack.3d.up.fill')) throw new Error('macOS 顶部装饰 logo 尚未移除');

console.log('✅ 双端三色与纯文字品牌回归通过');
