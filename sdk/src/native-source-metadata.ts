import { createHash } from "node:crypto";
import { types } from "node:util";
import type { ManifestTarget } from "./package.js";
import {
  type NativeCodableInput,
  type NativePackageMetadata,
  type NativeReadonly,
} from "./native-package.js";
import { nativeSemantics } from "./native-package-semantics.js";
import { rawByteView, copyBytes } from "./native-package-bytes.js";
import {
  manifestSchema,
  projectNativeValue,
  integerField,
  type Schema,
} from "./native-package-domain.js";
import { fail, nativeJSON } from "./native-package-json.js";
import { decodeNativeSourceJSON } from "./native-source-json.js";

export type NativeConstructionIdentity = Readonly<{
  schemaVersion: 1;
  dashboardId: string;
  revision: string;
  entrypoint: "index.html";
  sdkVersion: "1";
  target: NativeCodableInput<ManifestTarget>;
}>;
export interface NativeSourceMetadata {
  readonly metadata: NativeReadonly<NativePackageMetadata>;
  readonly canonicalJSON: string;
  readonly sha256: string;
  readonly sourceSha256: string;
}

const sourceFields = [
  "name",
  "connections",
  "target",
  "pages",
  "defaultPageId",
  "eventRules",
  "deviceBehavior",
];
const identityFields = [
  "schemaVersion",
  "dashboardId",
  "revision",
  "entrypoint",
  "sdkVersion",
  "target",
];
function subset(fields: string[], required: readonly string[]): Schema {
  return {
    type: "object",
    additionalProperties: false,
    required,
    properties: Object.fromEntries(
      fields.map((key) => [key, manifestSchema.properties![key]]),
    ),
  };
}
const sourceSchema = subset(sourceFields, ["name", "connections"]);
const identitySchema = subset(identityFields, identityFields);
const metadataSchema = subset(
  Object.keys(manifestSchema.properties!).filter(
    (key) => key !== "files" && key !== "digest",
  ),
  manifestSchema.required!.filter((key) => key !== "files"),
);
function hash(value: Uint8Array | string): string {
  return createHash("sha256").update(value).digest("hex");
}
function freeze<T>(value: T): T {
  if (value !== null && typeof value === "object") {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

/**
 * Capture one complete authored declaration snapshot. No asset, permission default,
 * prior revision inheritance, storage I/O, or device authorization is synthesized.
 * Byte input is limited to the existing 5 MiB single-source-file ceiling.
 */
export function captureNativeSourceMetadata(
  sourceJSON: Uint8Array,
  identity: NativeConstructionIdentity,
): NativeSourceMetadata {
  if (!types.isUint8Array(sourceJSON))
    fail("representation", "$source", "expected Uint8Array source bytes");
  const view = rawByteView(sourceJSON, "$source");
  if (types.isSharedArrayBuffer(view.buffer))
    fail(
      "representation",
      "$source",
      "shared mutable byte storage cannot be snapshotted reproducibly",
    );
  if (view.byteLength > 5 * 1024 * 1024)
    fail("size_limit", "$source", "source metadata exceeds 5 MiB");
  const bytes = copyBytes(view);
  const header = projectNativeValue(
    identity,
    identitySchema,
    "$identity",
    true,
  ) as NativeConstructionIdentity;
  if (header.entrypoint !== "index.html")
    fail(
      "schema",
      "$identity.entrypoint",
      "fixed source output requires index.html",
    );
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
      bytes,
    );
  } catch {
    return fail("utf8", "$source", "source metadata must be valid UTF-8");
  }
  // A BOM is not JSON whitespace. Reject it explicitly instead of silently stripping bytes.
  if (text.charCodeAt(0) === 0xfeff)
    fail(
      "json_syntax",
      "$source",
      "source metadata must not contain a UTF-8 BOM",
    );
  const source = projectNativeValue(
    decodeNativeSourceJSON(text, sourceSchema),
    sourceSchema,
    "$source",
  ) as Record<string, unknown>;
  if (
    source.target !== undefined &&
    nativeJSON(source.target, (path) => integerField(["target", ...path])) !==
      nativeJSON(header.target, (path) => integerField(["target", ...path]))
  )
    fail(
      "target_mismatch",
      "$source.target",
      "source target differs from the explicit construction target",
    );
  const metadata = projectNativeValue(
    { ...source, ...header },
    metadataSchema,
    "$metadata",
  ) as NativePackageMetadata;
  nativeSemantics(metadata as Parameters<typeof nativeSemantics>[0], false);
  const canonicalJSON = nativeJSON(metadata, integerField);
  return freeze({
    metadata: metadata as NativeReadonly<NativePackageMetadata>,
    canonicalJSON,
    sha256: hash(canonicalJSON),
    sourceSha256: hash(bytes),
  });
}
