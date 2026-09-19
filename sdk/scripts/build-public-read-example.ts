import { readFileSync, writeFileSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deploymentDigest, sha256Bytes, validateManifest, type DashboardManifest } from '../src/package.js';
const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const directory = join(root, 'examples/public-read-animation');
copyFileSync(join(root, 'sdk/dist/screenpunk.js'), join(directory, 'screenpunk.js'));
const manifest: DashboardManifest = {
  schemaVersion: 1, dashboardId: '66666666-6666-4666-8666-666666666666', revision: '66666666-6666-4666-9666-666666666667',
  name: 'Synthetic public read animation', entrypoint: 'index.html', sdkVersion: '1',
  target: {profileId: 'fixture-tablet', width: 640, height: 640, scale: 1, orientation: 'portrait'},
  connections: [{alias: 'publicData', required: true, publicHTTP: {origin: 'https://data.example.org', userAgent: 'Screenpunk/1 (synthetic fixture)', operations: [
    {name:'timeline',path:'/timeline',response:'json',parameters:{},maxAgeSeconds:1,staleSeconds:3600},
    {name:'frame',path:'/frames/{timestamp}.png',response:'raster',parameters:{timestamp:{location:'path',minimum:1000,maximum:2000}},maxAgeSeconds:3600,staleSeconds:3600}
  ]}}],
  files: ['app.js','index.html','styles.css','screenpunk.js'].map(path => { const data = readFileSync(join(directory,path)); return {path,bytes:data.length,sha256:sha256Bytes(data)}; })
};
manifest.digest = deploymentDigest(manifest); validateManifest(manifest);
writeFileSync(join(directory,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
