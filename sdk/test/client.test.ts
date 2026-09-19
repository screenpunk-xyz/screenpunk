import assert from "node:assert/strict";
import { test } from "node:test";
import { AUTH_OVERRIDE_KEYS } from "../src/bridge.ts";
import {
  BRIDGE_TIMEOUT_MS,
  BridgeClientError,
  CLIENT_AUTH_OVERRIDE_KEYS,
  createDashboardClient,
  type BridgeTransport
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
