#!/usr/bin/env node
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const brandRoot = join(root, "assets/brand");

const required = [
  "PROVENANCE.md",
  "style/tokens.json",
  "logomark/svg/screenpunk-mark-dark-transparent.svg",
  "logomark/svg/screenpunk-mark-light-transparent.svg",
  "logomark/svg/screenpunk-mark-dark-on-light.svg",
  "logomark/svg/screenpunk-mark-light-on-dark.svg",
  "logomark/palette.json",
  "wordmark/svg/screenpunk-wordmark-dark-transparent.svg",
  "wordmark/svg/screenpunk-wordmark-light-transparent.svg",
  "wordmark/svg/screenpunk-wordmark-dark-on-light.svg",
  "wordmark/svg/screenpunk-wordmark-light-on-dark.svg",
  "wordmark/palette.json",
  "lockups/screenpunk-lockup-v1-stacked-light.svg",
  "lockups/screenpunk-lockup-v1-stacked-dark.svg",
  "lockups/APPROVED-V1.md"
];

const forbidden = /v2|upright|avatar|modular-display-v(?!1\b)|startup-03/i;

function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path, out);
    else out.push(path);
  }
  return out;
}

const missing = required.filter((rel) => !existsSync(join(brandRoot, rel)));
if (missing.length) {
  console.error("missing brand files:\n" + missing.join("\n"));
  process.exit(1);
}

const forbiddenHits = walk(brandRoot)
  .map((p) => relative(brandRoot, p))
  .filter((rel) => forbidden.test(rel));
if (forbiddenHits.length) {
  console.error("under-review or unselected brand paths:\n" + forbiddenHits.join("\n"));
  process.exit(1);
}

const tokens = JSON.parse(readFileSync(join(brandRoot, "style/tokens.json"), "utf8"));
if (tokens.semanticTokens.light.danger !== "#A52C42" || tokens.semanticTokens.dark.danger !== "#FF8BA0") {
  console.error("danger tokens do not match Style-Guide");
  process.exit(1);
}
if (tokens.defaultLockup !== "stacked") {
  console.error("default lockup must be stacked");
  process.exit(1);
}
if (tokens.appleControls.ios27RequiredToRun !== false) {
  console.error("iOS 27 must not be required to run");
  process.exit(1);
}
if (tokens.publicGuideURL !== "https://screenpunk-style-guide.gsuter.chatgpt.site") {
  console.error("public guide URL missing from tokens provenance");
  process.exit(1);
}

const provenance = readFileSync(join(brandRoot, "PROVENANCE.md"), "utf8");
if (!provenance.includes("https://screenpunk-style-guide.gsuter.chatgpt.site")) {
  console.error("PROVENANCE.md missing public Codex URL");
  process.exit(1);
}

console.log(`brand provenance ok (${walk(brandRoot).length} files)`);
