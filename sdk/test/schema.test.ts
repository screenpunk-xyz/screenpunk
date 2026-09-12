import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const schema = JSON.parse(
  readFileSync(join(root, "schemas/dashboard-manifest.schema.json"), "utf8")
);
const ajv = new Ajv({ allErrors: true, strict: true });
addFormats(ajv);
const validate = ajv.compile(schema);

function load(rel: string) {
  return JSON.parse(readFileSync(join(root, rel), "utf8"));
}

test("valid minimal fixture", () => {
  assert.equal(validate(load("schemas/fixtures/valid/minimal.json")), true, ajv.errorsText(validate.errors));
});

test("rejects unsupported schema major", () => {
  assert.equal(validate(load("schemas/fixtures/invalid/unsupported-major.json")), false);
});

test("rejects path traversal", () => {
  assert.equal(validate(load("schemas/fixtures/invalid/path-traversal.json")), false);
});

test("rejects missing entrypoint only after semantic validation", () => {
  assert.equal(validate(load("schemas/fixtures/invalid/missing-entrypoint.json")), true);
});

test("schema still accepts duplicate paths; validator rejects them", () => {
  assert.equal(validate(load("schemas/fixtures/invalid/duplicate-path.json")), true);
});

test("connection grant schema", () => {
  const grantSchema = JSON.parse(
    readFileSync(join(root, "schemas/connection-grant.schema.json"), "utf8")
  );
  const grantValidate = ajv.compile(grantSchema);
  assert.equal(grantValidate(load("schemas/fixtures/valid/connection-grant.json")), true, ajv.errorsText(grantValidate.errors));
  assert.equal(grantSchema.$id, "https://screenpunk.xyz/schemas/connection-grant/v1.json");
});

test("pinned manifest schema id", () => {
  assert.equal(schema.$id, "https://screenpunk.xyz/schemas/dashboard-manifest/v1.json");
});
