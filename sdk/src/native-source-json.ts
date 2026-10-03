import { fail } from "./native-package-json.js";
import type { Schema } from "./native-package-domain.js";

/** Exact decimal integrality, before binary64 rounding. Never constructs huge BigInts. */
function exactInteger(token: string): boolean {
  const match = /^-?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(token)!;
  const digits = match[1] + (match[2] ?? "");
  if (!/[1-9]/.test(digits)) return true;
  const exponent = Number(match[3] ?? "0");
  const fraction = (match[2]?.length ?? 0) - exponent;
  if (fraction <= 0) return true;
  if (!Number.isFinite(fraction) || fraction >= digits.length) return false;
  return !/[1-9]/.test(digits.slice(digits.length - fraction));
}

/**
 * Schema-directed JSON decoding. This preserves number lexemes until Int validation
 * and detects duplicate decoded keys before an object can overwrite either value.
 * Input is a previously copied, fatal-UTF-8-decoded string of at most 5 MiB.
 */
export function decodeNativeSourceJSON(text: string, schema: Schema): unknown {
  let offset = 0;
  const number = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/y;
  const bad = (code = "json_syntax", path = "$source"): never =>
    fail(code, path, "invalid native source JSON");
  const space = () => {
    while (/^[\x20\x09\x0a\x0d]$/.test(text[offset] ?? "")) offset++;
  };
  function string(path: string): string {
    const start = offset++;
    while (offset < text.length) {
      const ch = text.charCodeAt(offset++);
      if (ch === 34) {
        try {
          return JSON.parse(text.slice(start, offset)) as string;
        } catch {
          return bad("json_syntax", path);
        }
      }
      if (ch < 32) return bad("json_syntax", path);
      if (ch === 92) {
        const escape = text[offset++];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.slice(offset, offset + 4)))
            return bad("json_syntax", path);
          offset += 4;
        } else if (!escape || !'"\\/bfnrt'.includes(escape))
          return bad("json_syntax", path);
      }
    }
    return bad("json_syntax", path);
  }
  function value(s: Schema, path: string, depth: number): unknown {
    if (depth > 32) return bad("depth_limit", path);
    space();
    if (text.startsWith("null", offset)) {
      offset += 4;
      return null;
    }
    if (s.type === "object") {
      if (text[offset++] !== "{") return bad("schema", path);
      const output: Record<string, unknown> = Object.create(null);
      const keys = new Set<string>();
      space();
      if (text[offset] === "}") {
        offset++;
        return output;
      }
      while (offset < text.length) {
        space();
        if (text[offset] !== '"') return bad("json_syntax", path);
        const key = string(path);
        if (keys.has(key)) return bad("duplicate_key", path);
        keys.add(key);
        if (s.maxProperties !== undefined && keys.size > s.maxProperties)
          return bad("schema", path);
        const declared =
          s.properties && Object.hasOwn(s.properties, key)
            ? s.properties[key]
            : undefined;
        const child = declared ?? s.additionalProperties;
        if (!child || typeof child === "boolean")
          return bad("unknown_field", path);
        space();
        if (text[offset++] !== ":") return bad("json_syntax", path);
        output[key] = value(child, `${path}.${key}`, depth + 1);
        space();
        const delimiter = text[offset++];
        if (delimiter === "}") return output;
        if (delimiter !== ",") return bad("json_syntax", path);
      }
      return bad("json_syntax", path);
    }
    if (s.type === "array") {
      if (text[offset++] !== "[") return bad("schema", path);
      const output: unknown[] = [];
      space();
      if (text[offset] === "]") {
        offset++;
        return output;
      }
      while (offset < text.length) {
        if (s.maxItems !== undefined && output.length >= s.maxItems)
          return bad("schema", path);
        output.push(value(s.items!, `${path}[${output.length}]`, depth + 1));
        space();
        const delimiter = text[offset++];
        if (delimiter === "]") return output;
        if (delimiter !== ",") return bad("json_syntax", path);
      }
      return bad("json_syntax", path);
    }
    // Every current union/enum is a scalar: never recurse into unexpected objects.
    if (text[offset] === '"') return string(path);
    if (text.startsWith("true", offset)) {
      offset += 4;
      return true;
    }
    if (text.startsWith("false", offset)) {
      offset += 5;
      return false;
    }
    number.lastIndex = offset;
    const match = number.exec(text);
    if (!match) return bad("json_syntax", path);
    offset = number.lastIndex;
    const n = Number(match[0]);
    if (!Number.isFinite(n)) return bad("schema", path);
    if (
      s.type === "integer" &&
      (!exactInteger(match[0]) || !Number.isSafeInteger(n))
    )
      return bad("lossy_integer", path);
    return n;
  }
  const output = value(schema, "$source", 0);
  space();
  if (offset !== text.length) return bad();
  return output;
}
