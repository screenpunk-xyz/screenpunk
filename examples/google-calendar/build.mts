import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { deploymentDigest, sha256Bytes, validateManifest } from '../../sdk/src/package.ts';
const dir = fileURLToPath(new URL('.', import.meta.url));
copyFileSync(new URL('../../sdk/dist/screenpunk.js', import.meta.url), dir + 'screenpunk.js');
const manifest = {
  schemaVersion: 1, dashboardId: '77777777-7777-4777-8777-777777777777', name: 'Calendar agenda',
  revision: '77777777-7777-4777-9777-777777777778', sdkVersion: '1', entrypoint: 'index.html',
  target: { profileId: 'fixture-phone', width: 390, height: 844, scale: 3, orientation: 'portrait' as const },
  connections: [{ alias: 'googleCalendar', required: true, operations: [{ name: 'events', kind: 'http' as const }] }],
  files: ['index.html', 'app.js', 'screenpunk.js'].map(path => {
    const bytes = readFileSync(dir + path); return { path, bytes: bytes.length, sha256: sha256Bytes(bytes) };
  }), digest: ''
};
manifest.digest = deploymentDigest(manifest);
validateManifest(manifest);
writeFileSync(dir + 'manifest.json', JSON.stringify(manifest, null, 2) + '\n');
console.log('Validated Calendar agenda manifest');
