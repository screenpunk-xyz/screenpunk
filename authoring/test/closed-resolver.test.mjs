import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createClosedResolver } from '../scripts/closed-resolver.mjs';

async function fixture(run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'screenpunk-resolver-'));
  const source = path.join(root, 'source');
  const kit = path.join(root, 'kit');
  try {
    await fs.mkdir(path.join(source, 'src/components'), { recursive: true });
    await fs.mkdir(path.join(kit, 'node_modules/hello'), { recursive: true });
    await fs.mkdir(path.join(kit, 'node_modules/mapping'), { recursive: true });
    await fs.writeFile(path.join(source, 'src/main.tsx'), 'import "hello";');
    await fs.writeFile(path.join(source, 'src/components/index.tsx'), 'export {}');
    await fs.mkdir(path.join(kit, 'node_modules/hello/assets'));
    await fs.writeFile(path.join(kit, 'node_modules/hello/package.json'), JSON.stringify({ name:'hello', exports:{'.':{browser:'./browser.js',default:'./server.js'},'./asset/*':'./assets/*'} }));
    await fs.writeFile(path.join(kit, 'node_modules/hello/browser.js'), 'export const browser = true;');
    await fs.writeFile(path.join(kit, 'node_modules/hello/assets/logo.svg'), '<svg/>');
    await fs.writeFile(path.join(kit, 'node_modules/mapping/package.json'), JSON.stringify({ name:'mapping', browser:{'./node.js':'./browser.js',fs:false} }));
    await fs.writeFile(path.join(kit, 'node_modules/mapping/node.js'), 'export const platform="node";');
    await fs.writeFile(path.join(kit, 'node_modules/mapping/browser.js'), 'export const platform="browser";');
    await run({ root, source, kit });
  } finally { await fs.rm(root, { recursive:true, force:true }); }
}

test('resolves project and kit imports without ambient fallback', async () => fixture(async ({ source, kit }) => {
  const main = path.join(source, 'src/main.tsx');
  const component = path.join(source, 'src/components/index.tsx');
  const resolver = createClosedResolver({ source, kit, sourceFiles:[main,component] });
  assert.equal(await resolver.resolve('./components', main), component);
  const browser = await resolver.resolve('hello', main);
  assert.equal(browser, path.join(kit, 'node_modules/hello/browser.js'));
  assert.match((await resolver.load(browser)).contents.toString(), /browser = true/);
  const asset = await resolver.resolve('hello/asset/logo.svg', main, 'url-token');
  assert.equal((await resolver.load(asset)).loader, 'file');
  const mapped = await resolver.resolve('mapping/node.js', main);
  assert.equal(mapped, path.join(kit, 'node_modules/mapping/browser.js'));
  const empty = await resolver.resolve('fs', mapped);
  assert.equal((await resolver.load(empty)).contents, '');
  await assert.rejects(resolver.resolve('missing', main), /verified kit/);
  await assert.rejects(resolver.resolve('../../../../etc/passwd', main), /escaped approved roots/);
  await assert.rejects(resolver.resolve('https://example.org/x.js', main), /external or dynamic/);
}));

test('rejects source files omitted from the frozen plan and linked assets', async () => fixture(async ({ source, kit }) => {
  const main = path.join(source, 'src/main.tsx');
  const extra = path.join(source, 'src/extra.ts');
  const linked = path.join(source, 'src/linked.ts');
  await fs.writeFile(extra, 'export {}');
  await fs.symlink('/etc/hosts', linked);
  const resolver = createClosedResolver({ source, kit, sourceFiles:[main] });
  await assert.rejects(resolver.resolve('./extra', main), /frozen input plan/);
  await assert.rejects(resolver.resolve('./linked', main), /link or member/);
}));
