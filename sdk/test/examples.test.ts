import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
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
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
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
    "examples/home-assistant/grants/operator-ws.json"
  ];
  for (const rel of files) {
    const grant = JSON.parse(readFileSync(join(root, rel), "utf8"));
    assert.equal(grantValidate(grant), true, `${rel} ${ajv.errorsText(grantValidate.errors)}`);
  }
});
