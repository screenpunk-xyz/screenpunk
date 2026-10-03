import { createHash } from "node:crypto";
import type { DashboardManifest, ManifestConnection } from "./package.js";
import {
  checkNativeExpandedBytes,
  copyData,
  integerField,
  projectNativeManifest,
} from "./native-package-domain.js";
import { compareNativePaths, fail, nativeJSON } from "./native-package-json.js";
export { NativePackageError } from "./native-package-json.js";

const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const storageGetters = ["buffer", "byteOffset", "byteLength"].map(
  (key) => Object.getOwnPropertyDescriptor(typedArrayPrototype, key)!.get!,
);
const rawSet = Uint8Array.prototype.set;
function rawByteView(data: Uint8Array, path: string): Uint8Array {
  try {
    const buffer = Reflect.apply(storageGetters[0], data, []) as ArrayBuffer;
    const offset = Reflect.apply(storageGetters[1], data, []) as number;
    const length = Reflect.apply(storageGetters[2], data, []) as number;
    if (buffer instanceof SharedArrayBuffer)
      fail(
        "representation",
        path,
        "shared mutable byte storage cannot be snapshotted reproducibly",
      );
    return new Uint8Array(buffer, offset, length);
  } catch (error) {
    if (error instanceof Error && error.name === "NativePackageError")
      throw error;
    return fail(
      "representation",
      path,
      "expected intrinsic typed-array byte storage",
    );
  }
}
function copyBytes(view: Uint8Array): Uint8Array {
  const output = new Uint8Array(Reflect.apply(storageGetters[2], view, []));
  Reflect.apply(rawSet, output, [view]);
  return output;
}

/** Additive codec identity; deliberately outside the wire manifest and digest. */
export const NATIVE_PACKAGE_PROFILE = "screenpunk-native-manifest-v1" as const;

/** Null is allowed only for optional Codable properties, or an EventScalar. */
export type NativeCodableInput<T> = T extends readonly (infer U)[]
  ? readonly NativeCodableInput<U>[]
  : T extends object
    ? {
        [K in keyof T]: undefined extends T[K]
          ? NativeCodableInput<Exclude<T[K], undefined>> | null
          : NativeCodableInput<T[K]>;
      }
    : T;
export type NativePackageMetadata = NativeCodableInput<
  Omit<DashboardManifest, "files" | "digest">
>;
export type NativeReadonly<T> = T extends readonly (infer U)[]
  ? readonly NativeReadonly<U>[]
  : T extends object
    ? { readonly [K in keyof T]: NativeReadonly<T[K]> }
    : T;
export interface NativePackageAsset {
  readonly path: string;
  readonly data: Uint8Array;
}
export interface NativePackage {
  readonly profile: typeof NATIVE_PACKAGE_PROFILE;
  readonly manifest: NativeReadonly<DashboardManifest>;
  readonly digest: string;
  readonly canonicalJSON: string;
  readonly manifestJSON: string;
  /** Assets plus the UTF-8 persisted manifest, not a compressed archive size. */
  readonly expandedBytes: number;
  /** Every data read returns a fresh copy; the internal byte snapshot is never exposed. */
  readonly assets: readonly NativePackageAsset[];
}

function unique(values: string[], path: string): void {
  if (new Set(values.map((v) => v.normalize("NFC"))).size !== values.length)
    fail("duplicate", path, "duplicate native String identity");
}
function pathIdentity(path: string, field: string): void {
  // Native PackagePath preserves raw segments. Reject aliases that a ZIP/URL layer
  // could normalize differently; do not rewrite the path inside a digest.
  if (
    !/^[A-Za-z0-9._/-]+$/.test(path) ||
    /[\r\n]/.test(path) ||
    path.split("/").some((s) => s === "" || s === ".")
  )
    fail(
      "path_identity",
      field,
      "path must have exact schema ASCII spelling without empty, dot, or control segments",
    );
}
function publicRead(connection: ManifestConnection, index: number): void {
  const d = connection.publicHTTP;
  if (!d) return;
  const field = `$manifest.connections[${index}].publicHTTP`;
  const bad = (detail: string): never =>
    fail("native_validation", field, detail);
  const component = (s: string) =>
    /^[A-Za-z0-9_.-]{1,128}$/.test(s) && s !== "." && s !== "..";
  const pathPart = (s: string) =>
    /^[A-Za-z0-9_.,~-]{1,256}$/.test(s) && s !== "." && s !== "..";
  if (
    connection.alias === "home" ||
    connection.operations !== undefined ||
    connection.serviceCalls !== undefined ||
    connection.cameraEntities !== undefined
  )
    bad(
      "public HTTP declaration conflicts with native connection capabilities",
    );
  const host = d.origin.replace(/^https:\/\//, "").replace(/:443$/, "");
  if (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host === "metadata.google.internal" ||
    host.endsWith(".metadata.google.internal")
  )
    bad("native public HTTP origin is not public unicast");
  if (/^[0-9.]+$/.test(host)) {
    const b = host.split(".").map(Number);
    if (
      b.length !== 4 ||
      b.some((n) => n > 255) ||
      b[0] === 0 ||
      b[0] === 10 ||
      b[0] === 127 ||
      b[0] >= 224 ||
      (b[0] === 169 && b[1] === 254) ||
      (b[0] === 192 && b[1] === 168) ||
      (b[0] === 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] === 100 && b[1] >= 64 && b[1] <= 127)
    )
      bad("native public HTTP origin is not public unicast");
  }
  unique(
    d.operations.map((o) => o.name),
    field + ".operations",
  );
  for (const op of d.operations) {
    if (!component(op.name)) bad("invalid public operation name");
    if (
      Object.values(op.parameters).some((p) => p.pathSegment !== undefined) &&
      (op.response !== "raster" ||
        !pathPart(op.path.split("/")[1] ?? "") ||
        op.path.split("/").length < 3)
    )
      bad("dynamic paths require a raster response and literal directory");
    let path = op.path;
    for (const [key, parameter] of Object.entries(op.parameters)) {
      if (
        !component(key) ||
        /^(authorization|x-api-key|token|password|access_token|api_key|apikey|secret|path|url|host|origin|method|headers|scheme|port)$/i.test(
          key,
        ) ||
        (parameter.location === "path") !== path.includes(`{${key}}`)
      )
        bad("invalid parameter name, destination override, or path binding");
      if (
        parameter.minimum !== undefined &&
        parameter.minimum > parameter.maximum!
      )
        bad("minimum exceeds maximum");
      if (
        parameter.values &&
        parameter.location === "path" &&
        !parameter.values.every(pathPart)
      )
        bad("path enum contains an invalid path component");
      const sample = parameter.pathSegment
        ? "x"
        : (parameter.values?.[0] ?? String(parameter.minimum));
      if (parameter.location === "path")
        path = path.replaceAll(`{${key}}`, sample);
    }
    if (
      Buffer.byteLength(path) > 512 ||
      !path.startsWith("/") ||
      !path.slice(1).split("/").every(pathPart)
    )
      bad("resolved sample is not a bounded native public path");
  }
}

function nativeSemantics(m: DashboardManifest): void {
  unique(
    m.connections.map((c) => c.alias),
    "$manifest.connections",
  );
  if (m.connections.filter((c) => c.publicHTTP !== undefined).length > 8)
    fail(
      "native_validation",
      "$manifest.connections",
      "native provisioning permits at most eight public HTTP connections",
    );
  m.connections.forEach((c, index) => {
    const field = `$manifest.connections[${index}]`;
    if (
      (c.serviceCalls !== undefined || c.cameraEntities !== undefined) &&
      c.alias !== "home"
    )
      fail(
        "native_validation",
        field,
        "Home Assistant capabilities require alias home",
      );
    unique(
      (c.serviceCalls ?? []).map((g) => g.domain + "." + g.service),
      field + ".serviceCalls",
    );
    for (const g of c.serviceCalls ?? []) {
      if (
        (!g.entityIds.length && g.allowUntargeted !== true) ||
        g.entityIds.some((id) =>
          id.split(".").some((part) => part.length > 128),
        )
      )
        fail(
          "native_validation",
          field + ".serviceCalls",
          "invalid native service grant",
        );
    }
    publicRead(c, index);
  });
  if (
    /password|secret|token|api[_-]?key|bearer/.test(
      m.dashboardId + m.name + m.entrypoint,
    )
  )
    fail(
      "credential_leak",
      "$manifest",
      "native metadata credential heuristic rejected the package",
    );
  unique(
    m.files.map((f) => f.path),
    "$manifest.files",
  );
  let size = 0;
  for (const [index, f] of m.files.entries()) {
    pathIdentity(f.path, `$manifest.files[${index}].path`);
    if (f.bytes > 50 * 1024 * 1024 - size)
      fail("size_limit", "$manifest.files", "expanded package exceeds 50 MiB");
    size += f.bytes;
  }
  pathIdentity(m.entrypoint, "$manifest.entrypoint");
  if (!m.files.some((f) => f.path === m.entrypoint))
    fail(
      "missing_entrypoint",
      "$manifest.entrypoint",
      "entrypoint is absent from the computed inventory",
    );
  const activation = m.deviceBehavior?.temporaryActivation;
  if (activation) {
    const states = [activation.activeState, activation.inactiveState];
    if (
      states.some(
        (s) => Buffer.byteLength(s) > 128 || /[\p{Cc}\p{Cf}]/u.test(s),
      ) ||
      states[0].normalize("NFC") === states[1].normalize("NFC")
    )
      fail(
        "native_validation",
        "$manifest.deviceBehavior.temporaryActivation",
        "native states must differ and contain bounded non-control UTF-8",
      );
    unique(
      [
        activation.idAttribute,
        activation.startedAtAttribute,
        activation.expiresAtAttribute,
      ],
      "$manifest.deviceBehavior.temporaryActivation",
    );
  }
  const pages = m.pages ?? [
    { id: "default", name: m.name, path: m.entrypoint },
  ];
  unique(
    pages.map((p) => p.id),
    "$manifest.pages",
  );
  const pageIds = new Set(pages.map((p) => p.id));
  if (!pageIds.has(m.defaultPageId ?? pages[0].id))
    fail(
      "native_validation",
      "$manifest.defaultPageId",
      "unknown default page",
    );
  for (const p of pages) {
    pathIdentity(p.path, "$manifest.pages.path");
    if (!m.files.some((f) => f.path === p.path))
      fail(
        "native_validation",
        "$manifest.pages",
        "page is absent from the inventory",
      );
  }
  unique(
    (m.eventRules ?? []).map((r) => r.id),
    "$manifest.eventRules",
  );
  for (const [index, r] of (m.eventRules ?? []).entries()) {
    const field = `$manifest.eventRules[${index}]`;
    const bad = (detail: string): never =>
      fail("native_validation", field, detail);
    if (
      !pageIds.has(r.defaults.pageId) ||
      r.allowedPageIds.some((id) => !pageIds.has(id))
    )
      bad("event rule refers to an unknown page");
    if (
      (r.defaults.returnBehavior === "conditionClear" ||
        r.allowedReturnBehaviors.includes("conditionClear")) &&
      !r.condition
    )
      bad("conditionClear requires a condition");
    if (
      Object.keys(r.source.parameters).some(
        (k) =>
          !k.length ||
          Array.from(k).length > 128 ||
          ["authorization", "x-api-key", "token", "password"].includes(
            k.toLowerCase(),
          ),
      )
    )
      bad("invalid native event parameter key");
    const connection = m.connections.find((c) => c.alias === r.source.alias);
    if (
      !connection?.operations?.some(
        (o) =>
          o.name === r.source.operation &&
          o.kind === (r.source.mode === "live" ? "ws" : "http"),
      )
    )
      bad("event source operation is not declared");
    if (
      r.source.refreshOperation !== undefined &&
      !m.connections
        .find((c) => c.alias === (r.source.refreshAlias ?? r.source.alias))
        ?.operations?.some(
          (o) => o.name === r.source.refreshOperation && o.kind === "http",
        )
    )
      bad("refresh operation is not declared");
    if (r.source.mode === "poll" && !r.condition)
      bad("polling requires a condition");
    if (!r.condition && !r.payload?.occurredAt)
      bad("event rules without a condition require occurredAt");
  }
}

function checked(value: unknown): DashboardManifest {
  const manifest = projectNativeManifest(value) as DashboardManifest;
  nativeSemantics(manifest);
  manifest.files.sort((a, b) => compareNativePaths(a.path, b.path));
  return manifest;
}

/** Validated native Codable projection, digest omitted, files sorted by Swift identity. */
export function canonicalNativeManifest(
  manifest: NativeCodableInput<DashboardManifest>,
): string {
  const projected = checked(manifest);
  delete projected.digest;
  return nativeJSON(projected, integerField);
}

export function nativeDeploymentDigest(
  manifest: NativeCodableInput<DashboardManifest>,
): string {
  return hash(canonicalNativeManifest(manifest));
}
function hash(bytes: Uint8Array | string): string {
  return createHash("sha256").update(bytes).digest("hex");
}
function freeze<T>(value: T): T {
  if (value !== null && typeof value === "object") {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

/** Pure assembly of explicit, already-resolved metadata and byte snapshots. */
export function createNativePackage(
  metadata: NativePackageMetadata,
  assets: readonly NativePackageAsset[],
): NativePackage {
  if (
    metadata === null ||
    typeof metadata !== "object" ||
    Array.isArray(metadata)
  )
    fail(
      "representation",
      "$metadata",
      "expected explicit resolved manifest metadata",
    );
  if (Object.hasOwn(metadata, "files") || Object.hasOwn(metadata, "digest"))
    fail(
      "computed_field",
      "$metadata",
      "files and digest are computed from supplied bytes",
    );
  const input = copyData(metadata, "$metadata") as Record<string, unknown>;
  if (!Array.isArray(assets) || assets.length < 1 || assets.length > 2000)
    fail("size_limit", "$assets", "expected between one and 2000 assets");
  if (
    Reflect.ownKeys(assets).some(
      (key) =>
        key !== "length" &&
        (typeof key !== "string" ||
          !/^(0|[1-9][0-9]*)$/.test(key) ||
          Number(key) >= assets.length),
    )
  )
    fail(
      "representation",
      "$assets",
      "asset array must be dense without extra properties",
    );
  let total = 0;
  const snapshots = Array.from({ length: assets.length }, (_, index) => {
    const field = `$assets[${index}]`;
    const member = Object.getOwnPropertyDescriptor(assets, String(index));
    if (!member || !member.enumerable || !("value" in member))
      fail(
        "representation",
        field,
        "expected an enumerable asset data property",
      );
    const asset = member.value as NativePackageAsset;
    if (
      asset === null ||
      typeof asset !== "object" ||
      (Object.getPrototypeOf(asset) !== Object.prototype &&
        Object.getPrototypeOf(asset) !== null) ||
      Reflect.ownKeys(asset).some((k) => k !== "path" && k !== "data")
    )
      fail("representation", field, "expected path and data only");
    const path = Object.getOwnPropertyDescriptor(asset, "path"),
      data = Object.getOwnPropertyDescriptor(asset, "data");
    if (
      !path ||
      !path.enumerable ||
      !("value" in path) ||
      typeof path.value !== "string" ||
      !data ||
      !data.enumerable ||
      !("value" in data) ||
      !(data.value instanceof Uint8Array)
    )
      fail(
        "representation",
        field,
        "expected a string path and Uint8Array data properties",
      );
    if (path.value === "manifest.json")
      fail(
        "reserved_path",
        field + ".path",
        "manifest.json is reserved for the computed persisted manifest",
      );
    const view = rawByteView(data.value as Uint8Array, field + ".data");
    if (view.byteLength < 1 || view.byteLength > 50 * 1024 * 1024 - total)
      fail(
        "size_limit",
        field + ".data",
        "assets must be nonempty and fit within 50 MiB",
      );
    total += view.byteLength;
    return Object.freeze({
      path: path.value as string,
      data: copyBytes(view),
    });
  });
  input.files = snapshots.map((a) => ({
    path: a.path,
    bytes: a.data.byteLength,
    sha256: hash(a.data),
  }));
  const manifest = checked(input);
  const canonicalJSON = nativeJSON(manifest, integerField);
  const digest = hash(canonicalJSON);
  manifest.digest = digest;
  snapshots.sort((a, b) => compareNativePaths(a.path, b.path));
  const ownedAssets = snapshots.map((a) =>
    Object.freeze({
      path: a.path,
      get data() {
        return copyBytes(a.data);
      },
    }),
  );
  const manifestJSON = nativeJSON(manifest, integerField, true);
  const expandedBytes = checkNativeExpandedBytes(total, manifestJSON);
  return Object.freeze({
    profile: NATIVE_PACKAGE_PROFILE,
    manifest: freeze(manifest),
    digest,
    canonicalJSON,
    manifestJSON,
    expandedBytes,
    assets: Object.freeze(ownedAssets),
  });
}
