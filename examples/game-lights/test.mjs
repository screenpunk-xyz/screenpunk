import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const code = readFileSync(new URL('./app.js', import.meta.url), 'utf8');
async function harness(stale = false) {
  const elements = new Map();
  const get = id => { if (!elements.has(id)) elements.set(id, {disabled:true,value:'59',textContent:''}); return elements.get(id); };
  const calls = [];
  let poll;
  let nextRead;
  const sdk = {runtime:{ready(){}}, connections:{async request(alias, operation, parameters) {
    calls.push({alias, operation, parameters});
    if (operation === 'getStates' && nextRead) {
      const pending = nextRead; nextRead = null;
      return pending;
    }
    return {stale, value:[{entity_id:'light.game_lights',state:'on',attributes:{brightness:59}}]};
  }}};
  vm.runInNewContext(code, {window:{screenpunk:sdk}, document:{getElementById:get,body:{dataset:{}}}, setTimeout(){}, setInterval(fn, delay){assert.equal(delay,2000);poll=fn;}});
  await new Promise(resolve => setImmediate(resolve));
  return {get,calls,poll, deferRead() {
    let resolve, reject;
    nextRead = new Promise((yes, no) => { resolve = yes; reject = no; });
    return {resolve, reject};
  }};
}
test('reads state without writing; actions target Game lights explicitly', async () => {
  const h = await harness();
  assert.deepEqual(h.calls.map(c=>c.operation), ['getStates']);
  assert.equal(h.get('on').disabled, false);
  assert.equal(h.get('level').textContent, '23%');
  await h.get('off').onclick();
  const action = h.calls.find(c=>c.operation==='lightOff');
  assert.equal(action.alias, 'home');
  assert.equal(action.parameters.entity_id, 'light.game_lights');
  assert.equal(Object.keys(action.parameters).length, 1);
  await h.get('on').onclick();
  assert.equal(h.calls.find(c=>c.operation==='lightOn').parameters.brightness, '59');
});
test('stale state disables controls and never dispatches a light action', async () => {
  const h = await harness(true);
  assert.equal(h.get('on').disabled,true);
  await h.get('off').onclick();
  assert.equal(h.calls.filter(c=>c.operation!=='getStates').length,0);
});
const state = (brightness = 59, stale = false) => ({stale, value:[{entity_id:'light.game_lights',state:'on',attributes:{brightness}}]});
test('background polling keeps controls enabled and preserves an active slider drag', async () => {
  const h = await harness();
  const read = h.deferRead();
  const pending = h.poll();
  assert.equal(h.poll(), pending, 'overlapping polls share one request');
  for (const id of ['on','off','brightness']) assert.equal(h.get(id).disabled, false);
  h.get('brightness').onpointerdown();
  h.get('brightness').value = '200';
  h.get('brightness').oninput();
  read.resolve(state(70));
  await pending;
  assert.equal(h.get('brightness').value, '200');
  assert.equal(h.get('level').textContent, '78%');
  for (const id of ['on','off','brightness']) assert.equal(h.get(id).disabled, false);
  await h.get('brightness').onchange();
  assert.equal(h.calls.find(c => c.operation === 'lightOn').parameters.brightness, '200');
});
test('a user action waits for an in-flight read without overlapping native requests', async () => {
  const h = await harness();
  const read = h.deferRead();
  const pending = h.poll();
  const action = h.get('off').onclick();
  assert.equal(h.calls.some(c => c.operation === 'lightOff'), false);
  assert.equal(h.get('off').disabled, true);
  read.resolve(state());
  await Promise.all([pending, action]);
  assert.equal(h.calls.filter(c => c.operation === 'lightOff').length, 1);
  assert.equal(h.get('off').disabled, false);
});
test('a failed background read disables controls and cancels a waiting action', async () => {
  const h = await harness();
  const read = h.deferRead();
  const pending = h.poll();
  const action = h.get('off').onclick();
  read.reject(new Error('offline'));
  await pending;
  assert.equal(h.calls.some(c => c.operation === 'lightOff'), false);
  await action;
  assert.equal(h.calls.some(c => c.operation === 'lightOff'), false);
});
test('a stale background response disables previously usable controls', async () => {
  const h = await harness();
  const read = h.deferRead();
  const pending = h.poll();
  read.resolve(state(59, true));
  await pending;
  for (const id of ['on','off','brightness']) assert.equal(h.get(id).disabled, true);
});
