import assert from "node:assert/strict";
import { test } from "node:test";
import { AUTH_OVERRIDE_KEYS, RenderReadiness, assertBridgeMessage, shouldRetry } from "../src/bridge.ts";
import { STATE_CACHE_BYTES } from "../src/limits.ts";
import { DashboardStore } from "../src/store.ts";

test("state budget and write cache rejection", () => {
  const store = new DashboardStore("dash");
  store.set("a", { n: 1 });
  assert.deepEqual(store.get("a"), { n: 1 });
  store.rememberRead(DashboardStore.cacheKey("status", "getStatus", {}), { ok: true }, 1);
  const stale = store.markStale(DashboardStore.cacheKey("status", "getStatus", {}));
  assert.equal(stale?.stale, true);
  store.rejectWriteCache("write");
  assert.throws(() => store.rememberRead("write", { ok: true }, 2));
  assert.ok(store.usedBytes() < STATE_CACHE_BYTES);
  assert.throws(() => store.set("k".repeat(300), 1));
});

test("bridge rejects auth overrides and oversized protocol", () => {
  const ok = assertBridgeMessage({
    protocolVersion: 1,
    id: "1",
    kind: "request",
    method: "connections.request",
    alias: "status",
    operation: "getStatus",
    parameters: { q: "1" }
  });
  assert.equal(ok.alias, "status");
  assert.throws(() =>
    assertBridgeMessage({
      protocolVersion: 1,
      id: "1",
      kind: "request",
      parameters: { Authorization: "secret" }
    })
  );
  assert.equal(AUTH_OVERRIDE_KEYS.includes("Authorization"), true);
  assert.equal(shouldRetry(true, false), false);
  assert.equal(shouldRetry(false, true), true);
  const ready = new RenderReadiness(() => 10);
  ready.markReady();
  assert.equal(ready.state, "ready");
  assert.equal(ready.connectionsHealthy, false);
});
