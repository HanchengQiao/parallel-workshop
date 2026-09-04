import { readFileSync } from 'node:fs';

const base = decodeURIComponent(new URL('..', import.meta.url).pathname);
const read = path => readFileSync(base + path, 'utf8').replace(/^\uFEFF/, '');
const fail = [];
const requireText = (condition, message) => { if (!condition) fail.push(message); };

const bump = read('scripts/bump-version.sh');
const app = read('scripts/package-app.sh');
const dmg = read('scripts/package-dmg.sh');
const audit = read('scripts/package-external-audit.sh');
const release = read('scripts/make-release.sh');
const storeListing = read('Windows/edge-extension/STORE_LISTING.md');

requireText(bump.includes('^[0-9]+\\.[0-9]+\\.[0-9]+$'),
  'bump-version 未在写文件前拒绝非 SemVer');
requireText(app.includes('--scratch-path "$PACKAGE_SCRATCH"') &&
  app.includes('lipo -create "$ARM" "$X64" -output "$APP_BINARY"') &&
  !app.includes('-output "$ARM.universal"') && !app.includes('mv "$ARM.universal" "$ARM"'),
  'package-app 仍会污染 SwiftPM 单架构产物');
requireText(app.includes('rm -f build/AppIcon.icns') && app.includes('swift scripts/icon.swift'),
  'package-app 仍可能复用旧图标缓存');
requireText(dmg.includes('APP_VERSION=') && dmg.includes('App 版本与 DMG 文件名不一致'),
  'package-dmg 未拒绝文件名与 App 内版本错配');

requireText(audit.includes('manifest 版本号无效') &&
  audit.includes('cp install-windows.ps1 "$STAGE/artifacts/"') &&
  audit.includes('VERIFY_SIDECAR=') && audit.includes('VERIFY-ASSEMBLY-ZIP.log') &&
  audit.includes('npm ci --prefix scripts --ignore-scripts --no-audit --no-fund') &&
  audit.includes("git tag --merged \"$COMMIT\" --list 'v[0-9]*'"),
  '外审包缺少版本防线、Windows 引导资产、诚实 ZIP 验证或可复跑说明');

requireText(release.includes('git fetch origin "$DEFAULT_BRANCH" --tags') &&
  release.includes('[ "$BRANCH" = "$DEFAULT_BRANCH" ]') &&
  release.includes('[ "$HEAD_SHA" = "$REMOTE_SHA" ]') &&
  release.includes('[ "$ORIGIN_REPO" = "$REPO" ]'),
  '发布脚本未锁定规范 origin/main/HEAD');
requireText(release.includes('prelaunch-external-audit-${SHORT}') &&
  release.includes('ARTIFACTS_SHA256.txt') && release.includes('shasum -a 256 -c') &&
  release.includes('cmp -s install-windows.ps1'),
  '发布脚本未复用并核验与 HEAD 精确对应的外审资产');
requireText(!release.includes('bash scripts/package-app.sh') &&
  !release.includes('bash scripts/build-edge-extension.sh') &&
  !release.includes('bash scripts/package-dmg.sh'),
  '发布脚本仍会重建未经外审的新字节');
requireText(release.includes('git show-ref --verify') && release.includes('git ls-remote --exit-code --tags') &&
  release.includes('gh release list') && release.includes('--draft --verify-tag') &&
  release.includes('REMOTE_TAG_TARGET') && release.includes('digest'),
  '发布脚本缺少 tag/Release 预检、Draft 或发布后资产回查');
requireText(storeListing.includes('豆包') && !storeListing.includes('五平台'),
  '商店文案仍遗漏豆包或写成五平台');

if (fail.length) {
  console.error(`❌ 发布流水线契约失败：\n- ${fail.join('\n- ')}`);
  process.exit(1);
}
console.log('✅ 发布流水线契约通过（版本/幂等打包/外审字节晋升/main 与资产闸门）');
