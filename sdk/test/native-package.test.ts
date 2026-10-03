import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  canonicalNativeManifest,
  createNativePackage,
  nativeDeploymentDigest,
  NativePackageError,
  NATIVE_PACKAGE_PROFILE,
  type NativePackageMetadata,
} from "../src/native-package.js";
import {
  compareNativeKeys,
  compareNativePaths,
  nativeDouble,
} from "../src/native-package-json.js";
import { nativeManifestSchema } from "../src/native-package-schema.js";
import { checkNativeExpandedBytes } from "../src/native-package-domain.js";
import { deploymentDigest } from "../src/package.js";

type Observation = {
  id: string;
  decodeAccepted: boolean;
  inputManifestUTF8?: string;
  rawInputManifestUTF8?: string;
  canonicalUTF8?: string;
  digest?: string;
  persistedManifestUTF8?: string;
  assets?: { path: string; base64: string; bytes: number; sha256: string }[];
  samples?: { path: string; decodedBinary64?: string }[];
};
const load = (path: string) =>
  JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8"));
const first = load("./fixtures/native-package/CORPUS.json");
const second = load("./fixtures/native-package-numeric-unicode/CORPUS.json");
const observations: Observation[] = [...first.cases, ...second.observations];
const narrower: Record<string, string> = {
  "optional-empty-arrays": "schema",
  "invalid-schema": "schema",
  "invalid-orientation": "schema",
  "missing-entrypoint": "missing_entrypoint",
  "duplicate-file": "duplicate",
  "empty-inventory": "schema",
  "negative-file-size": "schema",
  "native-path-dotdot-substring": "schema",
  "native-path-empty-component": "path_identity",
  "native-path-dot-component": "path_identity",
  "native-path-unicode-nfd": "schema",
  "rejected-path-traversal": "schema",
  "rejected-path-encoded-traversal": "schema",
  "native-zero-byte-file": "schema",
  "inventory-unicode-forward": "schema",
  "inventory-unicode-reverse": "schema",
  "inventory-equivalent-collision-forward": "schema",
  "inventory-equivalent-collision-reverse": "schema",
  "inventory-equivalent-single-composed": "schema",
  "inventory-equivalent-single-decomposed": "schema",
  "target-scaleUpperUp": "schema",
  "target-scaleZero": "schema",
  "target-scaleNegativeZero": "schema",
  "target-safeAreaBelowZero": "schema",
};
function rejected(fn: () => unknown, code?: string, path?: string) {
  assert.throws(
    fn,
    (e: unknown) =>
      e instanceof NativePackageError &&
      (!code || e.code === code) &&
      (!path || e.path === path),
  );
}
function manifest(id = "minimal-resolved-gallery"): any {
  const row = observations.find((v) => v.id === id)!;
  return JSON.parse(row.inputManifestUTF8 ?? row.rawInputManifestUTF8!);
}
function assemble(row: Observation) {
  const m = JSON.parse(row.inputManifestUTF8 ?? row.rawInputManifestUTF8!);
  delete m.files;
  delete m.digest;
  return createNativePackage(
    m,
    row.assets!.map((a) => ({
      path: a.path,
      data: Buffer.from(a.base64, "base64"),
    })),
  );
}

test("schema projection includes every current assertion, without annotation keywords", () => {
  function assertions(value: any): any {
    if (Array.isArray(value)) return value.map(assertions);
    if (value && typeof value === "object")
      return Object.fromEntries(
        Object.entries(value)
          .filter(
            ([k]) => !["$schema", "$id", "title", "description"].includes(k),
          )
          .map(([k, v]) => [k, assertions(v)]),
      );
    return value;
  }
  assert.deepEqual(
    nativeManifestSchema,
    assertions(load("../../schemas/dashboard-manifest.schema.json")),
  );
});

for (const row of observations) {
  test(`native differential manifest: ${row.id}`, () => {
    const input = JSON.parse(
      row.inputManifestUTF8 ?? row.rawInputManifestUTF8!,
    );
    if (!row.decodeAccepted || narrower[row.id]) {
      rejected(() => canonicalNativeManifest(input), narrower[row.id]);
    } else {
      assert.equal(canonicalNativeManifest(input), row.canonicalUTF8);
      assert.equal(nativeDeploymentDigest(input), row.digest);
    }
  });
}

test("byte constructor matches native canonical, persisted pretty manifest and every asset hash", () => {
  let count = 0;
  for (const row of first.cases as Observation[]) {
    if (!row.decodeAccepted || narrower[row.id]) continue;
    const output = assemble(row);
    assert.equal(output.profile, "screenpunk-native-manifest-v1");
    assert.equal(output.canonicalJSON, row.canonicalUTF8, row.id);
    assert.equal(output.digest, row.digest, row.id);
    assert.equal(output.manifestJSON, row.persistedManifestUTF8, row.id);
    for (const asset of output.assets) {
      const file = output.manifest.files.find((f) => f.path === asset.path)!;
      assert.equal(asset.data.byteLength, file.bytes);
      assert.equal(
        createHash("sha256").update(asset.data).digest("hex"),
        file.sha256,
      );
    }
    count++;
  }
  assert.equal(count, 18);
});

test("normalized gallery parser fixture is an explicit resolved input, not a parser implementation", () => {
  const row = first.parser.resolved as Observation;
  const output = assemble(row);
  assert.equal(output.digest, row.digest);
  assert.equal(output.canonicalJSON, row.canonicalUTF8);
  assert.equal(output.manifestJSON, row.persistedManifestUTF8);
});

test("all native decoded Double bit observations reproduce exact native numeric tokens", () => {
  let count = 0;
  for (const row of second.observations as Observation[]) {
    for (const sample of row.samples ?? []) {
      if (!sample.decodedBinary64) continue;
      const key = sample.path.split(".").at(-1)!;
      const token = row.canonicalUTF8!.match(
        new RegExp(`"${key}":(-?[0-9][^,}\\]]*)`),
      )?.[1];
      assert.ok(token, sample.path);
      assert.equal(
        nativeDouble(Buffer.from(sample.decodedBinary64, "hex").readDoubleBE()),
        token,
        row.id + ":" + sample.path,
      );
      count++;
    }
  }
  assert.equal(count, 62);
});

test("dictionary collision raw member permutations are rejected before native decoding can collapse them", () => {
  const collisions = load(
    "./fixtures/native-package-numeric-unicode/COLLISIONS.json",
  );
  for (const row of collisions.collisions)
    rejected(
      () => canonicalNativeManifest(JSON.parse(row.rawInputManifestUTF8)),
      "ambiguous_key",
    );
});

test("raw dictionary and normalized file ordering match native comparator observations", () => {
  for (const row of second.comparisons) {
    assert.equal(
      compareNativePaths(row.left, row.right) < 0,
      row.swiftLeftLess,
    );
    assert.equal(compareNativePaths(row.left, row.right) === 0, row.swiftEqual);
  }
  assert.equal(compareNativeKeys("é", "e\u0301"), 1);
  assert.equal(compareNativePaths("é", "e\u0301"), 0);
  assert.equal(compareNativeKeys("\ue000", "\u{10000}"), -1);
});

test("negative zero, exact integer boundary and finite binary64 extremes", () => {
  const cases: [number, string][] = [
    [-0, "-0"],
    [0, "0"],
    [2 ** 53, "9007199254740992"],
    [2 ** 53 + 2, "9.007199254740994e+15"],
    [1e-5, "1e-05"],
    [Number.MIN_VALUE, "5e-324"],
    [Number.MAX_VALUE, "1.7976931348623157e+308"],
  ];
  for (const [value, expected] of cases)
    assert.equal(nativeDouble(value), expected);
  for (const value of [NaN, Infinity, -Infinity])
    rejected(() => nativeDouble(value), "non_finite");
});

test("optional projection preserves required scalar null, empty objects and explicit false without defaults", () => {
  const m = manifest("optional-null");
  assert.equal(canonicalNativeManifest(m), canonicalNativeManifest(manifest()));
  const event = manifest("dictionary-ascii-forward");
  event.eventRules[0].condition.equals = null;
  event.eventRules[0].source.parameters = { é: null };
  assert.match(canonicalNativeManifest(event), /"equals":null/);
  assert.match(canonicalNativeManifest(event), /"é":null/);
  event.eventRules[0].defaults.enabled = undefined;
  rejected(
    () => canonicalNativeManifest(event),
    "required_field",
    "$manifest.eventRules[0].defaults.enabled",
  );
});

test("precise errors reject unknown fields, absent required fields and lossy integers", () => {
  const m = manifest();
  m.target.extra = 1;
  rejected(
    () => canonicalNativeManifest(m),
    "unknown_field",
    "$manifest.target.extra",
  );
  delete m.target.extra;
  delete m.target.scale;
  rejected(
    () => canonicalNativeManifest(m),
    "required_field",
    "$manifest.target.scale",
  );
  const event = manifest("dictionary-ascii-forward");
  event.connections[0].operations[0].maxAgeSeconds = 2 ** 53;
  rejected(
    () => canonicalNativeManifest(event),
    "lossy_integer",
    "$manifest.connections[0].operations[0].maxAgeSeconds",
  );
  const meta = manifest();
  delete meta.files;
  meta.digest = "a".repeat(64);
  rejected(
    () =>
      createNativePackage(meta, [
        { path: "index.html", data: new Uint8Array([1]) },
      ]),
    "computed_field",
  );
});

test("plain structured input rejects hooks, cycles, sparse arrays, prototypes and malformed Unicode", () => {
  let calls = 0;
  const m = manifest();
  Object.defineProperty(m, "name", {
    enumerable: true,
    get() {
      calls++;
      return "x";
    },
  });
  rejected(() => canonicalNativeManifest(m), "representation");
  assert.equal(calls, 0);
  const cycle = manifest();
  cycle.target.safeArea = cycle;
  rejected(() => canonicalNativeManifest(cycle), "representation");
  const sparse = manifest();
  sparse.connections = Array(1);
  rejected(() => canonicalNativeManifest(sparse), "representation");
  for (const name of ["\ud800", "\udfff"]) {
    const m = manifest();
    m.name = name;
    rejected(() => canonicalNativeManifest(m), "unicode");
  }
  const proto = manifest();
  proto.target = new Date();
  rejected(() => canonicalNativeManifest(proto), "representation");
  const unknown = manifest();
  Object.defineProperty(unknown.target, "constructor", {
    enumerable: true,
    value: "payload",
  });
  rejected(() => canonicalNativeManifest(unknown), "unknown_field");
});

test("input and post-return mutations cannot change retained manifest or byte snapshots", () => {
  const m = manifest();
  delete m.files;
  const bytes = new Uint8Array([120]);
  const output = createNativePackage(m as NativePackageMetadata, [
    { path: "index.html", data: bytes },
  ]);
  const initial = output.assets[0].data;
  bytes[0] = 121;
  initial[0] = 122;
  m.name = "changed";
  m.target.scale = 1;
  assert.deepEqual(output.assets[0].data, new Uint8Array([120]));
  assert.notEqual(output.assets[0].data, output.assets[0].data);
  assert.equal(output.manifest.name, "Component gallery");
  assert.equal(output.manifest.target.scale, 3);
  assert.throws(() => {
    output.manifest.target.scale = 1;
  }, TypeError);
  assert.throws(() => {
    (output.assets[0] as any).data = bytes;
  }, TypeError);
});

test("schema ranges, native relations, zero bytes and transport path aliases remain explicit", () => {
  const m = manifest();
  m.target.scale = 8.000000000000002;
  rejected(() => canonicalNativeManifest(m), "schema");
  const duplicate = manifest();
  duplicate.connections = [
    { alias: "home", required: false },
    { alias: "home", required: true },
  ];
  rejected(() => canonicalNativeManifest(duplicate), "duplicate");
  const meta = manifest();
  delete meta.files;
  rejected(
    () =>
      createNativePackage(meta, [
        { path: "index.html", data: new Uint8Array() },
      ]),
    "size_limit",
  );
  rejected(
    () =>
      createNativePackage(meta, [
        { path: "index.html", data: new Uint8Array([1]) },
        { path: "a/./b.js", data: new Uint8Array([1]) },
      ]),
    "path_identity",
  );
  const shared = new Uint8Array(new SharedArrayBuffer(1));
  rejected(
    () => createNativePackage(meta, [{ path: "index.html", data: shared }]),
    "representation",
  );
});

test("new profile is explicit and legacy digest remains its historical algorithm", () => {
  const m = manifest("nested-keys-reversed");
  const legacy = deploymentDigest(m);
  assert.notEqual(legacy, nativeDeploymentDigest(m));
  assert.equal(deploymentDigest(m), legacy);
  assert.equal(NATIVE_PACKAGE_PROFILE, "screenpunk-native-manifest-v1");
});

test("expanded transport budget includes persisted UTF-8 manifest at the exact boundary", () => {
  const pretty = '{"name":"é"}';
  const bytes = Buffer.byteLength(pretty);
  assert.equal(
    checkNativeExpandedBytes(50 * 1024 * 1024 - bytes, pretty),
    50 * 1024 * 1024,
  );
  rejected(
    () => checkNativeExpandedBytes(50 * 1024 * 1024 - bytes + 1, pretty),
    "size_limit",
    "$package",
  );
  const m = manifest();
  delete m.files;
  rejected(
    () =>
      createNativePackage(m, [
        { path: "manifest.json", data: new Uint8Array([1]) },
      ]),
    "reserved_path",
  );
});

test("the four native metadata bound probes retain inventory acceptance without materializing assets", () => {
  for (const probe of first.inventoryProbes) {
    const m = manifest();
    m.files = Array.from({ length: probe.declaredFileCount }, (_, i) => ({
      path: i === 0 ? "index.html" : `asset-${i}.js`,
      bytes: probe.declaredFileCount === 1 ? probe.declaredExpandedBytes : 1,
      sha256: "0".repeat(64),
    }));
    if (probe.validationIssues.length)
      rejected(() => canonicalNativeManifest(m), "schema");
    else assert.ok(canonicalNativeManifest(m), probe.id);
  }
});

test("deep and wide unknown branches fail before their data is visited", () => {
  let deep: unknown = null;
  for (let i = 0; i < 10000; i++) deep = { unknown: deep };
  const m = manifest();
  m.unknown = deep;
  rejected(
    () => canonicalNativeManifest(m),
    "unknown_field",
    "$manifest.unknown",
  );
  delete m.files;
  rejected(
    () =>
      createNativePackage(m, [
        { path: "index.html", data: new Uint8Array([1]) },
      ]),
    "unknown_field",
    "$metadata.unknown",
  );
  let calls = 0;
  const wide: Record<string, unknown> = {};
  for (let i = 0; i < 10000; i++)
    Object.defineProperty(wide, `branch${i}`, {
      enumerable: true,
      get() {
        calls++;
        throw Error("unknown branch was visited");
      },
    });
  const w = manifest();
  w.unknown = wide;
  rejected(
    () => canonicalNativeManifest(w),
    "unknown_field",
    "$manifest.unknown",
  );
  assert.equal(calls, 0);
});

test("nested scalar objects and oversized declared collections reject before recursive snapshot", () => {
  let deep: unknown = null;
  for (let i = 0; i < 10000; i++) deep = { value: deep };
  const m = manifest("dictionary-ascii-forward");
  m.eventRules[0].source.parameters = { x: deep };
  rejected(
    () => canonicalNativeManifest(m),
    "schema",
    "$manifest.eventRules[0].source.parameters.x",
  );
  m.eventRules[0].source.parameters = Object.fromEntries(
    Array.from({ length: 33 }, (_, i) => [`p${i}`, deep]),
  );
  rejected(
    () => canonicalNativeManifest(m),
    "schema",
    "$manifest.eventRules[0].source.parameters",
  );
  const a = manifest();
  a.connections = Array(65);
  rejected(() => canonicalNativeManifest(a), "schema", "$manifest.connections");
  const unicode = manifest("dictionary-ascii-forward");
  unicode.eventRules[0].source.parameters = { value: "\ud800" };
  rejected(
    () => canonicalNativeManifest(unicode),
    "unicode",
    "$manifest.eventRules[0].source.parameters.value",
  );
});

test("deepest valid schema path, optional null projection and large allowed scalar data remain supported", () => {
  const m = manifest();
  m.connections = [
    {
      alias: "photos",
      required: true,
      publicHTTP: {
        origin: "https://images.example.org",
        userAgent: "Screenpunk/1",
        operations: [
          {
            name: "photo",
            path: "/photos/{filename}",
            response: "raster",
            parameters: {
              filename: {
                location: "path",
                minimum: null,
                maximum: null,
                values: null,
                pathSegment: { maxLength: 256 },
              },
            },
            maxAgeSeconds: 60,
            staleSeconds: 3600,
          },
        ],
      },
    },
  ];
  assert.match(canonicalNativeManifest(m), /"pathSegment":\{"maxLength":256\}/);
  const event = manifest("dictionary-ascii-forward");
  event.eventRules[0].source.parameters = Object.fromEntries(
    Array.from({ length: 32 }, (_, i) => [`p${i}`, "é".repeat(8192)]),
  );
  assert.match(canonicalNativeManifest(event), /"p31":/);
});

test("asset snapshots copy actual visible raw bytes without caller iterator or storage hooks", () => {
  const m = manifest();
  delete m.files;
  const buffer = Buffer.from([0, 97, 98, 0]);
  const bytes = buffer.subarray(1, 3);
  let calls = 0;
  Object.defineProperty(bytes, Symbol.iterator, {
    value: function* () {
      calls++;
      yield 99;
      yield 100;
      yield 101;
    },
  });
  for (const key of ["buffer", "byteOffset", "byteLength"])
    Object.defineProperty(bytes, key, {
      get() {
        calls++;
        throw Error("storage hook invoked");
      },
    });
  const result = createNativePackage(m, [{ path: "index.html", data: bytes }]);
  assert.equal(calls, 0);
  assert.deepEqual(result.assets[0].data, new Uint8Array([97, 98]));
  assert.equal(result.manifest.files[0].bytes, 2);
  assert.equal(
    result.manifest.files[0].sha256,
    createHash("sha256")
      .update(new Uint8Array([97, 98]))
      .digest("hex"),
  );
  buffer[1] = 122;
  assert.deepEqual(result.assets[0].data, new Uint8Array([97, 98]));
  rejected(
    () =>
      createNativePackage(m, [
        { path: "index.html", data: new Proxy(new Uint8Array([1]), {}) },
      ]),
    "representation",
    "$assets[0].data",
  );
});

test("asset list must contain plain indexed data without caller map/accessor hooks", () => {
  const m = manifest();
  delete m.files;
  let calls = 0;
  const list: any = [{ path: "index.html", data: new Uint8Array([1]) }];
  list.map = () => {
    calls++;
    throw Error("map hook invoked");
  };
  rejected(() => createNativePackage(m, list), "representation", "$assets");
  delete list.map;
  Object.defineProperty(list, "0", {
    enumerable: true,
    get() {
      calls++;
      throw Error("asset hook invoked");
    },
  });
  rejected(() => createNativePackage(m, list), "representation", "$assets[0]");
  assert.equal(calls, 0);
});
