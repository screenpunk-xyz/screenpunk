import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const catalog = JSON.parse(
  readFileSync(
    join(root, "packages/ScreenpunkController/Sources/ScreenpunkController/Resources/mcp-catalog.json"),
    "utf8"
  )
);
const help = JSON.parse(
  readFileSync(
    join(root, "packages/ScreenpunkController/Sources/ScreenpunkController/Resources/help.json"),
    "utf8"
  )
);
const mcpDocs = readFileSync(join(root, "docs/mcp.md"), "utf8");

test("catalog keeps preview live, hidden helper, and stable errors", () => {
  assert.equal(catalog.previewLiveDefault, true);
  assert.equal(catalog.helperStartsAutomatically, true);
  assert.equal(catalog.workbenchMustBeVisible, false);
  assert.equal(catalog.neverPathOnlyPreview, true);
  assert.equal(catalog.neverPlaceholderImage, true);
  const names = catalog.tools.map((tool) => tool.name);
  for (const required of [
    "preview_dashboard",
    "interact_preview",
    "update_dashboard",
    "validate_dashboard",
    "get_help",
    "propose_connection"
  ]) {
    assert.equal(names.includes(required), true, required);
  }
  const preview = catalog.tools.find((tool) => tool.name === "preview_dashboard");
  assert.match(preview.description, /Live preview/);
  assert.match(preview.description, /live by default/i);
  for (const code of [
    "not_paired",
    "permission_required",
    "revision_conflict",
    "render_timeout",
    "validation_failed"
  ]) {
    assert.equal(catalog.errors.includes(code), true, code);
  }
});

test("catalog pairs and deploys through the LAN link without self-approval", () => {
  const byName = Object.fromEntries(catalog.tools.map((tool) => [tool.name, tool]));
  for (const required of [
    "discover_services",
    "list_devices",
    "get_device",
    "request_pairing",
    "confirm_pairing",
    "forget_device",
    "deploy_dashboard",
    "rollback_dashboard",
    "get_deployment"
  ]) {
    assert.ok(byName[required], required);
  }
  assert.match(byName.request_pairing.description, /matching code/i);
  assert.match(byName.request_pairing.description, /never self-approves/i);
  assert.match(byName.confirm_pairing.description, /permission_required/);
  assert.match(byName.confirm_pairing.description, /on the device/i);
  assert.match(byName.list_devices.description, /one owner per device/i);
  assert.match(byName.forget_device.description, /does not erase/i);
  assert.equal(byName.forget_device.destructiveHint, true);
  assert.match(byName.deploy_dashboard.description, /previewed revision/i);
  assert.match(byName.deploy_dashboard.description, /approved=true/);
  assert.match(byName.deploy_dashboard.description, /keeps the device's current dashboard/i);
  assert.match(byName.deploy_dashboard.description, /idempotent on deploymentId/i);
  assert.equal(byName.deploy_dashboard.destructiveHint, true);
  assert.equal(byName.rollback_dashboard.destructiveHint, true);
  assert.match(byName.discover_services.description, /not unrestricted subnet scanning/i);
  for (const code of ["device_offline", "not_paired", "permission_required"]) {
    assert.equal(catalog.errors.includes(code), true, code);
  }
  assert.match(help.pairing.body, /one owner/i);
  assert.match(help.pairing.body, /confirm_pairing/);
  assert.match(help.pairing.body, /never self-approves/i);
  assert.match(help.pairing.body, /does not erase/i);
  assert.match(help.deploy.body, /previewed|preview_dashboard/);
  assert.match(help.deploy.body, /keeps its current dashboard/i);
  assert.match(help.deploy.body, /not a runtime proxy/i);
  assert.match(mcpDocs, /request_pairing/);
  assert.match(mcpDocs, /confirm_pairing/);
  assert.match(mcpDocs, /deploy_dashboard/);
  assert.match(mcpDocs, /approved/);
  assert.match(mcpDocs, /one owner/i);
  assert.match(mcpDocs, /not a runtime proxy/i);
  assert.match(mcpDocs, /keeps its\s+current dashboard/i);
});

test("help and docs include the five-second device menu and confirmed Disconnect flow", () => {
  const unlink = help.unlink.body;
  assert.match(unlink, /two fingers/i);
  assert.match(unlink, /five seconds|5 seconds/i);
  assert.match(unlink, /device menu.*Disconnect and confirm/i);
  assert.match(unlink, /Opening the menu does not erase anything/i);
  assert.match(unlink, /Confirming Disconnect erases screens, credentials, and pairing/i);
  assert.match(unlink, /does not erase/i);
  assert.match(help.onboarding.body, /two fingers/i);
  assert.match(help.onboarding.body, /workbench/i);
  assert.match(help.preview.body, /live by default/i);
  assert.match(mcpDocs, /two fingers/);
  assert.match(mcpDocs, /five seconds/);
  assert.match(mcpDocs, /does not erase/);
  assert.match(mcpDocs, /Claude Desktop/);
  assert.match(mcpDocs, /Codex/);
  assert.match(mcpDocs, /Cursor/);
  assert.match(mcpDocs, /does not silently edit/i);
  assert.match(mcpDocs, /stacked/);
  assert.match(mcpDocs, /https:\/\/screenpunk-style-guide\.gsuter\.chatgpt\.site/);
});

test("preview success fixture is image content, never a path-only result", () => {
  const fixture = JSON.parse(readFileSync(join(root, "tests/mcp/fixtures/preview-success.json"), "utf8"));
  assert.equal(fixture.isError, false);
  const image = fixture.content.find((item) => item.type === "image");
  const text = fixture.content.find((item) => item.type === "text");
  assert.ok(image);
  assert.equal(image.mimeType, "image/png");
  assert.equal(image.data.startsWith("iVBOR"), true);
  assert.equal(Boolean(image.path), false);
  assert.equal(fixture.pathOnly, false);
  assert.equal(JSON.parse(text.text).live, true);
  assert.equal(JSON.parse(text.text).pathOnly, false);
});
