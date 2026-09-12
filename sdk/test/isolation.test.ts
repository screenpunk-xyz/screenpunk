import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  CONTENT_PROCESS_TERMINATED,
  CONTENT_SECURITY_POLICY,
  CUSTOM_SCHEME,
  NATIVE_NETWORKING_ONLY,
  decideIsolation,
  type IsolationDecision,
  type IsolationRequestKind
} from "../src/isolation.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const fixtures = JSON.parse(
  readFileSync(join(root, "tests/feasibility/isolation/attacks.json"), "utf8")
) as {
  cspMustInclude: string;
  nativeNetworkingOnly: boolean;
  contentProcessFailure: string;
  cases: Array<{
    id: string;
    kind: IsolationRequestKind;
    url: string;
    isMainFrame: boolean;
    expect: IsolationDecision;
  }>;
};

test("CSP denies connect and native networking is required", () => {
  assert.equal(CUSTOM_SCHEME, "screenpunk");
  assert.ok(CONTENT_SECURITY_POLICY.includes(fixtures.cspMustInclude));
  assert.equal(NATIVE_NETWORKING_ONLY, fixtures.nativeNetworkingOnly);
  assert.equal(CONTENT_PROCESS_TERMINATED, fixtures.contentProcessFailure);
});

for (const c of fixtures.cases) {
  test(`isolation fixture ${c.id}`, () => {
    assert.equal(
      decideIsolation({ kind: c.kind, url: c.url, isMainFrame: c.isMainFrame }),
      c.expect
    );
  });
}
