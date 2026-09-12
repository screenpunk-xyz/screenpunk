import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import { test } from "node:test";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { AUTH_OVERRIDE_KEYS, type BridgeMessage } from "../src/bridge.ts";
import { createDashboardClient, type BridgeTransport } from "../src/client.ts";
import { deploymentDigest, loadPackageDirectory, resolveLocalAsset } from "../src/package.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const ajv = new Ajv({ allErrors: true, strict: true });
addFormats(ajv);
const grantValidate = ajv.compile(
  JSON.parse(readFileSync(join(root, "schemas/connection-grant.schema.json"), "utf8"))
);
const manifestValidate = ajv.compile(
  JSON.parse(readFileSync(join(root, "schemas/dashboard-manifest.schema.json"), "utf8"))
);

test("offline fixture still loads after example packages", () => {
  const loaded = loadPackageDirectory(join(root, "examples/offline-fixture"));
  assert.equal(loaded.manifest.connections.length, 0);
  assert.equal(loaded.manifest.name, "Offline fixture");
  assert.equal(loaded.manifest.digest, "bd091f72ea19147c42be65292b7e482daa7ed7097fce7d4865d29a1c46225c82");
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
  assert.equal([...loaded.assets.keys()].sort().join(","), "app.js,index.html,styles.css");
});

test("weather package loads on pinned contracts", () => {
  const loaded = loadPackageDirectory(join(root, "examples/weather"));
  assert.equal(manifestValidate(loaded.manifest), true, ajv.errorsText(manifestValidate.errors));
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
  assert.equal(loaded.manifest.connections[0]?.alias, "weather");
  assert.equal(loaded.manifest.connections[0]?.required, true);
  const html = resolveLocalAsset(loaded.assets, "screenpunk://package/index.html");
  assert.match(new TextDecoder().decode(html.bytes), /Weather data by Open-Meteo.com/);
  assert.equal(/password|secret|token|api[_-]?key|bearer|authorization/i.test(JSON.stringify(loaded.manifest)), false);
});

test("theater package loads on pinned contracts", () => {
  const loaded = loadPackageDirectory(join(root, "examples/home-assistant"));
  assert.equal(manifestValidate(loaded.manifest), true, ajv.errorsText(manifestValidate.errors));
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
  assert.equal(loaded.manifest.target.orientation, "landscape");
  assert.equal(loaded.manifest.connections.some((c) => c.alias === "home" && c.required), true);
  assert.equal(loaded.manifest.connections.some((c) => c.alias === "homeEvents" && c.required === false), true);
  assert.equal(/password|secret|token|api[_-]?key|bearer|authorization/i.test(JSON.stringify(loaded.manifest)), false);
});

test("example grants match the pinned grant schema", () => {
  const files = [
    "examples/weather/grants/fixture.json",
    "examples/weather/grants/open-meteo-customer.json",
    "examples/weather/grants/open-meteo-self-hosted.json",
    "examples/home-assistant/grants/fixture-http.json",
    "examples/home-assistant/grants/fixture-ws.json",
    "examples/home-assistant/grants/operator-http.json",
    "examples/home-assistant/grants/operator-ws.json",
    "examples/http-status/connection-grant.json",
    "examples/ws-ticker/connection-grant.json"
  ];
  for (const rel of files) {
    const grant = JSON.parse(readFileSync(join(root, rel), "utf8"));
    assert.equal(grantValidate(grant), true, `${rel} ${ajv.errorsText(grantValidate.errors)}`);
    assert.equal(/password|secret|token|api[_-]?key|bearer|authorization/i.test(JSON.stringify(grant)), false);
  }
});

test("http-status package loads and matches the browser bundle", () => {
  const loaded = loadPackageDirectory(join(root, "examples/http-status"));
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
  assert.equal(loaded.manifest.connections[0]?.alias, "status");
  assert.equal(loaded.manifest.connections[0]?.required, true);
  const html = new TextDecoder().decode(loaded.assets.get("index.html")?.bytes);
  assert.match(html, /SCREENPUNK_HTTP_STATUS_EXAMPLE_V1/);
  assert.match(html, /data-lockup="stacked"/);
  const css = new TextDecoder().decode(loaded.assets.get("styles.css")?.bytes);
  assert.match(css, /#A52C42/);
  assert.match(css, /#FF8BA0/);
  assert.equal(
    Buffer.from(loaded.assets.get("screenpunk.js")!.bytes).equals(readFileSync(join(root, "sdk/dist/screenpunk.js"))),
    true
  );
});

test("ws-ticker package loads and matches the browser bundle", () => {
  const loaded = loadPackageDirectory(join(root, "examples/ws-ticker"));
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
  assert.equal(loaded.manifest.connections[0]?.alias, "ticker");
  const html = new TextDecoder().decode(loaded.assets.get("index.html")?.bytes);
  assert.match(html, /SCREENPUNK_WS_TICKER_EXAMPLE_V1/);
  assert.match(html, /data-lockup="stacked"/);
});

test("browser bundle is standalone and installs globalThis.screenpunk", () => {
  const bundle = readFileSync(join(root, "sdk/dist/screenpunk.js"), "utf8");
  assert.equal(/\bnode:/.test(bundle), false);
  assert.equal(/\brequire\s*\(/.test(bundle), false);
  assert.equal(/\bBuffer\b/.test(bundle), false);
  assert.match(bundle, /__screenpunkDispatch/);
  const sandbox: Record<string, unknown> = { console };
  sandbox.globalThis = sandbox;
  runInNewContext(bundle, sandbox);
  const installed = sandbox.screenpunk as { runtime?: { ready?: unknown } };
  assert.equal(typeof installed?.runtime?.ready, "function");
});

test("http-status example paints fixture data through the bridge", async () => {
  const result = await runExample("examples/http-status", {
    onRequest(message, reply) {
      if (message.method === "state.get") {
        reply({ kind: "response", value: null });
        return;
      }
      if (message.method === "connections.request") {
        reply({ kind: "response", value: { fixture: "SCREENPUNK_HTTP_FIXTURE_V1", temperatureC: 21 } });
        return;
      }
      reply({ kind: "response", ok: true });
    }
  });
  assert.equal(result.document.getElementById("temperature").textContent, "21°C");
  assert.equal(result.document.getElementById("status").textContent, "Live");
  assert.equal(result.ready, true);
  result.stop?.();
  result.sdk.dispose();
});

test("ws-ticker example paints subscribe events", async () => {
  const result = await runExample("examples/ws-ticker", {
    onRequest(message, reply) {
      if (message.method === "state.get") {
        reply({ kind: "response", value: null });
        return;
      }
      reply({ kind: "response", ok: true });
    }
  });
  const subscribe = result.host.sent.find((m) => m.method === "connections.subscribe");
  assert.ok(subscribe);
  result.host.emit({
    protocolVersion: 1,
    id: subscribe!.id,
    kind: "event",
    method: "connections.subscribe",
    alias: "ticker",
    operation: "ticks",
    value: 7
  });
  await delay(10);
  assert.equal(result.document.getElementById("tick").textContent, "7");
  assert.equal(result.ready, true);
  result.sdk.dispose();
});

test("http-status and ws-ticker keep grants out and only the bundle lists deny keys", () => {
  const bundle = readFileSync(join(root, "sdk/dist/screenpunk.js"), "utf8");
  for (const key of AUTH_OVERRIDE_KEYS) {
    assert.equal(bundle.includes(`"${key}"`), true, `bundle deny-list missing ${key}`);
  }
  for (const name of ["http-status", "ws-ticker"]) {
    const loaded = loadPackageDirectory(join(root, "examples", name));
    assert.equal(loaded.assets.has("connection-grant.json"), false);
    const page = ["app.js", "index.html", "styles.css"]
      .map((path) => new TextDecoder().decode(loaded.assets.get(path)!.bytes))
      .concat(JSON.stringify(loaded.manifest))
      .join("\n");
    for (const key of AUTH_OVERRIDE_KEYS) {
      assert.equal(page.includes(`"${key}"`), false, `${name} page leaked ${key}`);
    }
  }
});

async function runExample(
  rel: string,
  options: {
    onRequest: (message: BridgeMessage, reply: (patch: Partial<BridgeMessage>) => void) => void;
  }
) {
  const host = createLoopback(options);
  const sdk = createDashboardClient({ transport: host.page });
  let ready = false;
  const originalReady = sdk.runtime.ready.bind(sdk.runtime);
  sdk.runtime.ready = () => {
    ready = true;
    originalReady();
  };
  const document = fakeDocument();
  const sandbox: Record<string, unknown> = {
    document,
    console,
    setInterval,
    clearInterval,
    setTimeout,
    clearTimeout
  };
  sandbox.globalThis = sandbox;
  sandbox.screenpunk = sdk;
  runInNewContext(readFileSync(join(root, rel, "app.js"), "utf8"), sandbox);
  const example = sandbox.screenpunkExample as { task?: Promise<unknown>; stop?: () => void };
  await example.task;
  await delay(20);
  return { sdk, host, document, ready, stop: example.stop };
}

function createLoopback(options: {
  onRequest: (message: BridgeMessage, reply: (patch: Partial<BridgeMessage>) => void) => void;
}) {
  const listeners = new Set<(message: BridgeMessage) => void>();
  const sent: BridgeMessage[] = [];
  const page: BridgeTransport = {
    send(message) {
      sent.push(message);
      queueMicrotask(() => {
        options.onRequest(message, (patch) => {
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
  return { page, sent, emit };
}

function fakeDocument() {
  const nodes = new Map<string, FakeNode>();
  function node(id: string): FakeNode {
    let current = nodes.get(id);
    if (!current) {
      current = { id, textContent: "", hidden: false, className: "" };
      nodes.set(id, current);
    }
    return current;
  }
  return {
    readyState: "complete",
    getElementById: node,
    addEventListener() {},
    nodes
  };
}

interface FakeNode {
  id: string;
  textContent: string;
  hidden: boolean;
  className: string;
}

function delay(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}
