import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { validateManifest, type DashboardManifest, type DeviceBehavior } from "../src/package.ts";
const ajv = new Ajv({ strict: true }); addFormats(ajv);
const validateSchema = ajv.compile(JSON.parse(readFileSync(new URL("../../schemas/dashboard-manifest.schema.json", import.meta.url), "utf8")));
const behavior: DeviceBehavior = { temporaryActivation: { source: "homeAssistant", entityId: "sensor.notice", activeState: "active", inactiveState: "idle", idAttribute: "id", startedAtAttribute: "begin", expiresAtAttribute: "end", maxDurationSeconds: 45 }, audio: { autoplay: true } };
function manifest(value?: DeviceBehavior): DashboardManifest {
  const m = JSON.parse(readFileSync(new URL("../../schemas/fixtures/valid/minimal.json", import.meta.url), "utf8"));
  delete m.digest; m.deviceBehavior = value; return m;
}
test("schema and SDK accept explicit behavior, independent audio and opt-out", () => {
  for (const value of [undefined, {}, behavior, { audio: { autoplay: false } }]) {
    const m = manifest(value); assert.equal(validateSchema(m), true, ajv.errorsText(validateSchema.errors));
    assert.equal(validateManifest(m).deviceBehavior, value);
  }
});
test("schema and SDK reject malformed and unsafe declarations", () => {
  for (const patch of [{ entityId: "sensor.notice\n" }, { entityId: "sensor.a/b" }, { expiresAtAttribute: "end\n" }, { maxDurationSeconds: 0 }, { maxDurationSeconds: 3601 }, { source: "other" }]) {
    const m = manifest({ ...behavior, temporaryActivation: { ...behavior.temporaryActivation!, ...patch } } as DeviceBehavior);
    assert.equal(validateSchema(m), false); assert.throws(() => validateManifest(m));
  }
});
test("SDK enforces distinct states and attribute roles", () => {
  for (const patch of [{ inactiveState: "active" }, { expiresAtAttribute: "begin" }]) {
    const m = manifest({ ...behavior, temporaryActivation: { ...behavior.temporaryActivation!, ...patch } });
    assert.throws(() => validateManifest(m));
  }
});
