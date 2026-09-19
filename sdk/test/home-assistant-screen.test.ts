import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../examples/home-assistant-services/app.js', import.meta.url), 'utf8');
test('example screen gates writes on fresh available state and never replays a failed write', async () => {
  const elements = new Map<string, { disabled: boolean; textContent: string; click?: () => Promise<void>; addEventListener: (event: string, handler: () => Promise<void>) => void }>();
  for (const id of ['status', 'color', 'temperature']) {
    const element = { disabled: true, textContent: '', click: undefined as (() => Promise<void>) | undefined,
      addEventListener(_event: string, handler: () => Promise<void>) { this.click = handler; } };
    elements.set(id, element);
  }
  let stale = true;
  let poll: () => void = () => {};
  const writes: unknown[] = [];
  const context = { document: { getElementById: (id: string) => elements.get(id) },
    setInterval: (fn: () => void) => { poll = fn; },
    screenpunk: { runtime: { ready() {} }, connections: { async request() {
      return { stale, value: [{entity_id: 'light.example', state: 'on'}, {entity_id: 'climate.example', state: 'unavailable'}] };
    } }, homeAssistant: { async callService(call: unknown) { writes.push(JSON.parse(JSON.stringify(call))); throw new Error('timeout'); } } } };
  vm.runInNewContext(source, context);
  const settle = async () => { await new Promise(resolve => setImmediate(resolve)); };
  await settle();
  assert.equal(elements.get('color')!.disabled, true);
  await elements.get('color')!.click!();
  assert.equal(writes.length, 0);
  stale = false; poll(); await settle();
  assert.equal(elements.get('color')!.disabled, false);
  assert.equal(elements.get('temperature')!.disabled, true);
  await elements.get('color')!.click!();
  assert.deepEqual(writes, [{domain:'light',service:'turn_on',target:{entity_id:'light.example'},serviceData:{rgb_color:[255,180,100],transition:1.5}}]);
  poll(); await settle();
  assert.equal(writes.length, 1);
});

test('example manifest and package inventory include exact service declarations', async () => {
  const { loadPackageDirectory, validateManifest } = await import('../src/package.ts');
  const { fileURLToPath } = await import('node:url');
  const { manifest } = loadPackageDirectory(fileURLToPath(new URL('../../examples/home-assistant-services/', import.meta.url)));
  assert.deepEqual(manifest.connections[0].serviceCalls?.map(x => `${x.domain}.${x.service}`), ['light.turn_on', 'climate.set_temperature']);
  for (const grants of [
    [{domain:'light', service:'turn_on', entityIds:[]}],
    [{domain:'light', service:'turn_on', entityIds:['all']}],
    [{domain:'light\n', service:'turn_on', entityIds:['light.example']}],
    [{domain:'light', service:'turn_on', entityIds:['light.example'], allowUntargeted:'yes'}]
  ]) {
    const invalid = structuredClone(manifest);
    delete invalid.digest;
    invalid.connections[0].serviceCalls = grants as never;
    assert.throws(() => validateManifest(invalid));
  }
});
