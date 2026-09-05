// API-independent index sealed beside the binaries it describes.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [version, directory] = process.argv.slice(2);
if (!/^\d+\.\d+\.\d+$/.test(version || '') || !directory) {
  throw new Error('Usage: node scripts/generate-update-manifest.mjs X.Y.Z artifacts-directory');
}
const digest = name => createHash('sha256').update(readFileSync(resolve(directory, name))).digest('hex');
const prefix = `https://github.com/porcelaintech/parallel-workshop/releases/download/v${version}/`;
const manifest = {
  schemaVersion: 1,
  version,
  dmgURL: `${prefix}ParallelWorkbench-${version}.dmg`,
  dmgSHA256: digest(`ParallelWorkbench-${version}.dmg`),
  edgeURL: `${prefix}edge-extension.zip`,
  edgeSHA256: digest('edge-extension.zip'),
  notes: `平行工作台 v${version}`
};
writeFileSync(resolve(directory, 'update.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`Update index generated for v${version}`);
