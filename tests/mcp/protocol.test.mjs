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

test("help and docs include the two-finger ten-second Unlink gesture", () => {
  const unlink = help.unlink.body;
  assert.match(unlink, /two fingers/i);
  assert.match(unlink, /ten seconds|10 seconds/i);
  assert.match(unlink, /Unlink/);
  assert.match(unlink, /Dashboard, credentials, and pairing are erased/i);
  assert.match(unlink, /does not erase/i);
  assert.match(help.onboarding.body, /two fingers/i);
  assert.match(help.onboarding.body, /workbench/i);
  assert.match(help.preview.body, /live by default/i);
  assert.match(mcpDocs, /two fingers/);
  assert.match(mcpDocs, /ten seconds/);
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
