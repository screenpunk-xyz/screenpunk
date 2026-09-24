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

test('schema accepts bounded dynamic segments and rejects mixed parameter rules', () => {
  const manifest = load('schemas/fixtures/valid/minimal.json');
  manifest.connections = [{alias:'photos',required:true,publicHTTP:{origin:'https://images.example.org',userAgent:'Screenpunk/1',operations:[{
    name:'photo',path:'/photos/{filename}',response:'raster',parameters:{filename:{location:'path',pathSegment:{maxLength:128}}},maxAgeSeconds:60,staleSeconds:3600
  }]}}];
  assert.equal(validate(manifest),true,ajv.errorsText(validate.errors));
  for (const invalid of [{location:'query',pathSegment:{maxLength:128}}, {location:'path',pathSegment:{maxLength:0}}, {location:'path',pathSegment:{maxLength:257}}, {location:'path',pathSegment:{maxLength:128},values:['x']}, {location:'path',pathSegment:{maxLength:128},minimum:1,maximum:2}]) {
    manifest.connections[0].publicHTTP.operations[0].parameters.filename = invalid;
    assert.equal(validate(manifest),false);
  }
});
