import assert from "node:assert/strict";
import { getEventListeners } from "node:events";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { AUTH_OVERRIDE_KEYS } from "../src/bridge.ts";
import {
  BRIDGE_TIMEOUT_MS,
  BridgeClientError,
  CLIENT_AUTH_OVERRIDE_KEYS,
  createDashboardClient,
  type BridgeTransport,
  type DashboardClient
} from "../src/client.ts";
import { HTTP_TIMEOUT_SECONDS, MAX_BRIDGE_MESSAGE_BYTES } from "../src/limits.ts";
import type { BridgeMessage } from "../src/bridge.ts";

test("browser client constants match pinned bounds", () => {
  assert.equal(BRIDGE_TIMEOUT_MS, HTTP_TIMEOUT_SECONDS * 1000);
  assert.deepEqual([...CLIENT_AUTH_OVERRIDE_KEYS], AUTH_OVERRIDE_KEYS);
  assert.equal(64 * 1024, MAX_BRIDGE_MESSAGE_BYTES);
});

test("request, state, ready, and stale flag", async () => {
  const host = createLoopback({
    onRequest(message, reply) {
      if (message.method === "connections.request") {
        reply({ kind: "response", value: { temperatureC: 21 }, stale: true });
        return;
      }
      if (message.method === "state.set") {
        host.state.set(message.key ?? "", message.value);
        reply({ kind: "response", ok: true });
        return;
      }
      if (message.method === "state.get") {
        reply({ kind: "response", value: host.state.get(message.key ?? "") ?? null });
        return;
      }
      if (message.method === "state.remove") {
        host.state.delete(message.key ?? "");
        reply({ kind: "response", ok: true });
        return;
      }
      reply({ kind: "response", ok: true });
    }
  });
  const sdk = createDashboardClient({ transport: host.page });
  const reading = await sdk.connections.request("status", "getStatus", {});
  assert.deepEqual(reading, { value: { temperatureC: 21 }, stale: true });
  await sdk.state.set("lastReading", reading.value);
  assert.deepEqual(await sdk.state.get("lastReading"), { temperatureC: 21 });
  await sdk.state.remove("lastReading");
  assert.equal(await sdk.state.get("lastReading"), null);
  sdk.runtime.ready();
  assert.equal(host.sent.some((m) => m.method === "runtime.ready"), true);
  sdk.dispose();
});

test("subscribe events and unsubscribe", async () => {
  const host = createLoopback({
    onRequest(message, reply) {
      reply({ kind: "response", ok: true });
    }
  });
  const sdk = createDashboardClient({ transport: host.page });
  const ticks: unknown[] = [];
  const stop = sdk.connections.subscribe("ticker", "ticks", {}, (message) => {
    ticks.push(message);
  });
  await delay(10);
  const subscribe = host.sent.find((m) => m.method === "connections.subscribe");
  assert.ok(subscribe);
  host.emit({
    protocolVersion: 1,
    id: subscribe!.id,
    kind: "event",
    method: "connections.subscribe",
    alias: "ticker",
    operation: "ticks",
    value: 3
  });
  assert.deepEqual(ticks, [3]);
  stop();
  await delay(10);
  assert.equal(host.sent.some((m) => m.method === "connections.unsubscribe"), true);
  sdk.dispose();
});

test("onStatus and auth-header deny", async () => {
  const host = createLoopback({
    onRequest(_message, reply) {
      reply({ kind: "response", ok: true });
    }
  });
  const sdk = createDashboardClient({ transport: host.page });
  const statuses: unknown[] = [];
  const stop = sdk.runtime.onStatus((status) => statuses.push(status));
  await delay(10);
  host.emit({
    protocolVersion: 1,
    id: "status-1",
    kind: "event",
    method: "runtime.onStatus",
    value: { message: "optional fault" }
  });
  assert.deepEqual(statuses, [{ message: "optional fault" }]);
  stop();
  await assert.rejects(
    () => sdk.connections.request("status", "getStatus", { Authorization: "nope" }),
    (err: unknown) => err instanceof BridgeClientError && err.code === "permission_required"
  );
  sdk.dispose();
});

test("silent host times out with pinned error code", async () => {
  const host = createLoopback();
  const sdk = createDashboardClient({ transport: host.page, timeoutMs: 20 });
  await assert.rejects(
    () => sdk.connections.request("status", "getStatus", {}),
    (err: unknown) =>
      err instanceof BridgeClientError && err.code === "render_timeout" && err.message === "bridge_timeout"
  );
  sdk.dispose();
});

function createLoopback(options?: {
  onRequest?: (message: BridgeMessage, reply: (patch: Partial<BridgeMessage>) => void) => void;
}) {
  const listeners = new Set<(message: BridgeMessage) => void>();
  const sent: BridgeMessage[] = [];
  const state = new Map<string, unknown>();
  const page: BridgeTransport = {
    send(message) {
      sent.push(message);
      queueMicrotask(() => {
        options?.onRequest?.(message, (patch) => {
          emit({
            protocolVersion: 1,
            id: message.id,
            kind: "response",
            method: message.method,
            ok: true,
            ...patch
          });
        });
      });
    },
    onMessage(handler) {
      listeners.add(handler);
      return () => {
        listeners.delete(handler);
      };
    }
  };
  function emit(message: BridgeMessage) {
    for (const listener of listeners) listener(message);
  }
  return { page, sent, state, emit };
}

function delay(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

test("manual page navigation and status use native bridge", async () => {
  const host = createLoopback({ onRequest(message, reply) {
    if (message.method === "navigation.open") {
      assert.deepEqual(message.parameters, { pageId: "front-door" });
      reply({ kind: "response", ok: true });
    } else reply({ kind: "response", value: { pageId: "front-door", activeRuleId: "doorbell" } });
  } });
  const sdk = createDashboardClient({ transport: host.page });
  await sdk.navigation.open("front-door");
  assert.deepEqual(await sdk.navigation.get(), { pageId: "front-door", activeRuleId: "doorbell" });
  sdk.dispose();
});

test("general Home Assistant call preserves nested values and propagates errors without replay", async () => {
  const call = { domain: "light", service: "turn_on", target: { entity_id: ["light.a"] },
    serviceData: { rgb_color: [255, 0, 128], transition: 1.5, future: { enabled: true, unset: null } } };
  const host = createLoopback({ onRequest(message, reply) {
    assert.equal(message.alias, "home");
    assert.equal(message.operation, "callService");
    assert.deepEqual(JSON.parse(message.parameters!.call as string), call);
    reply({ kind: "error", code: "permission_required", message: "permission_required" });
  }});
  const sdk = createDashboardClient({ transport: host.page });
  await assert.rejects(sdk.homeAssistant.callService(call), { code: "permission_required" });
  assert.equal(host.sent.length, 1);
  await assert.rejects(sdk.homeAssistant.callService({ ...call, serviceData: { value: "x".repeat(32768) } }), { code: "size_limit" });
  assert.equal(host.sent.length, 1);
  sdk.dispose();
});

test("service data rejects non-JSON values before native dispatch", async () => {
  const host = createLoopback({ onRequest(_message, reply) { reply({ kind: "response", value: null }); } });
  const sdk = createDashboardClient({ transport: host.page });
  for (const value of [NaN, Infinity, undefined, () => 1, new Date()]) {
    await assert.rejects(sdk.homeAssistant.callService({domain:'test',service:'call',serviceData:{value: value as never}}), {code:'validation_failed'});
  }
  assert.equal(host.sent.length, 0);
  sdk.dispose();
});

for (const operation of ["voice", "launchChannel", "togglePower"]) test(`Google TV ${operation} gets a bounded deadline and cancels native work without replay`, async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const host = createLoopback({ onRequest() {} });
  const sdk = createDashboardClient({ transport: host.page });
  const pending = sdk.connections.request("googleTV", operation, operation === "voice" ? { text: "Watch CNBC" } : { channelID: "LXfrE81qMGA" });
  const rejected = assert.rejects(pending, /bridge_timeout/);
  t.mock.timers.tick(15000);
  assert.equal(host.sent.filter(m => m.method === "connections.cancel").length, 0);
  t.mock.timers.tick(30000);
  await rejected;
  const requests = host.sent.filter(m => m.method === "connections.request");
  const cancel = host.sent.find(m => m.method === "connections.cancel");
  assert.equal(requests.length, 1);
  assert.equal(cancel?.parameters?.requestId, requests[0].id);
  sdk.dispose();
});

test("request abort cancels the exact native waiter once and ignores its late response", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const host = createLoopback();
  let nextID = 0;
  const sdk = createDashboardClient({ transport: host.page, nowId: () => `request-${++nextID}` });
  const controller = new AbortController();
  const pending = sdk.connections.request("googleTV", "voice", { text: "Watch CNBC" }, { signal: controller.signal });
  const rejected = assert.rejects(pending, { name: "AbortError" });
  // Dispatch remains synchronous so a trusted tap can reach the native voice gate.
  assert.equal(host.sent.length, 1);
  assert.equal(getEventListeners(controller.signal, "abort").length, 1);
  const request = host.sent[0];
  controller.abort();
  controller.abort();
  assert.equal(host.sent.length, 2);
  assert.equal(host.sent[1].method, "connections.cancel");
  assert.deepEqual(host.sent[1].parameters, { requestId: request.id });
  await rejected;
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  host.emit({ ...request, kind: "response", value: "too late", stale: false });
  t.mock.timers.tick(45_000);
  assert.equal(host.sent.length, 2, "abort clears the deadline and cannot send another cancellation");
  const following = sdk.connections.request("status", "getStatus", {});
  const followingRequest = host.sent[2];
  host.emit({ ...request, kind: "response", value: "still too late" });
  host.emit({ ...followingRequest, kind: "response", value: "current", stale: true });
  assert.deepEqual(await following, { value: "current", stale: true });
  sdk.dispose();
});

test("pre-aborted request sends no request or cancellation and retains no listener", async () => {
  const host = createLoopback();
  let ids = 0;
  const sdk = createDashboardClient({ transport: host.page, nowId: () => `${++ids}` });
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(sdk.connections.request("googleTV", "voice", {}, { signal: controller.signal }), { name: "AbortError" });
  assert.equal(host.sent.length, 0);
  assert.equal(ids, 0);
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  sdk.dispose();
});

test("request removes the abort listener after successful completion", async () => {
  const host = createLoopback({ onRequest(_message, reply) { reply({ value: "done", stale: true }); } });
  const sdk = createDashboardClient({ transport: host.page });
  const controller = new AbortController();
  assert.deepEqual(await sdk.connections.request("status", "getStatus", {}, { signal: controller.signal }), { value: "done", stale: true });
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  controller.abort();
  assert.equal(host.sent.length, 1);
  sdk.dispose();
});

for (const outcome of ["host error", "timeout", "dispose", "send failure"] as const) {
  test(`request removes the abort listener after ${outcome}`, async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const host = createLoopback();
    if (outcome === "send failure") host.page.send = () => { throw new Error("closed"); };
    const sdk = createDashboardClient({ transport: host.page });
    const controller = new AbortController();
    const pending = sdk.connections.request("status", "getStatus", {}, { signal: controller.signal });
    const rejected = assert.rejects(pending, outcome === "send failure" ? /closed/ : outcome === "timeout" ? /bridge_timeout/ : outcome === "dispose" ? /disposed/ : /permission_required/);
    if (outcome === "host error") host.emit({ ...host.sent[0], kind: "error", code: "permission_required" });
    if (outcome === "timeout") t.mock.timers.tick(BRIDGE_TIMEOUT_MS);
    if (outcome === "dispose") sdk.dispose();
    await rejected;
    assert.equal(getEventListeners(controller.signal, "abort").length, 0);
    const sent = host.sent.length;
    controller.abort();
    t.mock.timers.tick(45_000);
    assert.equal(host.sent.length, sent);
    sdk.dispose();
  });
}

test("request abort settles even when the cancellation transport throws", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const host = createLoopback();
  const send = host.page.send;
  host.page.send = message => {
    if (message.method === "connections.cancel") throw new Error("closed");
    send(message);
  };
  const sdk = createDashboardClient({ transport: host.page });
  const controller = new AbortController();
  const pending = sdk.connections.request("googleTV", "voice", {}, { signal: controller.signal });
  const rejected = assert.rejects(pending, { name: "AbortError" });
  assert.doesNotThrow(() => controller.abort());
  await rejected;
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  t.mock.timers.tick(45_000);
  assert.equal(host.sent.length, 1);
  sdk.dispose();
});

test("native preinstalled SDK keeps cancellable requests when a screen installs the SDK", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const bundle = readFileSync(new URL("../../packages/ScreenpunkApple/Sources/ScreenpunkApple/Resources/runtime-sdk.js", import.meta.url), "utf8");
  const sent: BridgeMessage[] = [];
  const sandbox: Record<string, unknown> = {
    TextEncoder, DOMException, setTimeout, clearTimeout,
    webkit: { messageHandlers: { screenpunk: { postMessage(message: BridgeMessage) { sent.push(message); } } } }
  };
  // DashboardWebView injects this resource at documentStart, before the screen's SDK.
  runInNewContext(bundle, sandbox);
  const nativeClient = sandbox.screenpunk as DashboardClient;
  runInNewContext(bundle, sandbox);
  const api = sandbox.ScreenpunkSDK as { installScreenpunk(): DashboardClient };
  assert.equal(api.installScreenpunk(), nativeClient);
  assert.equal(sandbox.screenpunk, nativeClient);
  const controller = new AbortController();
  const pending = nativeClient.connections.request("googleTV", "voice", { text: "Watch CNBC" }, { signal: controller.signal });
  const rejected = assert.rejects(pending, { name: "AbortError" });
  assert.equal(sent.length, 1, "the preinstalled native client dispatches in the tap call stack");
  controller.abort();
  await rejected;
  assert.equal(sent.length, 2);
  assert.equal(sent[1].method, "connections.cancel");
  assert.equal(sent[1].parameters?.requestId, sent[0].id);
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  (sandbox.__screenpunkDispatch as (message: BridgeMessage) => void)({ ...sent[0], kind: "response", value: "late" });
  t.mock.timers.tick(45_000);
  assert.equal(sent.length, 2);
  nativeClient.dispose();
});
