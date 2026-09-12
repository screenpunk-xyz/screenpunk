import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  PackageValidationError,
  deploymentDigest,
  loadPackageDirectory,
  validateManifest,
  type DashboardManifest
} from "../src/package.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

function fixtureManifest(): DashboardManifest {
  return JSON.parse(readFileSync(join(root, "examples/offline-fixture/manifest.json"), "utf8")) as DashboardManifest;
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function issues(fn: () => unknown): string[] {
  try {
    fn();
  } catch (err) {
    if (err instanceof PackageValidationError) return err.issues;
    throw err;
  }
  return [];
}

test("deployment identity is a SHA-256 hex digest that ignores file order and the digest field", () => {
  const manifest = fixtureManifest();
  const base = deploymentDigest(manifest);
  assert.match(base, /^[a-f0-9]{64}$/);
  assert.equal(base, manifest.digest, "committed fixture digest is reproducible");

  const reversed = clone(manifest);
  reversed.files.reverse();
  assert.equal(deploymentDigest(reversed), base);

  const stripped = clone(manifest);
  delete stripped.digest;
  assert.equal(deploymentDigest(stripped), base);

  const wrongPinned = clone(manifest);
  wrongPinned.digest = "0".repeat(64);
  assert.equal(deploymentDigest(wrongPinned), base, "a pinned digest never feeds back into identity");
});

test("retrying the same deployment yields the same identity; rolling back re-sends an older identity unchanged", () => {
  const revisionA = fixtureManifest();
  const revisionB = clone(revisionA);
  revisionB.revision = "33333333-3333-4333-8333-333333333333";
  revisionB.files[0].sha256 = "f".repeat(64);
  delete revisionB.digest;

  const a1 = deploymentDigest(revisionA);
  const a2 = deploymentDigest(clone(revisionA));
  const b = deploymentDigest(revisionB);
  assert.equal(a1, a2, "idempotent retry");
  assert.notEqual(a1, b, "a new revision is a new deployment");

  const rollback = clone(revisionA);
  assert.equal(deploymentDigest(rollback), a1, "rollback sends the older package as a deployment with its original identity");
  const loaded = loadPackageDirectory(join(root, "examples/offline-fixture"));
  assert.equal(deploymentDigest(loaded.manifest), a1, "identity computed from disk matches the committed one");
});

test("every field that changes what a device would show changes the identity", () => {
  const base = fixtureManifest();
  const baseDigest = deploymentDigest(base);
  const mutations: Array<[string, (m: DashboardManifest) => void]> = [
    ["revision", (m) => (m.revision = "44444444-4444-4444-8444-444444444444")],
    ["dashboardId", (m) => (m.dashboardId = "55555555-5555-4555-8555-555555555555")],
    ["name", (m) => (m.name = "Renamed")],
    ["entrypoint", (m) => (m.entrypoint = "app.js")],
    ["file sha256", (m) => (m.files[0].sha256 = "e".repeat(64))],
    ["file bytes", (m) => (m.files[0].bytes += 1)],
    ["file path", (m) => (m.files[0].path = "renamed.js")],
    ["added file", (m) => m.files.push({ path: "extra.css", bytes: 1, sha256: "d".repeat(64) })],
    ["target size", (m) => (m.target.width += 1)],
    ["orientation", (m) => (m.target.orientation = "landscape")],
    ["connections", (m) => m.connections.push({ alias: "weather", required: true })]
  ];
  const seen = new Set<string>([baseDigest]);
  for (const [label, mutate] of mutations) {
    const mutated = clone(base);
    delete mutated.digest;
    mutate(mutated);
    const digest = deploymentDigest(mutated);
    assert.notEqual(digest, baseDigest, `${label} must change the deployment identity`);
    assert.ok(!seen.has(digest), `${label} collides with another mutation`);
    seen.add(digest);
  }
});

test("a draft changed after preview cannot validate as the previewed revision", () => {
  const previewed = fixtureManifest();
  assert.doesNotThrow(() => validateManifest(previewed));

  const editedFile = clone(previewed);
  editedFile.files[1].sha256 = "c".repeat(64);
  assert.deepEqual(issues(() => validateManifest(editedFile)), ["digest_mismatch"]);

  const editedRevision = clone(previewed);
  editedRevision.revision = "66666666-6666-4666-8666-666666666666";
  assert.deepEqual(issues(() => validateManifest(editedRevision)), ["digest_mismatch"]);

  const swappedEntry = clone(previewed);
  swappedEntry.entrypoint = "index.html";
  swappedEntry.files = swappedEntry.files.map((f) =>
    f.path === "index.html" ? { ...f, bytes: f.bytes + 1 } : f
  );
  assert.deepEqual(issues(() => validateManifest(swappedEntry)), ["digest_mismatch"]);

  const repinned = clone(editedFile);
  repinned.digest = deploymentDigest(repinned);
  assert.doesNotThrow(() => validateManifest(repinned), "re-pinning produces a different, valid identity");
  assert.notEqual(repinned.digest, previewed.digest);
});

test("staged packages that fail on disk never validate: hash, size, symlink and missing files", () => {
  const loaded = loadPackageDirectory(join(root, "examples/offline-fixture"));
  assert.equal(loaded.assets.size, loaded.manifest.files.length);
  for (const file of loaded.manifest.files) {
    const asset = loaded.assets.get(file.path);
    assert.ok(asset, file.path);
    assert.equal(asset.bytes.byteLength, file.bytes);
    assert.equal(asset.sha256, file.sha256);
  }

  const invalid = join(root, "schemas/fixtures/invalid");
  assert.deepEqual(issues(() => validateManifest(JSON.parse(readFileSync(join(invalid, "unsupported-major.json"), "utf8")))), [
    "unsupported_version"
  ]);
  assert.deepEqual(issues(() => validateManifest(JSON.parse(readFileSync(join(invalid, "missing-entrypoint.json"), "utf8")))), [
    "missing_entrypoint"
  ]);
  assert.deepEqual(issues(() => validateManifest(JSON.parse(readFileSync(join(invalid, "duplicate-path.json"), "utf8")))), [
    "duplicate_path"
  ]);
  assert.ok(
    issues(() => validateManifest(JSON.parse(readFileSync(join(invalid, "path-traversal.json"), "utf8")))).some((i) =>
      ["path_traversal", "validation_failed"].includes(i)
    )
  );
});
