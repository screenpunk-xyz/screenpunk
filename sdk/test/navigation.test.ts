import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { validateManifest, type DashboardManifest } from "../src/package.ts";
function manifest(): DashboardManifest {
  const m = JSON.parse(readFileSync(new URL("../../schemas/fixtures/valid/minimal.json", import.meta.url), "utf8")) as DashboardManifest;
  delete m.digest;
  m.pages = [{ id: "home", name: "Home", path: "index.html" }, { id: "door", name: "Front door", path: "index.html" }];
  m.defaultPageId = "home";
  m.connections = [{ alias: "events", required: false, operations: [{ name: "changes", kind: "ws" }] }, { alias: "current", required: false, operations: [{ name: "read", kind: "http" }] }];
  m.eventRules = [{ id: "doorbell", name: "Doorbell", source: { mode: "live", alias: "events", operation: "changes", parameters: {}, refreshOperation: "read", refreshAlias: "current" }, condition: { field: ["active"], equals: true }, defaults: { enabled: true, pageId: "door", returnBehavior: "conditionClear", timeoutSeconds: 30, allowPayloadOverrides: true }, priority: 0, userConfigurable: true, allowedPageIds: ["home"], allowedReturnBehaviors: ["stay", "timeout"], allowTimeoutOverride: true, payload: { timeoutSeconds: ["seconds"], eventId: ["id"] } }];
  return m;
}
test("pages and condition rules validate with separate read refresh grant", () => { assert.equal(validateManifest(manifest()).defaultPageId, "home"); });
test("navigation rejects undeclared pages, operations and untracked clears", () => {
  const changes: ((m: DashboardManifest) => void)[] = [
    m => { m.pages![0].path = "missing.html"; },
    m => { m.defaultPageId = "missing"; },
    m => { m.eventRules![0].source.operation = "unapproved"; },
    m => { m.eventRules![0].source.refreshAlias = "unapproved"; },
    m => { delete m.eventRules![0].condition; },
    m => { m.eventRules![0].defaults.timeoutSeconds = 3601; },
    m => { m.eventRules![0].payload!.eventId = ["__proto__"]; }
  ];
  for (const change of changes) { const m = manifest(); change(m); assert.throws(() => validateManifest(m)); }
});
test("polling requires a condition and a bounded interval", () => {
  const m = manifest(); const r = m.eventRules![0]; r.source = { mode: "poll", alias: "current", operation: "read", parameters: {}, pollIntervalSeconds: 15 };
  assert.doesNotThrow(() => validateManifest(m));
  r.source.pollIntervalSeconds = 1; assert.throws(() => validateManifest(m));
});
