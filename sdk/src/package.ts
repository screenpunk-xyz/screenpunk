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

export interface DashboardPage { id: string; name: string; path: string }
export type EventReturnBehavior = "stay" | "timeout" | "conditionClear";
export type EventScalar = string | number | boolean | null;
export interface EventCondition { field: string[]; equals: EventScalar }
export interface EventPayloadFields {
  pageId?: string[]; returnBehavior?: string[]; timeoutSeconds?: string[];
  eventId?: string[]; correlationId?: string[]; occurredAt?: string[];
}
export interface EventRuleDefaults {
  enabled: boolean; pageId: string; returnBehavior: EventReturnBehavior;
  timeoutSeconds: number; allowPayloadOverrides: boolean;
}
export interface EventSource {
  mode: "live" | "poll"; alias: string; operation: string;
  parameters: Record<string, EventScalar>; pollIntervalSeconds?: number; refreshOperation?: string; refreshAlias?: string;
}
export interface ManifestEventRule {
  id: string; name: string; source: EventSource; filter?: EventCondition; condition?: EventCondition;
  defaults: EventRuleDefaults; priority: number; userConfigurable: boolean;
  allowedPageIds: string[]; allowedReturnBehaviors: EventReturnBehavior[];
  allowTimeoutOverride: boolean; payload?: EventPayloadFields;
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
  pages?: DashboardPage[];
  defaultPageId?: string;
  eventRules?: ManifestEventRule[];
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

  try { validateNavigation(typed); } catch { issues.push("validation_failed"); }

  if (typed.digest && typed.digest !== deploymentDigest(typed)) {
    issues.push("digest_mismatch");
  }

  if (issues.length) throw new PackageValidationError([...new Set(issues)]);
  return typed;
}

/** Mirrors native EventNavigationEngine validation; payloads never introduce capabilities. */
export function validateNavigation(manifest: DashboardManifest): void {
  const invalid = () => { throw new PackageValidationError(["validation_failed"]); };
  if (manifest.pages === undefined && manifest.defaultPageId === undefined && manifest.eventRules === undefined) return;
  const pages = manifest.pages ?? [{ id: "default", name: manifest.name, path: manifest.entrypoint }];
  const id = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(v);
  const field = (v: unknown): boolean => Array.isArray(v) && v.length > 0 && v.length <= 16 && v.every(k => typeof k === "string" && k.length > 0 && k.length <= 128 && !["__proto__", "prototype", "constructor"].includes(k));
  const scalar = (v: unknown): boolean => v === null || typeof v === "string" || typeof v === "boolean" || (typeof v === "number" && Number.isFinite(v));
  const condition = (v: unknown): boolean => isObject(v) && field(v.field) && scalar(v.equals);
  const behaviors = ["stay", "timeout", "conditionClear"];
  if (!Array.isArray(pages) || !pages.length || pages.length > 64) invalid();
  const ids = new Set(pages.map(p => p.id));
  if (ids.size !== pages.length || !ids.has(manifest.defaultPageId ?? pages[0].id)) invalid();
  for (const p of pages) if (!id(p.id) || !p.name || p.name.length > 128 || !REL_HTML.test(p.path) || !manifest.files.some(f => f.path === p.path)) invalid();
  const rules = manifest.eventRules ?? [];
  if (!Array.isArray(rules) || rules.length > 64 || new Set(rules.map(r => r.id)).size !== rules.length) invalid();
  for (const r of rules) {
    const d = r.defaults; const source = r.source;
    if (!id(r.id) || !r.name || r.name.length > 128 || !Number.isInteger(r.priority) || r.priority < -100 || r.priority > 100 ||
        !d || !ids.has(d.pageId) || typeof d.enabled !== "boolean" || typeof d.allowPayloadOverrides !== "boolean" ||
        !behaviors.includes(d.returnBehavior) || !Number.isInteger(d.timeoutSeconds) || d.timeoutSeconds < 1 || d.timeoutSeconds > 3600 ||
        typeof r.userConfigurable !== "boolean" || typeof r.allowTimeoutOverride !== "boolean" ||
        !Array.isArray(r.allowedPageIds) || r.allowedPageIds.some(p => !ids.has(p)) || new Set(r.allowedPageIds).size !== r.allowedPageIds.length ||
        !Array.isArray(r.allowedReturnBehaviors) || r.allowedReturnBehaviors.some(b => !behaviors.includes(b)) || new Set(r.allowedReturnBehaviors).size !== r.allowedReturnBehaviors.length ||
        (r.condition !== undefined && !condition(r.condition)) || (r.filter !== undefined && !condition(r.filter)) ||
        ((d.returnBehavior === "conditionClear" || r.allowedReturnBehaviors.includes("conditionClear")) && !r.condition) ||
        !source || !["live", "poll"].includes(source.mode) || !isObject(source.parameters) || Object.keys(source.parameters).length > 32 ||
        Object.entries(source.parameters).some(([k, v]) => !k.length || k.length > 128 || ["authorization", "x-api-key", "token", "password"].includes(k.toLowerCase()) || !scalar(v))) invalid();
    const connection = manifest.connections.find(c => c.alias === source.alias);
    if (!connection?.operations?.some(o => o.name === source.operation && o.kind === (source.mode === "live" ? "ws" : "http"))) invalid();
    if (source.refreshOperation !== undefined && !manifest.connections.find(c => c.alias === (source.refreshAlias ?? source.alias))?.operations?.some(o => o.name === source.refreshOperation && o.kind === "http")) invalid();
    if (source.mode === "poll" && (!r.condition || !Number.isInteger(source.pollIntervalSeconds ?? 30) || (source.pollIntervalSeconds ?? 30) < 15 || (source.pollIntervalSeconds ?? 30) > 86400)) invalid();
    if (!r.condition && !r.payload?.occurredAt) invalid();
    if (r.payload !== undefined && (!isObject(r.payload) || Object.values(r.payload).some(v => !field(v)))) invalid();
  }
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
