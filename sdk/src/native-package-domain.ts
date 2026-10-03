import { types } from "node:util";
import { fail } from "./native-package-json.js";
import { nativeManifestSchema } from "./native-package-schema.js";

export type Schema = {
  type?: string;
  const?: unknown;
  enum?: readonly unknown[];
  properties?: Record<string, Schema | boolean>;
  required?: readonly string[];
  additionalProperties?: Schema | boolean;
  items?: Schema;
  minimum?: number;
  maximum?: number;
  exclusiveMinimum?: number;
  minLength?: number;
  maxLength?: number;
  pattern?: string;
  format?: string;
  minItems?: number;
  maxItems?: number;
  maxProperties?: number;
  uniqueItems?: boolean;
  anyOf?: readonly Schema[];
  oneOf?: readonly Schema[];
  not?: Schema;
};
export const manifestSchema = nativeManifestSchema as unknown as Schema;

function string(value: string, path: string): void {
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff))
        fail(
          "unicode",
          path,
          "unpaired UTF-16 surrogate is not a native String",
        );
    } else if (c >= 0xdc00 && c <= 0xdfff)
      fail("unicode", path, "unpaired UTF-16 surrogate is not a native String");
  }
}

/** Schema-directed snapshot: unknown branches and scalar objects are never traversed. */
export function copyData(
  value: unknown,
  path = "$manifest",
  seen = new Set<object>(),
  schema: Schema = manifestSchema,
  rejectProxy = false,
): unknown {
  if (rejectProxy && types.isProxy(value))
    fail(
      "representation",
      path,
      "proxy input cannot be snapshotted reproducibly",
    );
  if (schema.anyOf) {
    if (typeof value === "string") string(value, path);
    return validate(value, schema, path, false);
  }
  if (
    schema.type === "object" &&
    (value === null || typeof value !== "object" || Array.isArray(value))
  )
    return fail("schema", path, "expected object");
  if (schema.type === "array" && !Array.isArray(value))
    return fail("schema", path, "expected array");
  if (schema.type !== "object" && schema.type !== "array") {
    if (typeof value === "string") string(value, path);
    return validate(value, schema, path, false);
  }
  if (typeof value === "string") {
    string(value, path);
    return value;
  }
  if (
    value === null ||
    value === undefined ||
    typeof value === "boolean" ||
    typeof value === "number"
  )
    return value;
  if (typeof value !== "object")
    return fail("representation", path, "expected plain structured JSON data");
  if (seen.has(value))
    return fail("representation", path, "cyclic structured data");
  const array = Array.isArray(value);
  if (
    array &&
    ((schema.minItems !== undefined && value.length < schema.minItems) ||
      (schema.maxItems !== undefined && value.length > schema.maxItems))
  )
    return fail("schema", path, "array length is outside the schema range");
  if (
    !array &&
    Object.getPrototypeOf(value) !== Object.prototype &&
    Object.getPrototypeOf(value) !== null
  )
    return fail("representation", path, "expected a plain object");
  seen.add(value);
  const result: Record<string, unknown> = Object.create(null);
  const normalized = new Set<string>();
  const keys = Reflect.ownKeys(value);
  if (
    !array &&
    schema.maxProperties !== undefined &&
    keys.length > schema.maxProperties
  )
    return fail("schema", path, "dictionary has too many members");
  for (const key of keys) {
    if (array && key === "length") continue;
    if (typeof key !== "string")
      return fail("representation", path, "symbol properties are unsupported");
    const childPath = array ? `${path}[${key}]` : `${path}.${key}`;
    if (
      array &&
      (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= value.length)
    )
      return fail(
        "representation",
        path,
        "array must be dense without extra properties",
      );
    const declared =
      schema.properties && Object.hasOwn(schema.properties, key)
        ? schema.properties[key]
        : undefined;
    const child = array
      ? schema.items
      : (declared ?? schema.additionalProperties);
    if (!child || child === true)
      return fail(
        "unknown_field",
        childPath,
        "unknown fields cannot participate silently in a native digest",
      );
    string(key, path);
    const descriptor = Object.getOwnPropertyDescriptor(value, key)!;
    if (!descriptor.enumerable || !("value" in descriptor))
      return fail(
        "representation",
        childPath,
        "expected an enumerable data property",
      );
    const canonical = key.normalize("NFC");
    if (normalized.has(canonical))
      return fail(
        "ambiguous_key",
        childPath,
        "canonically equivalent keys would collide in a native dictionary",
      );
    normalized.add(canonical);
    if ((schema.required ?? []).includes(key) && descriptor.value === undefined)
      fail(
        "required_field",
        childPath,
        "required native field is absent; no default is synthesized",
      );
    // Optional native Codable fields project null/undefined to absence later.
    result[key] =
      declared !== undefined &&
      !(schema.required ?? []).includes(key) &&
      (descriptor.value === null || descriptor.value === undefined)
        ? descriptor.value
        : copyData(descriptor.value, childPath, seen, child, rejectProxy);
  }
  seen.delete(value);
  if (!array) return result;
  if (
    Object.keys(result).length !== value.length ||
    Object.keys(result).some(
      (k) => !/^(0|[1-9][0-9]*)$/.test(k) || Number(k) >= value.length,
    )
  )
    return fail(
      "representation",
      path,
      "array must be dense without extra properties",
    );
  return Array.from({ length: value.length }, (_, i) => result[String(i)]);
}

function validate(
  value: unknown,
  s: Schema | boolean,
  path: string,
  project: boolean,
): unknown {
  const bad = (detail: string): never => fail("schema", path, detail);
  if (s === false)
    return bad("field is forbidden by the native schema profile");
  if (s === true) return value;
  if ("const" in s && value !== s.const)
    bad(`expected ${JSON.stringify(s.const)}`);
  if (s.enum && !s.enum.includes(value))
    bad("value is outside the declared enum");
  if (s.not?.enum?.includes(value)) bad("value is forbidden");
  if (s.anyOf) {
    for (const variant of s.anyOf) {
      try {
        return validate(value, variant, path, project);
      } catch (e) {
        if (!(e instanceof Error) || e.name !== "NativePackageError") throw e;
      }
    }
    return bad(
      "expected a finite native scalar (string, Double, boolean or null)",
    );
  }
  if (s.type === "integer" || s.type === "number") {
    if (typeof value !== "number" || !Number.isFinite(value))
      bad("expected a finite number");
    const n = value as number;
    if (s.type === "integer" && !Number.isSafeInteger(n))
      fail(
        "lossy_integer",
        path,
        "native Int fields require a safe JavaScript integer",
      );
    if (
      (s.minimum !== undefined && n < s.minimum) ||
      (s.maximum !== undefined && n > s.maximum) ||
      (s.exclusiveMinimum !== undefined && n <= s.exclusiveMinimum)
    )
      bad("number is outside the schema range");
    return s.type === "integer" && n === 0 ? 0 : n;
  }
  if (s.type === "null" && value !== null) bad("expected null");
  if (s.type === "boolean" && typeof value !== "boolean")
    bad("expected boolean");
  if (s.type === "string") {
    if (typeof value !== "string") bad("expected string");
    const text = value as string,
      length = Array.from(text).length;
    if (
      (s.minLength !== undefined && length < s.minLength) ||
      (s.maxLength !== undefined && length > s.maxLength)
    )
      bad("string length is outside the schema range");
    if (s.pattern && !new RegExp(s.pattern).test(text))
      bad("string does not match the schema pattern");
    if (
      s.format === "uuid" &&
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        text,
      )
    )
      bad("expected an explicit UUID");
  }
  if (s.type === "array") {
    if (!Array.isArray(value)) bad("expected array");
    const items = value as unknown[];
    if (
      (s.minItems !== undefined && items.length < s.minItems) ||
      (s.maxItems !== undefined && items.length > s.maxItems)
    )
      bad("array length is outside the schema range");
    const output = items.map((v, i) =>
      validate(v, s.items!, `${path}[${i}]`, project),
    );
    if (
      s.uniqueItems &&
      new Set(output.map((v) => JSON.stringify(v))).size !== output.length
    )
      bad("array contains duplicate values");
    return output;
  }
  if (s.type === "object" || s.properties || s.required) {
    if (value === null || typeof value !== "object" || Array.isArray(value))
      bad("expected object");
    const input = value as Record<string, unknown>,
      output: Record<string, unknown> = Object.create(null);
    for (const required of s.required ?? [])
      if (!Object.hasOwn(input, required) || input[required] === undefined)
        fail(
          "required_field",
          `${path}.${required}`,
          "required native field is absent; no default is synthesized",
        );
    for (const key of Object.keys(input)) {
      const field =
        s.properties && Object.hasOwn(s.properties, key)
          ? s.properties[key]
          : undefined;
      const child = field ?? s.additionalProperties;
      if (
        child === false ||
        (child === undefined && s.additionalProperties === false)
      )
        fail(
          "unknown_field",
          `${path}.${key}`,
          "unknown fields cannot participate silently in a native digest",
        );
      // Only declared optional Codable properties project null/undefined to absence.
      if (
        project &&
        field !== undefined &&
        !(s.required ?? []).includes(key) &&
        (input[key] === null || input[key] === undefined)
      )
        continue;
      output[key] =
        child === undefined
          ? input[key]
          : validate(input[key], child, `${path}.${key}`, project);
    }
    if (
      s.maxProperties !== undefined &&
      Object.keys(output).length > s.maxProperties
    )
      bad("dictionary has too many members");
    if (s.oneOf) {
      let matches = 0;
      for (const branch of s.oneOf) {
        try {
          validate(output, branch, path, false);
          matches++;
        } catch (e) {
          if (!(e instanceof Error) || e.name !== "NativePackageError") throw e;
        }
      }
      if (matches !== 1) bad("expected exactly one declared parameter rule");
    }
    return output;
  }
  return value;
}

export function projectNativeValue(
  value: unknown,
  schema: Schema,
  path: string,
  rejectProxy = false,
): unknown {
  return validate(
    copyData(value, path, new Set(), schema, rejectProxy),
    schema,
    path,
    true,
  );
}

export function projectNativeManifest(value: unknown): unknown {
  return projectNativeValue(value, manifestSchema, "$manifest");
}

export function integerField(path: string[]): boolean {
  let schema: Schema | boolean | undefined = manifestSchema;
  for (const key of path) {
    if (!schema || typeof schema === "boolean") return false;
    schema =
      schema.type === "array"
        ? schema.items
        : schema.properties && Object.hasOwn(schema.properties, key)
          ? schema.properties[key]
          : schema.additionalProperties;
  }
  return typeof schema === "object" && schema.type === "integer";
}

/** Constructor transport budget includes the exact persisted manifest entry. */
export function checkNativeExpandedBytes(
  assetBytes: number,
  manifestJSON: string,
): number {
  const manifestBytes = new TextEncoder().encode(manifestJSON).byteLength;
  const limit = 50 * 1024 * 1024;
  if (
    !Number.isSafeInteger(assetBytes) ||
    assetBytes < 0 ||
    manifestBytes > limit - assetBytes
  )
    fail(
      "size_limit",
      "$package",
      "assets plus manifest.json exceed the 50 MiB expanded transport budget",
    );
  return assetBytes + manifestBytes;
}
