import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createFixtureServer } from "../../tools/fixture-server/server.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const script = join(root, "tools/fixture-server/server.mjs");

/** The token requirement is read at module load, so a token-protected fixture runs in its own process. */
function spawnFixture(env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script], {
      env: { ...process.env, SCREENPUNK_FIXTURE_PORT: "0", ...env },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let out = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`fixture-server did not start: ${out}`));
    }, 5000);
    child.stdout.on("data", (chunk) => {
      out += String(chunk);
      const match = out.match(/fixture-server (\d+)/);
      if (match) {
        clearTimeout(timer);
        resolve({
          port: Number(match[1]),
          stop: () =>
            new Promise((done) => {
              child.once("exit", () => done());
              child.kill();
            })
        });
      }
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`fixture-server exited early (${code}): ${out}`));
    });
  });
}

async function listen() {
  const server = createFixtureServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    port,
    stop: () => new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())))
  };
}

function waitForClose(socket, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("ws close timeout")), timeoutMs);
    socket.addEventListener("close", (event) => {
      clearTimeout(timer);
      resolve(event.code);
    });
  });
}

test("API auth expiry: token-protected fixture returns 401 until the right bearer is presented", async () => {
  const fixture = await spawnFixture({ SCREENPUNK_FIXTURE_TOKEN: "fixture-token" });
  try {
    const anonymous = await fetch(`http://127.0.0.1:${fixture.port}/v1/status`);
    assert.equal(anonymous.status, 401);
    const body = await anonymous.json();
    assert.equal(body.error, "unauthorized");
    assert.equal(JSON.stringify(body).includes("fixture-token"), false, "401 bodies never echo the expected secret");

    const wrong = await fetch(`http://127.0.0.1:${fixture.port}/v1/status`, {
      headers: { authorization: "Bearer stale-token" }
    });
    assert.equal(wrong.status, 401);

    const queryLeak = await fetch(`http://127.0.0.1:${fixture.port}/v1/status?token=fixture-token`);
    assert.equal(queryLeak.status, 401, "query-string credentials are not accepted as a header substitute");

    const ok = await fetch(`http://127.0.0.1:${fixture.port}/v1/status`, {
      headers: { authorization: "Bearer fixture-token" }
    });
    assert.equal(ok.status, 200);
    assert.equal((await ok.json()).fixture, "SCREENPUNK_HTTP_FIXTURE_V1");

    const upgrade = new WebSocket(`ws://127.0.0.1:${fixture.port}/v1/events`);
    const failed = await new Promise((resolve) => {
      upgrade.addEventListener("error", () => resolve(true));
      upgrade.addEventListener("open", () => resolve(false));
    });
    assert.equal(failed, true, "unauthenticated websocket upgrade is refused");
  } finally {
    await fixture.stop();
  }
});

test("WebSocket frames above the 256 KiB bound close with 1009 instead of being processed", async () => {
  const fixture = await listen();
  try {
    const socket = new WebSocket(`ws://127.0.0.1:${fixture.port}/v1/events`);
    await new Promise((resolve, reject) => {
      socket.addEventListener("message", () => resolve(), { once: true });
      socket.addEventListener("error", () => reject(new Error("ws error")));
    });
    const closed = waitForClose(socket);
    socket.send("x".repeat(256 * 1024 + 1));
    assert.equal(await closed, 1009);
  } finally {
    await fixture.stop();
  }
});

test("WebSocket frames at the bound are still acknowledged without echo", async () => {
  const fixture = await listen();
  try {
    const socket = new WebSocket(`ws://127.0.0.1:${fixture.port}/v1/events`);
    await new Promise((resolve, reject) => {
      socket.addEventListener("message", () => resolve(), { once: true });
      socket.addEventListener("error", () => reject(new Error("ws error")));
    });
    const reply = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("no ack")), 3000);
      socket.addEventListener(
        "message",
        (event) => {
          clearTimeout(timer);
          resolve(JSON.parse(String(event.data)));
        },
        { once: true }
      );
    });
    socket.send("y".repeat(256 * 1024));
    const ack = await reply;
    assert.equal(ack.received, true);
    assert.equal(ack.echo, false);
    socket.close();
    await waitForClose(socket);
  } finally {
    await fixture.stop();
  }
});

test("oversized upstream bodies are capped by the fixture so size-limit tests stay deterministic", async () => {
  const fixture = await listen();
  try {
    const capped = await fetch(`http://127.0.0.1:${fixture.port}/v1/blob?bytes=99999999`);
    const text = await capped.text();
    assert.ok(text.length > 2 * 1024 * 1024, "exceeds the native 2 MiB response bound");
    assert.ok(text.length < 3 * 1024 * 1024 + 256, "but stays under the fixture cap");
    const small = await fetch(`http://127.0.0.1:${fixture.port}/v1/blob?bytes=16`).then((r) => r.json());
    assert.equal(small.blob, "x".repeat(16));
    const nonUpgrade = await fetch(`http://127.0.0.1:${fixture.port}/v1/events`);
    assert.equal(nonUpgrade.status, 426);
  } finally {
    await fixture.stop();
  }
});
