import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const swift = readFileSync(join(root, 'tools/preview-host/Sources/SnapshotSession.swift'), 'utf8');
const script = probeScript(swift);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const readyBudgetToken = '\\(readyBudgetMs)';
// The host interpolates the remaining ready budget; run that same script.
function probe(readyBudgetMs) {
  const js = script.replaceAll(readyBudgetToken, String(readyBudgetMs));
  if (js.includes('readyBudgetMs')) throw new Error('probe script did not receive the ready budget');
  return new AsyncFunction(js)();
}
const restingFailures = ['chart', 'tabs', 'dialog', 'dialog-focus', 'focus-restoration', 'select', 'table-sort', 'carousel'];

function probeScript(source) {
  const start = source.indexOf('private func probeAuthoring');
  const body = source.slice(start);
  const open = body.indexOf('let script = """');
  const contentStart = body.indexOf('\n', open) + 1;
  const fence = body.slice(contentStart).match(/\n([ \t]*)"""/);
  if (start < 0 || open < 0 || !fence) throw new Error('authoring probe script not found');
  const indent = fence[1];
  return body.slice(contentStart, contentStart + fence.index).split('\n')
    .map(line => line.startsWith(indent) ? line.slice(indent.length) : line).join('\n');
}

// Gallery keeps Count inside a fieldset that is disabled until preference phase is ready.
function countPage({ hydrateAfter, incrementAfter = 250, ready = false } = {}) {
  let phase = ready ? 'ready' : 'loading';
  let count = 0;
  let hydratedAt = 0;
  let incrementedAt = 0;
  const polls = [];
  const clicks = [];
  const observations = [];
  const button = {
    get textContent() {
      observations.push({ at: performance.now(), count });
      return `Count ${count}`;
    },
    matches(selector) {
      const disabled = phase !== 'ready';
      polls.push({ at: performance.now(), disabled });
      return selector === ':disabled' && disabled;
    },
    click() {
      const disabled = phase !== 'ready';
      clicks.push({ at: performance.now(), disabled });
      if (disabled) return;
      // save() resolves on a later turn; a single 100ms look would still miss it.
      setTimeout(() => { count += 1; incrementedAt = performance.now(); }, incrementAfter);
    },
  };
  return {
    polls, clicks, observations,
    get count() { return count; },
    get hydratedAt() { return hydratedAt; },
    get incrementedAt() { return incrementedAt; },
    arm() { if (hydrateAfter != null) setTimeout(() => { phase = 'ready'; hydratedAt = performance.now(); }, hydrateAfter); },
    document: {
      body: { textContent: '' }, activeElement: null,
      querySelectorAll: selector => selector === 'button' ? [button] : [],
      querySelector: () => null,
      dispatchEvent() {},
    },
  };
}

// The probe's 100ms pause can fire late. Drive that clock so one poll lands past the budget.
function deferredClock() {
  let now = 0;
  const pending = [];
  let handle = 0;
  const previousNow = performance.now;
  const previousSetTimeout = globalThis.setTimeout;
  const previousClearTimeout = globalThis.clearTimeout;
  const flush = () => new Promise(resolve => setImmediate(resolve));
  performance.now = () => now;
  globalThis.setTimeout = (fn, delay = 0) => {
    pending.push({ handle: ++handle, fn, at: now + delay });
    return handle;
  };
  globalThis.clearTimeout = id => {
    const index = pending.findIndex(entry => entry.handle === id);
    if (index >= 0) pending.splice(index, 1);
  };
  const due = limit => pending.filter(entry => entry.at <= limit).sort((a, b) => a.at - b.at || a.handle - b.handle);
  return {
    async fireDue(limit) {
      for (;;) {
        const next = due(limit)[0];
        if (!next) {
          await flush();
          if (!due(limit).length) return;
          continue;
        }
        pending.splice(pending.indexOf(next), 1);
        now = next.at;
        next.fn();
        await flush();
      }
    },
    async fireOnly(scheduledAt, at = scheduledAt) {
      const index = pending.findIndex(entry => entry.at === scheduledAt);
      if (index < 0) throw new Error(`no timer at ${scheduledAt}; pending ${pending.map(entry => entry.at).join(', ') || 'none'}`);
      const [entry] = pending.splice(index, 1);
      now = at;
      entry.fn();
      await flush();
    },
    async finish(promise) {
      let settled = false;
      let value;
      let failure;
      promise.then(result => { settled = true; value = result; }, error => { settled = true; failure = error; });
      for (let guard = 0; guard < 40 && !settled; guard += 1) {
        await flush();
        if (settled || pending.length === 0) break;
        pending.sort((a, b) => a.at - b.at || a.handle - b.handle);
        const entry = pending.shift();
        now = Math.max(now, entry.at);
        entry.fn();
      }
      await flush();
      if (failure) throw failure;
      if (!settled) throw new Error(`probe still running at ${now}`);
      return value;
    },
    restore() {
      performance.now = previousNow;
      globalThis.setTimeout = previousSetTimeout;
      globalThis.clearTimeout = previousClearTimeout;
    },
  };
}

function install(document) {
  const keys = ['document', 'window', 'innerWidth', 'innerHeight', 'MouseEvent', 'KeyboardEvent'];
  const previous = new Map(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const define = (key, value) => Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  define('document', document);
  define('window', { __authoringSyntheticState: true, __authoringViolations: [] });
  define('innerWidth', 1024);
  define('innerHeight', 768);
  if (typeof globalThis.MouseEvent !== 'function') define('MouseEvent', class MouseEvent {});
  if (typeof globalThis.KeyboardEvent !== 'function') define('KeyboardEvent', class KeyboardEvent {});
  return () => {
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  };
}

test('synthetic Count probe races preference hydration against the ready deadline', async t => {
  for (const name of ['button', 'chart', 'durable-edit-disabled', 'no-volatile-edit', 'unsupported-status', 'tabs', 'dialog', 'dialog-focus', 'dialog-close', 'focus-restoration', 'select', 'durable-choice-disabled', 'table-sort', 'carousel']) {
    assert.ok(script.includes(`'${name}'`), name);
  }
  assert.match(script, /matches\(':disabled'\)/);
  assert.match(script, /\\\(readyBudgetMs\)/);

  await t.test('waits while hydration keeps Count disabled past ready+100ms, then records 1', { timeout: 8000 }, async () => {
    const hydrationDelay = 450;
    const page = countPage({ hydrateAfter: hydrationDelay });
    const restore = install(page.document);
    const origin = performance.now();
    page.arm();
    try {
      const report = await probe(2000);
      assert.equal(report.syntheticState, true);
      assert.equal(report.nativePersistenceVerified, false);
      assert.deepEqual(report.violations, []);
      assert.equal(report.width, 1024);
      assert.equal(report.height, 768);
      assert.deepEqual(report.failures, restingFailures);
      assert.equal(page.count, 1);
      assert.equal(page.clicks.length, 1);
      assert.equal(page.clicks[0].disabled, false);
      assert.ok(page.hydratedAt - origin >= hydrationDelay - 20, 'hydration returned before the delayed ready phase');
      assert.ok(page.clicks[0].at >= page.hydratedAt, 'clicked while Count was still disabled');
      assert.ok(page.polls.some(poll => poll.disabled && poll.at - origin > 100), 'Count was not still disabled after ready+100ms');
    } finally { restore(); }
  });

  await t.test('records button when Count stays disabled through the ready deadline', { timeout: 8000 }, async () => {
    const deadline = 500;
    const page = countPage({});
    const restore = install(page.document);
    const origin = performance.now();
    try {
      const report = await probe(deadline);
      assert.equal(page.count, 0);
      assert.equal(page.clicks.length, 0);
      assert.deepEqual(report.failures, ['chart', 'button', ...restingFailures.slice(1)]);
      assert.ok(page.polls.at(-1).at - origin >= deadline - 40, 'stopped polling before the ready deadline');
      assert.ok(performance.now() - origin < 8000, 'waited without a deadline');
    } finally { restore(); }
  });

  // 500ms budget: click at 100ms, Count becomes 1 at 510ms, the next poll lands at 520ms.
  await t.test('records button when Count becomes 1 on a poll after the ready deadline', async () => {
    const deadline = 500;
    const page = countPage({ ready: true, incrementAfter: 410 });
    const restore = install(page.document);
    const clock = deferredClock();
    try {
      const pending = probe(deadline);
      await clock.fireDue(100);
      assert.equal(page.clicks.length, 1);
      assert.equal(page.clicks[0].at, 100);
      assert.equal(page.clicks[0].disabled, false);
      await clock.fireDue(400);
      assert.equal(page.count, 0);
      await clock.fireOnly(510);
      assert.equal(page.incrementedAt, 510);
      assert.equal(page.count, 1);
      await clock.fireOnly(500, 520);
      assert.equal(page.observations.some(item => item.count === 1 && item.at < deadline), false);
      assert.equal(page.observations.some(item => item.count === 1 && item.at === 520), true);
      const report = await clock.finish(pending);
      assert.equal(report.syntheticState, true);
      assert.equal(page.count, 1);
      assert.deepEqual(report.failures, ['chart', 'button', ...restingFailures.slice(1)]);
    } finally {
      clock.restore();
      restore();
    }
  });
});
