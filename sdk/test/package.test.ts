import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  PackageValidationError,
  deploymentDigest,
  loadPackageDirectory,
  resolveLocalAsset,
  validateManifest
} from "../src/package.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

test("offline example package loads and digest matches", () => {
  const loaded = loadPackageDirectory(join(root, "examples/offline-fixture"));
  assert.equal(loaded.manifest.connections.length, 0);
  assert.equal(loaded.manifest.digest, deploymentDigest(loaded.manifest));
  const html = resolveLocalAsset(loaded.assets, "screenpunk://package/index.html");
  assert.match(new TextDecoder().decode(html.bytes), /SCREENPUNK_OFFLINE_EXAMPLE_V1/);
});

test("validator rejects traversal, missing entry, duplicates, and auth-looking blobs", () => {
  const base = JSON.parse(
    JSON.stringify({
      schemaVersion: 1,
      dashboardId: "11111111-1111-4111-8111-111111111111",
      name: "X",
      revision: "22222222-2222-4222-8222-222222222222",
      entrypoint: "index.html",
      sdkVersion: "1",
      target: { profileId: "p", width: 1, height: 1, scale: 1, orientation: "portrait" },
      connections: [],
      files: [{ path: "index.html", bytes: 1, sha256: "a".repeat(64) }]
    })
  );
  assert.throws(
    () => validateManifest({ ...base, schemaVersion: 2 }),
    (err: unknown) => err instanceof PackageValidationError && err.issues.includes("unsupported_version")
  );
  assert.throws(
    () => validateManifest({ ...base, entrypoint: "missing.html" }),
    (err: unknown) => err instanceof PackageValidationError && err.issues.includes("missing_entrypoint")
  );
  assert.throws(
    () =>
      validateManifest({
        ...base,
        files: [
          ...base.files,
          { path: "index.html", bytes: 2, sha256: "b".repeat(64) }
        ]
      }),
    (err: unknown) => err instanceof PackageValidationError && err.issues.includes("duplicate_path")
  );
  assert.throws(
    () => validateManifest({ ...base, name: "token leak" }),
    (err: unknown) => err instanceof PackageValidationError && err.issues.includes("credential_leak")
  );
  assert.throws(() => resolveLocalAsset(new Map(), "https://evil.example/x"));
});
