import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readdirSync } from "node:fs";
import { join, posix, relative, sep } from "node:path";
import { EXPANDED_BYTES, MAX_FILES, SCHEMA_MAJOR } from "./limits.js";

export type Orientation = "portrait" | "landscape";

export interface SafeArea {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

export interface ManifestTarget {
  profileId: string;
  width: number;
  height: number;
  scale: number;
  orientation: Orientation;
  safeArea?: SafeArea;
}

export interface ManifestOperation {
  name: string;
  kind: "http" | "ws";
  maxAgeSeconds?: number;
}

export interface ManifestConnection {
  alias: string;
  required: boolean;
  operations?: ManifestOperation[];
}

export interface ManifestFile {
  path: string;
  bytes: number;
  sha256: string;
}

export interface DashboardManifest {
  schemaVersion: number;
  dashboardId: string;
  name: string;
  revision: string;
  entrypoint: string;
  sdkVersion: string;
  digest?: string;
  target: ManifestTarget;
  connections: ManifestConnection[];
  files: ManifestFile[];
}

export type PackageIssueCode =
  | "unsupported_version"
  | "validation_failed"
  | "missing_entrypoint"
  | "duplicate_path"
  | "path_traversal"
  | "size_limit"
  | "hash_mismatch"
  | "symlink_rejected"
  | "credential_leak"
  | "digest_mismatch";

export class PackageValidationError extends Error {
  readonly issues: PackageIssueCode[];
  constructor(issues: PackageIssueCode[], detail?: string) {
    super(detail ?? issues.join(","));
    this.issues = issues;
  }
}

const TRAVERSAL = /(^|\/)\.\.(\/|$)|\\|\0|^\/|^[A-Za-z]:/;
const SECRET_KEYS = /password|secret|token|api[_-]?key|bearer|authorization/i;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REL_FILE = /^(?!\/)(?!.*\.\.)[A-Za-z0-9._/-]+$/;
const REL_HTML = /^(?!\/)(?!.*\.\.)[A-Za-z0-9._/-]+\.html$/;
const SHA256 = /^[a-f0-9]{64}$/;

export function normalizePackagePath(path: string): string {
  const posixPath = path.replaceAll("\\", "/");
  if (TRAVERSAL.test(posixPath) || posixPath.includes("%2e%2e")) {
    throw new PackageValidationError(["path_traversal"], posixPath);
  }
  return posix.normalize(posixPath).replace(/^\.?\//, "");
}

export function sha256Bytes(data: Uint8Array | string): string {
  return createHash("sha256").update(data).digest("hex");
}

export function canonicalManifest(manifest: DashboardManifest): string {
  const copy: DashboardManifest = {
    ...manifest,
    files: [...manifest.files].sort((a, b) => a.path.localeCompare(b.path))
  };
  delete copy.digest;
  return JSON.stringify(copy);
}

export function deploymentDigest(manifest: DashboardManifest): string {
  return sha256Bytes(canonicalManifest(manifest));
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function validateManifest(manifest: unknown): DashboardManifest {
  if (!isObject(manifest)) {
    throw new PackageValidationError(["validation_failed"]);
  }
  if (manifest.schemaVersion !== SCHEMA_MAJOR) {
    throw new PackageValidationError(["unsupported_version"]);
  }
  const typed = manifest as unknown as DashboardManifest;
  if (
    !UUID.test(typed.dashboardId) ||
    !UUID.test(typed.revision) ||
    typed.sdkVersion !== "1" ||
    !typed.name ||
    !REL_HTML.test(typed.entrypoint) ||
    !typed.target ||
    !["portrait", "landscape"].includes(typed.target.orientation) ||
    !Array.isArray(typed.connections) ||
    !Array.isArray(typed.files) ||
    typed.files.length < 1
  ) {
    throw new PackageValidationError(["validation_failed"]);
  }
  for (const file of typed.files) {
    if (!REL_FILE.test(file.path) || !SHA256.test(file.sha256) || file.bytes < 1) {
      throw new PackageValidationError(["validation_failed"], file.path);
    }
  }
  const issues: PackageIssueCode[] = [];
  const seen = new Set<string>();
  let expanded = 0;

  if (SECRET_KEYS.test(JSON.stringify(typed))) {
    issues.push("credential_leak");
  }

  for (const file of typed.files) {
    let normalized: string;
    try {
      normalized = normalizePackagePath(file.path);
    } catch {
      issues.push("path_traversal");
      continue;
    }
    if (seen.has(normalized)) issues.push("duplicate_path");
    seen.add(normalized);
    expanded += file.bytes;
  }

  if (typed.files.length > MAX_FILES || expanded > EXPANDED_BYTES) {
    issues.push("size_limit");
  }

  let entry: string;
  try {
    entry = normalizePackagePath(typed.entrypoint);
  } catch {
    issues.push("path_traversal");
    entry = "";
  }
  if (entry && !seen.has(entry)) issues.push("missing_entrypoint");

  if (typed.digest && typed.digest !== deploymentDigest(typed)) {
    issues.push("digest_mismatch");
  }

  if (issues.length) throw new PackageValidationError([...new Set(issues)]);
  return typed;
}

export interface LoadedAsset {
  path: string;
  bytes: Uint8Array;
  sha256: string;
  mime: string;
}

export function mimeFor(path: string): string {
  if (path.endsWith(".html")) return "text/html; charset=utf-8";
  if (path.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (path.endsWith(".css")) return "text/css; charset=utf-8";
  if (path.endsWith(".json")) return "application/json";
  if (path.endsWith(".svg")) return "image/svg+xml";
  if (path.endsWith(".png")) return "image/png";
  return "application/octet-stream";
}

export function loadPackageDirectory(dir: string): {
  manifest: DashboardManifest;
  assets: Map<string, LoadedAsset>;
} {
  const manifestPath = join(dir, "manifest.json");
  const manifest = validateManifest(JSON.parse(readFileSync(manifestPath, "utf8")));
  const assets = new Map<string, LoadedAsset>();

  for (const file of manifest.files) {
    const normalized = normalizePackagePath(file.path);
    const abs = join(dir, normalized.split("/").join(sep));
    const rel = relative(dir, abs);
    if (rel.startsWith("..") || !existsSync(abs)) {
      throw new PackageValidationError(["missing_entrypoint"], file.path);
    }
    if (lstatSync(abs).isSymbolicLink()) {
      throw new PackageValidationError(["symlink_rejected"], file.path);
    }
    const bytes = new Uint8Array(readFileSync(abs));
    const digest = sha256Bytes(bytes);
    if (bytes.byteLength !== file.bytes || digest !== file.sha256) {
      throw new PackageValidationError(["hash_mismatch"], file.path);
    }
    assets.set(normalized, { path: normalized, bytes, sha256: digest, mime: mimeFor(normalized) });
  }
  return { manifest, assets };
}

export function resolveLocalAsset(
  assets: Map<string, LoadedAsset>,
  url: string
): LoadedAsset {
  const prefix = "screenpunk://package/";
  if (!url.startsWith(prefix)) {
    throw new PackageValidationError(["path_traversal"], url);
  }
  const path = normalizePackagePath(url.slice(prefix.length));
  const asset = assets.get(path);
  if (!asset) throw new PackageValidationError(["missing_entrypoint"], path);
  return asset;
}

export function listFilesRecursive(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listFilesRecursive(path));
    else out.push(path);
  }
  return out;
}
