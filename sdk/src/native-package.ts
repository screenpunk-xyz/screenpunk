import { createHash } from "node:crypto";
import { rawByteView, copyBytes } from "./native-package-bytes.js";
import { nativeSemantics } from "./native-package-semantics.js";
import type { DashboardManifest } from "./package.js";
import {
  checkNativeExpandedBytes,
  copyData,
  integerField,
  projectNativeManifest,
} from "./native-package-domain.js";
import { compareNativePaths, fail, nativeJSON } from "./native-package-json.js";
export { NativePackageError } from "./native-package-json.js";

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

export { captureNativeSourceMetadata } from "./native-source-metadata.js";
export type {
  NativeConstructionIdentity,
  NativeSourceMetadata,
} from "./native-source-metadata.js";
