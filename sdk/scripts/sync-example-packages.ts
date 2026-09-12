/**
 * Copy the browser bundle and stacked lockup assets into example packages,
 * then write manifests with matching SHA-256 inventories.
 */
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { deploymentDigest, sha256Bytes, validateManifest, type DashboardManifest } from "../src/package.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const brand = join(root, "assets/brand");
const bundle = join(root, "sdk/dist/screenpunk.js");

const copies = [
  ["logomark/svg/screenpunk-mark-dark-on-light.svg", "mark-light.svg"],
  ["logomark/svg/screenpunk-mark-light-on-dark.svg", "mark-dark.svg"],
  ["wordmark/png/screenpunk-wordmark-dark-on-light-256.png", "wordmark-light.png"],
  ["wordmark/png/screenpunk-wordmark-light-on-dark-256.png", "wordmark-dark.png"]
] as const;

const inventory = [
  "app.js",
  "index.html",
  "mark-dark.svg",
  "mark-light.svg",
  "screenpunk.js",
  "styles.css",
  "wordmark-dark.png",
  "wordmark-light.png"
];

const examples: Array<{ dir: string; manifest: Omit<DashboardManifest, "files" | "digest"> }> = [
  {
    dir: "examples/http-status",
    manifest: {
      schemaVersion: 1,
      dashboardId: "44444444-4444-4444-8444-444444444444",
      name: "HTTP status",
      revision: "44444444-4444-4444-9444-444444444445",
      entrypoint: "index.html",
      sdkVersion: "1",
      target: {
        profileId: "fixture-phone",
        width: 390,
        height: 844,
        scale: 3,
        orientation: "portrait",
        safeArea: { top: 47, right: 0, bottom: 34, left: 0 }
      },
      connections: [
        {
          alias: "status",
          required: true,
          operations: [{ name: "getStatus", kind: "http", maxAgeSeconds: 45 }]
        }
      ]
    }
  },
  {
    dir: "examples/ws-ticker",
    manifest: {
      schemaVersion: 1,
      dashboardId: "55555555-5555-4555-8555-555555555555",
      name: "WS ticker",
      revision: "55555555-5555-4555-9555-555555555556",
      entrypoint: "index.html",
      sdkVersion: "1",
      target: {
        profileId: "fixture-phone",
        width: 390,
        height: 844,
        scale: 3,
        orientation: "portrait",
        safeArea: { top: 47, right: 0, bottom: 34, left: 0 }
      },
      connections: [
        {
          alias: "ticker",
          required: true,
          operations: [{ name: "ticks", kind: "ws" }]
        }
      ]
    }
  }
];

for (const example of examples) {
  const dir = join(root, example.dir);
  mkdirSync(dir, { recursive: true });
  cpSync(bundle, join(dir, "screenpunk.js"));
  for (const [from, to] of copies) {
    cpSync(join(brand, from), join(dir, to));
  }
  const files = inventory.map((path) => {
    const bytes = new Uint8Array(readFileSync(join(dir, path)));
    return { path, bytes: bytes.byteLength, sha256: sha256Bytes(bytes) };
  });
  const manifest: DashboardManifest = {
    ...example.manifest,
    files
  };
  manifest.digest = deploymentDigest(manifest);
  validateManifest(manifest);
  writeFileSync(join(dir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  process.stdout.write(`synced ${example.dir} ${manifest.digest}\n`);
}
