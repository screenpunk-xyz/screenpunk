#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

const packages = [
  {
    dir: join(root, "weather"),
    manifest: {
      schemaVersion: 1,
      dashboardId: "55555555-5555-4555-8555-555555555501",
      name: "Weather",
      revision: "66666666-6666-4666-8666-666666666601",
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
          alias: "weather",
          required: true,
          operations: [{ name: "getForecast", kind: "http", maxAgeSeconds: 1815 }]
        }
      ]
    },
    files: [
      "app.js",
      "index.html",
      "mark-inverse.svg",
      "mark.svg",
      "model.js",
      "styles.css",
      "wordmark-inverse.svg",
      "wordmark.svg"
    ]
  },
  {
    dir: join(root, "home-assistant"),
    manifest: {
      schemaVersion: 1,
      dashboardId: "77777777-7777-4777-8777-777777777701",
      name: "Theater",
      revision: "88888888-8888-4888-8888-888888888801",
      entrypoint: "index.html",
      sdkVersion: "1",
      target: {
        profileId: "fixture-phone",
        width: 844,
        height: 390,
        scale: 3,
        orientation: "landscape",
        safeArea: { top: 0, right: 47, bottom: 21, left: 47 }
      },
      connections: [
        {
          alias: "home",
          required: true,
          operations: [
            { name: "getStates", kind: "http", maxAgeSeconds: 45 },
            { name: "lightOn", kind: "http" },
            { name: "lightOff", kind: "http" },
            { name: "sceneOn", kind: "http" },
            { name: "mediaPlayPause", kind: "http" },
            { name: "volumeSet", kind: "http" },
            { name: "selectSource", kind: "http" }
          ]
        },
        {
          alias: "homeEvents",
          required: false,
          operations: [{ name: "subscribeStates", kind: "ws" }]
        }
      ]
    },
    files: [
      "app.js",
      "index.html",
      "mark-inverse.svg",
      "mark.svg",
      "model.js",
      "styles.css",
      "wordmark-inverse.svg",
      "wordmark.svg"
    ]
  }
];

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

for (const pack of packages) {
  const files = pack.files.map((path) => {
    const bytes = readFileSync(join(pack.dir, path));
    return { path, bytes: bytes.byteLength, sha256: sha256(bytes) };
  });
  const manifest = { ...pack.manifest, files };
  const canonical = JSON.stringify({
    ...manifest,
    files: [...files].sort((a, b) => a.path.localeCompare(b.path))
  });
  manifest.digest = sha256(canonical);
  writeFileSync(join(pack.dir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  process.stdout.write(`wrote ${pack.dir}/manifest.json ${manifest.digest}\n`);
}
