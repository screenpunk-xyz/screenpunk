/** Internal native codec. This module does not validate a dashboard schema. */
export class NativePackageError extends Error {
  constructor(
    readonly code: string,
    readonly path: string,
    detail: string,
  ) {
    super(`${path}: ${detail}`);
    this.name = "NativePackageError";
  }
}

export function fail(code: string, path: string, detail: string): never {
  throw new NativePackageError(code, path, detail);
}

/** Foundation sortedKeys compares raw Unicode scalars, not normalized Swift Strings. */
export function compareNativeKeys(a: string, b: string): number {
  const left = Array.from(a, (c) => c.codePointAt(0)!);
  const right = Array.from(b, (c) => c.codePointAt(0)!);
  for (let i = 0; i < Math.min(left.length, right.length); i++) {
    if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1;
  }
  return Math.sign(left.length - right.length);
}

/** Swift file ordering is canonically equivalent. Public v1 paths are ASCII. */
export function compareNativePaths(a: string, b: string): number {
  return compareNativeKeys(a.normalize("NFC"), b.normalize("NFC"));
}

const powers = [1n];
function ten(n: number): bigint {
  while (powers.length <= n) powers.push(powers[powers.length - 1] * 10n);
  return powers[n];
}
const denominator = 1n << 1075n;
const bitsView = new DataView(new ArrayBuffer(8));
function units(bits: bigint): bigint {
  const exponent = Number((bits >> 52n) & 0x7ffn);
  const fraction = bits & ((1n << 52n) - 1n);
  return exponent === 0
    ? fraction
    : ((1n << 52n) | fraction) << BigInt(exponent - 1);
}

/**
 * Exact binary64 interval search: shortest round-tripping decimal, then nearest,
 * then even. No JS shortest-decimal tie policy is assumed. At most 17 digits.
 * The interval is expressed in units of 2^-1074; midpoint denominator is 2^1075.
 */
export function nativeDouble(value: number): string {
  if (!Number.isFinite(value))
    fail("non_finite", "$number", "native Double must be finite");
  if (value === 0) return Object.is(value, -0) ? "-0" : "0";
  const magnitude = Math.abs(value);
  bitsView.setFloat64(0, magnitude, false);
  const bits = bitsView.getBigUint64(0, false);
  const valueUnits = units(bits);
  const lower = valueUnits + units(bits - 1n);
  // The hypothetical next value above MAX_VALUE is 2^1024, not Infinity.
  const upper =
    valueUnits +
    (bits === 0x7fefffffffffffffn ? 1n << 2098n : units(bits + 1n));
  const inclusive = (bits & 1n) === 0n;
  const target = valueUnits * 2n;
  let exponent = Number(magnitude.toExponential().split("e")[1]);
  const atLeastPower = (p: number) =>
    p >= 0 ? target >= denominator * ten(p) : target * ten(-p) >= denominator;
  while (!atLeastPower(exponent)) exponent--;
  while (atLeastPower(exponent + 1)) exponent++;
  for (let count = 1; count <= 17; count++) {
    let power = exponent - count + 1;
    const multiplier = power < 0 ? ten(-power) : 1n;
    const divisor = power > 0 ? denominator * ten(power) : denominator;
    const l = lower * multiplier,
      u = upper * multiplier,
      t = target * multiplier;
    const minimum = inclusive ? (l + divisor - 1n) / divisor : l / divisor + 1n;
    const maximum = inclusive ? u / divisor : (u - 1n) / divisor;
    if (minimum > maximum) continue;
    let candidate = t / divisor;
    const remainder = t % divisor;
    if (
      remainder * 2n > divisor ||
      (remainder * 2n === divisor && (candidate & 1n) === 1n)
    )
      candidate++;
    if (candidate < minimum) candidate = minimum;
    if (candidate > maximum) candidate = maximum;
    while (candidate % 10n === 0n) {
      candidate /= 10n;
      power++;
    }
    const digits = candidate.toString();
    const p = power + digits.length - 1;
    let text: string;
    // Swift 6.3.3's runtime uses the binary exponent boundary at exactly 2^53.
    if (p < -4 || magnitude > 2 ** 53) {
      text =
        digits[0] +
        (digits.length > 1 ? "." + digits.slice(1) : "") +
        "e" +
        (p < 0 ? "-" : "+") +
        Math.abs(p).toString().padStart(2, "0");
    } else if (p < 0) {
      text = "0." + "0".repeat(-p - 1) + digits;
    } else if (p + 1 < digits.length) {
      text = digits.slice(0, p + 1) + "." + digits.slice(p + 1);
    } else {
      text = digits + "0".repeat(p + 1 - digits.length);
    }
    return (value < 0 ? "-" : "") + text;
  }
  return fail(
    "number_encoding",
    "$number",
    "binary64 shortest-decimal search failed",
  );
}

export function nativeJSON(
  value: unknown,
  integer: (path: string[]) => boolean,
  pretty = false,
): string {
  function encode(v: unknown, path: string[], depth: number): string {
    if (v === null || typeof v === "boolean" || typeof v === "string")
      return JSON.stringify(v);
    if (typeof v === "number")
      return integer(path) ? String(v === 0 ? 0 : v) : nativeDouble(v);
    if (typeof v !== "object" || v === null)
      return fail("representation", path.join("."), "not native JSON data");
    const array = Array.isArray(v);
    const entries = array
      ? v.map((x, i) => encode(x, [...path, String(i)], depth + 1))
      : Object.keys(v)
          .sort(compareNativeKeys)
          .map(
            (k) =>
              JSON.stringify(k) +
              (pretty ? " : " : ":") +
              encode(
                (v as Record<string, unknown>)[k],
                [...path, k],
                depth + 1,
              ),
          );
    const open = array ? "[" : "{",
      close = array ? "]" : "}";
    if (!entries.length)
      return pretty ? open + "\n\n" + "  ".repeat(depth) + close : open + close;
    return pretty
      ? open +
          "\n" +
          entries.map((e) => "  ".repeat(depth + 1) + e).join(",\n") +
          "\n" +
          "  ".repeat(depth) +
          close
      : open + entries.join(",") + close;
  }
  return encode(value, [], 0);
}
