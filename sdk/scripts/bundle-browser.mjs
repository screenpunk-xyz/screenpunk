#!/usr/bin/env node
/**
 * Compile sdk/src/client.ts to a single IIFE. Authoring-time only; devices
 * load the generated JavaScript. No Node APIs may remain in the output.
 */
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const tsc = join(dirname(require.resolve("typescript/package.json")), "bin/tsc");

const sdkRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = join(sdkRoot, "src/client.ts");
const outDir = join(sdkRoot, "dist");
const outPath = join(outDir, "screenpunk.js");

// TypeScript 7 no longer exposes the old JavaScript transpileModule API.
// Use its compiler CLI for this isolated, type-checked emit.
const stage = mkdtempSync(join(tmpdir(), "screenpunk-browser-"));
let body;
try {
  execFileSync(process.execPath, [tsc, "--ignoreConfig", "--strict", "--skipLibCheck", "--types", "node",
    "--moduleResolution", "Bundler",
    "--target", "ES2020", "--module", "ES2015", "--removeComments",
    "--outDir", stage, sourcePath], { stdio: "pipe" });
  body = readFileSync(join(stage, "client.js"), "utf8")
    .replace(/^export \{\};?\s*/gm, "").replace(/^export /gm, "");
} finally {
  rmSync(stage, { recursive: true, force: true });
}
if (/^\s*import\s/m.test(body) || /\brequire\s*\(/.test(body) || /\bnode:/.test(body) || /\bBuffer\b/.test(body)) {
  throw new Error("browser bundle must be standalone (no imports, require, node:, or Buffer)");
}

const banner = `/* @screenpunk/sdk browser bridge. Schema major 1. No Node on devices. */\n`;
const wrapped = `${banner}"use strict";
(function (global) {
${body}
  var api = {
    createDashboardClient: createDashboardClient,
    createWebKitTransport: createWebKitTransport,
    installScreenpunk: installScreenpunk,
    BridgeClientError: BridgeClientError,
    BRIDGE_TIMEOUT_MS: BRIDGE_TIMEOUT_MS
  };
  var installed = installScreenpunk();
  installed.createDashboardClient = createDashboardClient;
  installed.createWebKitTransport = createWebKitTransport;
  installed.BridgeClientError = BridgeClientError;
  global.screenpunk = installed;
  global.ScreenpunkSDK = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
`;

mkdirSync(outDir, { recursive: true });
writeFileSync(outPath, wrapped);
process.stdout.write(`wrote ${outPath} (${Buffer.byteLength(wrapped)} bytes)\n`);
