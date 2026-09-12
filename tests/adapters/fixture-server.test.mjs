import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createFixtureServer } from "../../tools/fixture-server/server.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

async function listen() {
  const server = createFixtureServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { server, port };
}

test("HTTP fixture stays deterministic and credential-free", async () => {
  const { server, port } = await listen();
  try {
    const status = await fetch(`http://127.0.0.1:${port}/v1/status`).then((r) => r.json());
    assert.equal(status.fixture, "SCREENPUNK_HTTP_FIXTURE_V1");
    assert.equal(status.temperatureC, 21);
    assert.equal(/token|password|bearer/i.test(JSON.stringify(status)), false);
    const missing = await fetch(`http://127.0.0.1:${port}/nope`);
    assert.equal(missing.status, 404);
    const redirect = await fetch(`http://127.0.0.1:${port}/v1/redirect`, { redirect: "manual" });
    assert.equal(redirect.status, 302);
    assert.equal(redirect.headers.get("location"), "/v1/status");
  } finally {
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
});

test("WebSocket fixture greets without echoing bodies", async () => {
  const { server, port } = await listen();
  try {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/events`);
    const first = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("ws timeout")), 3000);
      socket.addEventListener("message", (event) => {
        clearTimeout(timer);
        resolve(JSON.parse(String(event.data)));
      });
      socket.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new Error("ws error"));
      });
    });
    assert.equal(first.fixture, "SCREENPUNK_WS_FIXTURE_V1");
    assert.equal(first.event, "hello");
    const reply = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("ws reply timeout")), 3000);
      socket.addEventListener("message", (event) => {
        clearTimeout(timer);
        resolve(JSON.parse(String(event.data)));
      });
      socket.send(JSON.stringify({ secret: "must-not-echo" }));
    });
    assert.equal(reply.received, true);
    assert.equal(reply.echo, false);
    assert.equal(JSON.stringify(reply).includes("must-not-echo"), false);
    socket.close();
  } finally {
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
});

test("committed grants contain auth refs, not secrets", () => {
  for (const rel of [
    "schemas/fixtures/valid/connection-grant.json",
    "schemas/fixtures/valid/connection-grant-ws.json"
  ]) {
    const text = readFileSync(join(root, rel), "utf8");
    assert.match(text, /keychain:/);
    assert.equal(/Bearer |sk-|password=/i.test(text), false);
  }
  const vectors = JSON.parse(readFileSync(join(root, "tests/adapters/vectors.json"), "utf8"));
  assert.equal(vectors.macIsRuntimeProxy, false);
  assert.equal(vectors.followsRedirects, false);
  assert.ok(Array.isArray(vectors.cases) && vectors.cases.length >= 5);
});
