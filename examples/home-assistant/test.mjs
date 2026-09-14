import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createHomeAssistantFixtureServer } from "./fixture/server.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const model = require("./model.js");
const states = JSON.parse(readFileSync(join(here, "fixture/states.json"), "utf8"));

test("theater snapshot disables unavailable lights and keeps media", () => {
  const snapshot = model.parseTheater(states);
  assert.equal(snapshot.lights.length, 2);
  assert.equal(snapshot.lights[0].on, true);
  assert.equal(snapshot.lights[1].unavailable, true);
  assert.equal(snapshot.scenes[0].name, "Movie");
  assert.equal(snapshot.media[0].source, "Apple TV");
  assert.equal(snapshot.media[0].volume, 0.4);
  assert.equal(model.POLL_SECONDS, 2);
});

test("configured entity filter omits extra lights", () => {
  const snapshot = model.parseTheater(states, { lights: ["light.theater"] });
  assert.equal(snapshot.lights.length, 1);
  assert.equal(snapshot.lights[0].entityId, "light.theater");
});

test("state_changed updates volume without a write cache", () => {
  const snapshot = model.parseTheater(states);
  const next = model.applyStateChanged(snapshot, {
    event: {
      data: {
        new_state: {
          entity_id: "media_player.theater",
          state: "paused",
          attributes: { volume_level: 0.2, source: "Blu-ray", source_list: ["Apple TV", "Blu-ray"] }
        }
      }
    }
  });
  assert.equal(next.media[0].paused, true);
  assert.equal(next.media[0].volume, 0.2);
});

test("write parameters reject auth overrides", () => {
  assert.deepEqual(model.lightParameters("light.theater"), { entity_id: "light.theater" });
  assert.throws(() => model.assertSafeParameters({ token: "nope" }));
});

test("HA fixture HTTP writes and stays secret-free", async () => {
  const server = createHomeAssistantFixtureServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  try {
    const before = await fetch(`http://127.0.0.1:${port}/api/states`).then((r) => r.json());
    assert.equal(before[0].state, "on");
    assert.equal(/token|password|bearer/i.test(JSON.stringify(before)), false);
    await fetch(`http://127.0.0.1:${port}/api/services/light/turn_off`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ entity_id: "light.theater" })
    });
    const after = await fetch(`http://127.0.0.1:${port}/api/states`).then((r) => r.json());
    assert.equal(after.find((item) => item.entity_id === "light.theater").state, "off");
  } finally {
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
});

test("committed HA grants have refs, not secrets", () => {
  for (const name of ["fixture-http.json", "fixture-ws.json", "operator-http.json", "operator-ws.json"]) {
    const text = readFileSync(join(here, "grants", name), "utf8");
    assert.match(text, /keychain:/);
    assert.equal(/Bearer |sk-|password=/i.test(text), false);
  }
});


test("native SDK envelopes preserve states and stale status", () => {
  const result = model.unwrapResult({ value: states, stale: true });
  assert.deepEqual(result.data, states);
  assert.equal(result.stale, true);
  assert.ok(model.parseTheater(result.data).lights.length > 0);
});
