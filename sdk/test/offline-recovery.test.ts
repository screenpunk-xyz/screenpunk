import assert from "node:assert/strict";
import { test } from "node:test";
import { RenderReadiness, httpBounds, shouldRetry, websocketBounds } from "../src/bridge.ts";
import {
  BACKOFF_CAP_SECONDS,
  HTTP_RESPONSE_BYTES,
  HTTP_TIMEOUT_SECONDS,
  MIN_POLL_SECONDS,
  READY_TIMEOUT_SECONDS,
  STATE_CACHE_BYTES,
  WEBSOCKET_MESSAGE_BYTES
} from "../src/limits.ts";
import { DashboardStore } from "../src/store.ts";

const key = DashboardStore.cacheKey("status", "getStatus", {});

test("a required failure marks the last read stale but keeps value and timestamp", () => {
  const store = new DashboardStore("dash");
  store.rememberRead(key, { temperatureC: 21 }, 1_000);
  const stale = store.markStale(key);
  assert.equal(stale?.stale, true);
  assert.deepEqual(stale?.value, { temperatureC: 21 });
  assert.equal(stale?.fetchedAtMs, 1_000);
  assert.equal(store.readCache(key)?.stale, true);
});

test("recovery replaces the stale record with fresh data and a new timestamp", () => {
  const store = new DashboardStore("dash");
  store.rememberRead(key, { temperatureC: 21 }, 1_000);
  store.markStale(key);
  store.rememberRead(key, { temperatureC: 19 }, 61_000);
  const record = store.readCache(key);
  assert.equal(record?.stale, false);
  assert.equal(record?.fetchedAtMs, 61_000);
  assert.deepEqual(record?.value, { temperatureC: 19 });
});

test("unknown keys and write records never become stale reads", () => {
  const store = new DashboardStore("dash");
  assert.equal(store.markStale("missing"), null);
  store.rejectWriteCache("write");
  assert.equal(store.markStale("write"), null);
  assert.throws(() => store.rememberRead("write", {}, 1), /never cache a write/);
});

test("cache key is stable across parameter key order and distinct across values", () => {
  const a = DashboardStore.cacheKey("ha", "getState", { entity: "light.desk", attrs: ["a", "b"] });
  const b = DashboardStore.cacheKey("ha", "getState", { attrs: ["a", "b"], entity: "light.desk" });
  const c = DashboardStore.cacheKey("ha", "getState", { entity: "light.lamp", attrs: ["a", "b"] });
  assert.equal(a, b);
  assert.notEqual(a, c);
  assert.notEqual(DashboardStore.cacheKey("ha", "getState", null), DashboardStore.cacheKey("ha", "getState", {}));
});

test("budget overflow fails closed without corrupting retained state", () => {
  const store = new DashboardStore("dash");
  store.set("keep", { n: 1 });
  store.rememberRead(key, { temperatureC: 21 }, 1_000);
  const before = store.usedBytes();
  assert.throws(() => store.set("big", "x".repeat(STATE_CACHE_BYTES)), /size_limit/);
  assert.throws(() => store.rememberRead("big-read", "x".repeat(STATE_CACHE_BYTES), 2_000), /size_limit/);
  assert.equal(store.usedBytes(), before);
  assert.deepEqual(store.get("keep"), { n: 1 });
  assert.deepEqual(store.readCache(key)?.value, { temperatureC: 21 });
  assert.equal(store.readCache("big-read"), null);
  assert.throws(() => store.set("", 1), /validation_failed/);
});

test("unlink clears state, cache, and byte accounting so nothing survives into the next dashboard", () => {
  const store = new DashboardStore("dash");
  store.set("theme", "dark");
  store.rememberRead(key, { temperatureC: 21 }, 1_000);
  store.rejectWriteCache("write");
  assert.ok(store.usedBytes() > 0);
  store.clear();
  assert.equal(store.get("theme"), null);
  assert.equal(store.readCache(key), null);
  assert.equal(store.readCache("write"), null);
  assert.equal(store.usedBytes(), 0);
  store.set("theme", "light");
  assert.equal(store.get("theme"), "light");
});

test("render readiness: timeout and content-process death are terminal for ready()", () => {
  let now = 0;
  const ready = new RenderReadiness(() => now);
  assert.equal(ready.state, "pending");
  assert.equal(ready.readyAtMs, null);

  now = 10;
  ready.markReady();
  assert.equal(ready.state, "ready");
  assert.equal(ready.readyAtMs, 10);
  ready.markTimeout();
  assert.equal(ready.state, "ready", "timeout after ready is ignored");

  const timedOut = new RenderReadiness(() => now);
  timedOut.markTimeout();
  timedOut.markReady();
  assert.equal(timedOut.state, "timeout", "ready after timeout is ignored");

  const died = new RenderReadiness(() => now);
  died.markReady();
  died.markProcessDeath();
  assert.equal(died.state, "content-process-terminated");
  assert.equal(died.readyAtMs, null);
  died.markReady();
  assert.equal(died.state, "content-process-terminated", "the host reloads; the page cannot self-declare ready");
  assert.equal(died.connectionsHealthy, false);
});

test("pinned runtime bounds match ScreenpunkCore.RuntimeBounds", () => {
  assert.deepEqual(httpBounds(), { timeoutSeconds: 15, maxBytes: 2 * 1024 * 1024 });
  assert.deepEqual(websocketBounds(), { maxBytes: 256 * 1024 });
  assert.equal(HTTP_TIMEOUT_SECONDS, 15);
  assert.equal(HTTP_RESPONSE_BYTES, 2 * 1024 * 1024);
  assert.equal(WEBSOCKET_MESSAGE_BYTES, 256 * 1024);
  assert.equal(STATE_CACHE_BYTES, 5 * 1024 * 1024);
  assert.equal(MIN_POLL_SECONDS, 15);
  assert.equal(BACKOFF_CAP_SECONDS, 60);
  assert.equal(READY_TIMEOUT_SECONDS, 15);
  assert.equal(MIN_POLL_SECONDS * 2 + HTTP_TIMEOUT_SECONDS, 45, "default staleness window used by the native runtime");
  assert.equal(shouldRetry(true, false), false);
  assert.equal(shouldRetry(true, true), true);
});
