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
  cameraEntities?: string[];
  publicHTTP?: PublicReadDeclaration;
  serviceCalls?: { domain: string; service: string; entityIds: string[]; allowUntargeted?: boolean }[];
}

export interface PublicReadParameter { location: "path" | "query"; minimum?: number; maximum?: number; values?: string[] }
export interface PublicReadDeclaration {
  origin: string;
  userAgent: string;
  operations: { name: string; path: string; response: "json" | "raster"; parameters: Record<string, PublicReadParameter>; maxAgeSeconds: number; staleSeconds: number }[];
}

export function validatePublicRead(connection: ManifestConnection): void {
  const d = connection.publicHTTP;
  if (!d) return;
  const fail = (): never => { throw new PackageValidationError(["validation_failed"]); };
  const component = (s: string) => typeof s === "string" && s.length <= 128 && /^[a-zA-Z0-9_.-]+$/.test(s) && s !== "." && s !== "..";
  if (connection.alias === "home" || !/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/.test(connection.alias) || connection.operations !== undefined || connection.serviceCalls !== undefined || connection.cameraEntities !== undefined) fail();
  if (!/^https:\/\/[a-z0-9]+(?:[.-][a-z0-9]+)*(?::443)?$/.test(d.origin)) fail();
  const host = new URL(d.origin).hostname;
  if (host === "localhost" || host.endsWith(".localhost") || host === "metadata.google.internal" || host.endsWith(".metadata.google.internal")) fail();
  if (/^[0-9.]+$/.test(host)) {
    const b = host.split('.').map(Number);
    if (b.length !== 4 || b.some(n => !Number.isInteger(n) || n < 0 || n > 255) || b[0] === 0 || b[0] === 10 || b[0] === 127 || b[0] >= 224 ||
      (b[0] === 169 && b[1] === 254) || (b[0] === 192 && b[1] === 168) || (b[0] === 172 && b[1] >= 16 && b[1] <= 31) || (b[0] === 100 && b[1] >= 64 && b[1] <= 127)) fail();
  }
  if (typeof d.userAgent !== "string" || !/^[\x20-\x7e]{1,256}$/.test(d.userAgent) || !Array.isArray(d.operations) || !d.operations.length || d.operations.length > 16 || new Set(d.operations.map(o => o.name)).size !== d.operations.length) fail();
  for (const op of d.operations) {
    if (!component(op.name) || !["json", "raster"].includes(op.response) || !Number.isInteger(op.maxAgeSeconds) || op.maxAgeSeconds < 1 || op.maxAgeSeconds > 86400 || !Number.isInteger(op.staleSeconds) || op.staleSeconds < 0 || op.staleSeconds > 604800 || typeof op.path !== "string" || op.path.length > 512 || !op.parameters || Object.keys(op.parameters).length > 12) fail();
    let path = op.path;
    for (const [key, rule] of Object.entries(op.parameters)) {
      if (!component(key) || /^(authorization|x-api-key|token|password|access_token|api_key|apikey|secret|path|url|host|origin|method|headers|scheme|port)$/i.test(key) || !["path", "query"].includes(rule.location) || (rule.location === "path") !== path.includes(`{${key}}`)) fail();
      let value: string;
      if (rule.values !== undefined) {
        if (!Array.isArray(rule.values) || !rule.values.length || rule.values.length > 64 || rule.minimum !== undefined || rule.maximum !== undefined || new Set(rule.values).size !== rule.values.length || !rule.values.every(v => typeof v === "string" && /^[\x20-\x7e]{1,256}$/.test(v) && (rule.location === "query" || (/^[a-zA-Z0-9_.,-]+$/.test(v) && v !== "." && v !== "..")))) fail();
        value = rule.values[0];
      } else {
        if (!Number.isSafeInteger(rule.minimum) || !Number.isSafeInteger(rule.maximum) || rule.minimum! > rule.maximum!) fail();
        value = String(rule.minimum);
      }
      if (rule.location === "path") path = path.replaceAll(`{${key}}`, value);
    }
    if (!path.startsWith("/") || !path.slice(1).split("/").every(v => /^[a-zA-Z0-9_.,-]{1,256}$/.test(v) && v !== "." && v !== "..")) fail();
  }
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
  const aliases = new Set<string>();
  for (const connection of typed.connections) {
    if (aliases.has(connection.alias)) throw new PackageValidationError(["validation_failed"]);
    aliases.add(connection.alias);
    validatePublicRead(connection);
    if (connection.cameraEntities !== undefined) {
      const ids = connection.cameraEntities;
      if (connection.alias !== "home" || !Array.isArray(ids) || ids.length > 16 || new Set(ids).size !== ids.length ||
          ids.some(id => typeof id !== "string" || id.length > 255 || !/^camera\.[a-z0-9_]+$/.test(id)))
        throw new PackageValidationError(["validation_failed"]);
    }
    if (connection.serviceCalls === undefined) continue;
    if (connection.alias !== "home" || !Array.isArray(connection.serviceCalls) || connection.serviceCalls.length > 128)
      throw new PackageValidationError(["validation_failed"]);
    const services = new Set<string>();
    for (const grant of connection.serviceCalls) {
      const name = `${grant.domain}.${grant.service}`;
      if (![grant.domain, grant.service].every(x => typeof x === "string" && /^[a-z0-9_]{1,128}$/.test(x) && !/\s/.test(x)) ||
          services.has(name) || !Array.isArray(grant.entityIds) || grant.entityIds.length > 128 ||
          !grant.entityIds.every(x => typeof x === "string" && x.length <= 255 && /^[a-z0-9_]{1,128}\.[a-z0-9_]{1,128}$/.test(x) && !/\s/.test(x)) ||
          new Set(grant.entityIds).size !== grant.entityIds.length ||
          (grant.allowUntargeted !== undefined && typeof grant.allowUntargeted !== "boolean") ||
          (!grant.entityIds.length && grant.allowUntargeted !== true))
        throw new PackageValidationError(["validation_failed"]);
      services.add(name);
    }
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
