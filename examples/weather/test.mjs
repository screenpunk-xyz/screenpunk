import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createWeatherFixtureServer } from "./fixture/server.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const model = require("./model.js");
const forecast = JSON.parse(readFileSync(join(here, "fixture/forecast.json"), "utf8"));

test("parses Open-Meteo fixture and keeps 15-minute poll", () => {
  const snapshot = model.parseForecast(forecast);
  assert.equal(snapshot.condition, "Partly cloudy");
  assert.equal(snapshot.temperatureC, 18.4);
  assert.equal(snapshot.days.length, 3);
  assert.equal(snapshot.days[2].label, "Light rain");
  assert.equal(snapshot.attribution, "Weather data by Open-Meteo.com");
  assert.equal(model.POLL_SECONDS, 900);
  assert.equal(model.MAX_AGE_SECONDS, 1815);
});

test("forecast parameters never include auth fields", () => {
  const query = model.forecastQuery({});
  assert.equal(query.latitude, "37.7749");
  assert.doesNotThrow(() => model.assertSafeParameters(query));
  assert.throws(() => model.assertSafeParameters({ apikey: "nope" }));
  assert.throws(() => model.assertSafeParameters({ Authorization: "nope" }));
});

test("stale host wrapper still parses", () => {
  const wrapped = { statusCode: 0, body: forecast, stale: true, fetchedAt: 1 };
  const unwrapped = model.unwrapResult(wrapped);
  assert.equal(unwrapped.stale, true);
  assert.equal(model.parseForecast(unwrapped.data).temperatureC, 18.4);
});

test("local weather fixture is deterministic and credential-free", async () => {
  const server = createWeatherFixtureServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  try {
    const payload = await fetch(`http://127.0.0.1:${port}/v1/forecast?latitude=37.7749`).then((r) => r.json());
    assert.equal(payload.current.temperature_2m, 18.4);
    assert.equal(/token|password|bearer|apikey/i.test(JSON.stringify(payload)), false);
  } finally {
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
});

test("committed weather grants have refs, not secrets", () => {
  for (const name of ["fixture.json", "open-meteo-customer.json", "open-meteo-self-hosted.json"]) {
    const text = readFileSync(join(here, "grants", name), "utf8");
    assert.match(text, /keychain:/);
    assert.equal(/Bearer |sk-|password=/i.test(text), false);
    assert.equal(JSON.parse(text).alias, "weather");
  }
});
