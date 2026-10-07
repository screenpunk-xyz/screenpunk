import React, { StrictMode } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ScreenpunkProvider, useScreenPreferences, type ScreenpunkClient } from '../react/index';
(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
const defaults = { schemaVersion: 1, text: 'default' };
function decode(value: unknown): typeof defaults {
  const data = value as typeof defaults;
  if (!data || data.schemaVersion !== 1 || typeof data.text !== 'string') throw new Error('migration_required');
  return { schemaVersion: 1, text: data.text };
}
function host(saved: unknown = null) {
  let listener: (value: unknown) => void = () => {};
  const calls = { get: 0, set: 0, remove: 0 };
  const client: ScreenpunkClient = {
    runtime: { ready() {}, onStatus(next) { listener = next; return () => {}; } },
    connections: { async read() { return { state: 'fresh', status: 200 }; }, release() {}, subscribe() { return () => {}; } },
    state: { async get() { calls.get++; return saved; }, async set(_key, value) { calls.set++; saved = value; }, async remove() { calls.remove++; saved = null; } }
  };
  return { client, calls, status(value: unknown) { listener(value); }, saved: () => saved };
}
type Preferences = ReturnType<typeof useScreenPreferences<typeof defaults>>;
async function mount(h: ReturnType<typeof host>) {
  let observed!: Preferences; let tree!: ReactTestRenderer;
  function App() { observed = useScreenPreferences('example.preferences.v1', defaults, decode); return null; }
  await act(async () => { tree = create(<StrictMode><ScreenpunkProvider client={h.client}><App/></ScreenpunkProvider></StrictMode>); });
  await act(async () => h.status({ active: true, persistentState: 1, persistentStateWritable: 1 }));
  return { prefs: () => observed, async close() { await act(async () => tree.unmount()); } };
}
test('explicit save survives remount while hydration and absent values never write defaults', async () => {
  const h = host();
  const first = await mount(h);
  assert.equal(first.prefs().phase, 'ready'); assert.equal(h.calls.set, 0);
  await act(async () => first.prefs().save({ schemaVersion: 1, text: 'user value' }));
  await first.close();
  const second = await mount(h);
  assert.equal(second.prefs().value.text, 'user value'); assert.equal(h.calls.set, 1); assert.equal(h.calls.remove, 0);
  await second.close();
});
test('read rejection and unknown schema disable edits without replacing existing saved data', async () => {
  for (const failRead of [false, true]) {
    const h = host({ schemaVersion: 99, text: 'keep' });
    if (failRead) h.client.state!.get = async () => { throw new Error('device_offline'); };
    const mounted = await mount(h);
    assert.equal(mounted.prefs().phase, 'error'); assert.equal(mounted.prefs().editable, false);
    await assert.rejects(mounted.prefs().save(defaults));
    assert.equal(h.calls.set, 0); assert.deepEqual(h.saved(), { schemaVersion: 99, text: 'keep' });
    await mounted.close();
  }
});
test('unsupported and read-only status perform no persistence operations', async () => {
  const h = host(); const mounted = await mount(h);
  const baseline = h.calls.get;
  await act(async () => h.status({ active: true }));
  assert.equal(mounted.prefs().phase, 'unsupported');
  await act(async () => h.status({ active: true, persistentState: 1, persistentStateWritable: 0 }));
  assert.equal(mounted.prefs().phase, 'read-only');
  await assert.rejects(mounted.prefs().save(defaults));
  assert.equal(h.calls.get, baseline); assert.equal(h.calls.set, 0); assert.equal(h.calls.remove, 0);
  await mounted.close();
});
test('save failure is visible and concurrent save cannot overwrite a pending user edit', async () => {
  const h = host({ schemaVersion: 1, text: 'original' });
  const mounted = await mount(h);
  h.client.state!.set = async () => { throw new Error('write_failed'); };
  await act(async () => { await assert.rejects(mounted.prefs().save({ schemaVersion: 1, text: 'new' })); });
  assert.equal(mounted.prefs().error, 'write_failed'); assert.equal(mounted.prefs().value.text, 'original');
  let finish!: () => void;
  h.client.state!.set = () => new Promise<void>(resolve => { finish = resolve; });
  let pending!: Promise<void>;
  await act(async () => { pending = mounted.prefs().save({ schemaVersion: 1, text: 'latest' }); });
  await assert.rejects(mounted.prefs().save({ schemaVersion: 1, text: 'stale' }));
  await act(async () => { finish(); await pending; });
  assert.equal(mounted.prefs().value.text, 'latest'); assert.equal(mounted.prefs().saving, false);
  await mounted.close();
});
