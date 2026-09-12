#!/usr/bin/env node
/**
 * Compile sdk/src/client.ts to a single IIFE. Authoring-time only; devices
 * load the generated JavaScript. No Node APIs may remain in the output.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const ts = require("typescript");

const sdkRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = join(sdkRoot, "src/client.ts");
const outDir = join(sdkRoot, "dist");
const outPath = join(outDir, "screenpunk.js");

const source = readFileSync(sourcePath, "utf8");
const transpiled = ts.transpileModule(source, {
  compilerOptions: {
    target: ts.ScriptTarget.ES2020,
    module: ts.ModuleKind.ES2015,
    strict: true,
    removeComments: true
  },
  reportDiagnostics: true,
  fileName: "client.ts"
});

if (transpiled.diagnostics?.length) {
  const host = {
    getCanonicalFileName: (file) => file,
    getCurrentDirectory: () => sdkRoot,
    getNewLine: () => "\n"
  };
  throw new Error(ts.formatDiagnostics(transpiled.diagnostics, host));
}

let body = transpiled.outputText.replace(/^export \{\};?\s*/gm, "").replace(/^export /gm, "");
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
