import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { AUTH_OVERRIDE_KEYS, assertBridgeMessage } from "../src/bridge.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

interface GrantCase {
  id: string;
  operation: string;
  parameters: Record<string, string>;
  resolvedAddresses: string[];
  expect: "allow" | "validation_failed" | "permission_required" | "denied_egress" | "size_limit";
  schemaValid?: boolean;
  grant: Record<string, unknown>;
}

const vectors = JSON.parse(readFileSync(join(root, "tests/adapters/vectors.json"), "utf8")) as {
  macIsRuntimeProxy: boolean;
  followsRedirects: boolean;
  selfSignedHTTPSTrustedSilently: boolean;
  globalArbitraryLoads: boolean;
  cases: GrantCase[];
};

const ajv = new Ajv({ allErrors: true, strict: true });
addFormats(ajv);
const validateGrant = ajv.compile(
  JSON.parse(readFileSync(join(root, "schemas/connection-grant.schema.json"), "utf8"))
);

test("adapter grant vectors are unique, credential-free where allowed, and cover every decision", () => {
  assert.equal(vectors.macIsRuntimeProxy, false);
  assert.equal(vectors.followsRedirects, false);
  assert.equal(vectors.selfSignedHTTPSTrustedSilently, false);
  assert.equal(vectors.globalArbitraryLoads, false);
  assert.ok(vectors.cases.length >= 60);

  const ids = vectors.cases.map((c) => c.id);
  assert.equal(new Set(ids).size, ids.length, "case ids must be unique");

  const decisions = new Set(vectors.cases.map((c) => c.expect));
  for (const expected of ["allow", "validation_failed", "permission_required", "denied_egress", "size_limit"]) {
    assert.ok(decisions.has(expected as GrantCase["expect"]), `vectors must exercise ${expected}`);
  }

  for (const c of vectors.cases) {
    const blob = JSON.stringify(c.grant);
    const credentialShaped = /bearer |token=|password=|sk-/i.test(blob);
    if (credentialShaped) {
      assert.equal(c.expect, "validation_failed", `${c.id}: credential-shaped grants must be rejected`);
    }
    if (c.expect === "allow") {
      assert.match(String(c.grant.authRef), /^keychain:/, `${c.id}: allowed grants reference the Keychain, never a secret`);
    }
  }
});

test("every vector grant that reaches a runtime decision is valid against the pinned grant schema", () => {
  for (const c of vectors.cases) {
    const valid = validateGrant(c.grant);
    if (c.schemaValid === false) {
      assert.equal(valid, false, `${c.id}: schema must reject this document`);
      assert.equal(c.expect, "validation_failed", `${c.id}: schema-invalid documents fail validation`);
    } else {
      assert.equal(valid, true, `${c.id}: ${ajv.errorsText(validateGrant.errors)}`);
    }
    if (c.expect === "allow") {
      assert.notEqual(c.schemaValid, false, `${c.id}: an allowed grant cannot be schema-invalid`);
    }
  }
});

/** Mirrors ScreenpunkCore.ConnectionAuthKeys.overrideKeys (lower-cased). */
const POLICY_OVERRIDE_KEYS = [
  "authorization",
  "x-api-key",
  "token",
  "password",
  "access_token",
  "api_key",
  "apikey",
  "secret"
];

test("bridge auth-override keys are a subset of the native policy's override keys", () => {
  for (const key of AUTH_OVERRIDE_KEYS) {
    assert.ok(POLICY_OVERRIDE_KEYS.includes(key.toLowerCase()), `${key} must also be refused natively`);
  }
});

test("override vectors the bridge already knows about are refused before reaching the host", () => {
  const overrideCases = vectors.cases.filter(
    (c) => c.expect === "permission_required" && Object.keys(c.parameters).some((k) => POLICY_OVERRIDE_KEYS.includes(k.toLowerCase()))
  );
  assert.ok(overrideCases.length >= 5);
  for (const c of overrideCases) {
    const bridgeKnown = Object.keys(c.parameters).filter((key) => AUTH_OVERRIDE_KEYS.includes(key));
    if (bridgeKnown.length === 0) continue;
    assert.throws(
      () =>
        assertBridgeMessage({
          protocolVersion: 1,
          id: c.id,
          kind: "request",
          method: "connections.request",
          alias: String(c.grant.alias),
          operation: c.operation,
          parameters: c.parameters
        }),
      /permission_required/,
      `${c.id}: bridge must refuse ${bridgeKnown.join(",")}`
    );
  }
});

test("vectors that exceed the parameter budget are also refused by the bridge size limit or the policy", () => {
  const oversized = vectors.cases.filter((c) => c.expect === "size_limit");
  assert.ok(oversized.length >= 1);
  for (const c of oversized) {
    assert.ok(Buffer.byteLength(JSON.stringify(c.parameters)) > 8 * 1024, `${c.id}: must exceed 8 KiB`);
  }
  const atLimit = vectors.cases.find((c) => c.id === "parameters-at-limit-allowed");
  assert.ok(atLimit);
  assert.equal(Buffer.byteLength(JSON.stringify(atLimit.parameters)), 8 * 1024);
});
