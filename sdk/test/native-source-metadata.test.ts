import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  captureNativeSourceMetadata,
  createNativePackage,
  NativePackageError,
  type NativeConstructionIdentity,
  type NativePackageMetadata,
} from "../src/native-package.js";
import { integerField } from "../src/native-package-domain.js";
import { nativeJSON } from "../src/native-package-json.js";

const encode = (text: string) => new TextEncoder().encode(text);
const identity = (): NativeConstructionIdentity => ({
  schemaVersion: 1,
  dashboardId: "11111111-1111-4111-8111-111111111111",
  revision: "22222222-2222-4222-8222-222222222222",
  entrypoint: "index.html",
  sdkVersion: "1",
  target: {
    profileId: "fixture-phone",
    width: 390,
    height: 844,
    scale: 3,
    orientation: "portrait",
    safeArea: { top: 47, right: 0, bottom: 34, left: 0 },
  },
});
const base = '{"name":"Example","connections":[]}';
const capture = (text = base, id = identity()) =>
  captureNativeSourceMetadata(encode(text), id);
const rejects = (fn: () => unknown, code?: string) =>
  assert.throws(
    fn,
    (e: unknown) =>
      e instanceof NativePackageError &&
      (code === undefined || e.code === code),
  );
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");

test("metadata is explicit, immutable and canonical-equivalent to real package construction", () => {
  const raw = encode(base),
    id = identity();
  const result = captureNativeSourceMetadata(raw, id);
  const pkg = createNativePackage(result.metadata as NativePackageMetadata, [
    { path: "index.html", data: encode("<h1>Hello</h1>") },
  ]);
  const { files, digest: _digest, ...metadata } = pkg.manifest;
  assert.equal(result.canonicalJSON, nativeJSON(metadata, integerField));
  assert.equal(result.sha256, digest(result.canonicalJSON));
  assert.equal(result.sourceSha256, digest(raw));
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.metadata.target));
  raw.fill(0);
  id.target.width = 1;
  assert.equal(result.metadata.target.width, 390);
  assert.equal(result.metadata.name, "Example");
  assert.equal(result.metadata.revision, identity().revision);
  assert.throws(() => {
    (result.metadata.connections as unknown[]).push({});
  }, TypeError);
});

test("strict syntax, fatal UTF8 and duplicate decoded keys cannot silently lose data", () => {
  for (const text of [
    '{"name":"A","name":"B","connections":[]}',
    '{"name":"A","na\\u006de":"B","connections":[]}',
    '{"name":"A","connections":[],"target":{"width":1,"width":2}}',
  ])
    rejects(() => capture(text), "duplicate_key");
  for (const text of [
    base + "null",
    base.replace("[]", "[,]"),
    base.replace("[]", "[{} ,]"),
    "\ufeff" + base,
    '{"name":"A" "connections":[]}',
    '{"name":"\\x41","connections":[]}',
  ])
    rejects(() => capture(text));
  rejects(
    () => captureNativeSourceMetadata(new Uint8Array([0xc3, 0x28]), identity()),
    "utf8",
  );
  rejects(() => capture('{"name":"\\ud800","connections":[]}'), "unicode");
  rejects(
    () =>
      capture('{"name":"A","connections":[],"unknown":' + "[".repeat(10000)),
    "unknown_field",
  );
});

test("Int fields reject rounded decimal aliases, unsafe integers and huge exponents", () => {
  for (const token of [
    "1.0000000000000001",
    "1e-9999999",
    "9007199254740993",
    "1e99999",
    "0.99999999999999999",
  ])
    rejects(() =>
      capture(
        `{"name":"A","connections":[{"alias":"home","required":false,"operations":[{"name":"read","kind":"http","maxAgeSeconds":${token}}]}]}`,
      ),
    );
  for (const token of ["1.0000", "10e-1", "1e0"])
    assert.equal(
      capture(
        `{"name":"A","connections":[{"alias":"home","required":false,"operations":[{"name":"read","kind":"http","maxAgeSeconds":${token}}]}]}`,
      ).metadata.connections[0].operations![0].maxAgeSeconds,
      1,
    );
  rejects(
    () =>
      capture(
        '{"name":"A","connections":[],"target":{"profileId":"x","width":390.000000000000001,"height":844,"scale":3,"orientation":"portrait"}}',
      ),
    "lossy_integer",
  );
});

test("Double negative zero, Unicode and optional nil semantics use accepted projection", () => {
  const id = identity();
  id.target.safeArea!.left = -0;
  const result = capture(
    '{"name":"😀 é / \\u2028","connections":[],"pages":null,"eventRules":null,"deviceBehavior":{},"target":null}',
    id,
  );
  assert.ok(Object.is(result.metadata.target.safeArea!.left, -0));
  assert.match(result.canonicalJSON, /"left":-0/);
  assert.equal(result.metadata.pages, undefined);
  assert.equal(result.metadata.eventRules, undefined);
  assert.deepEqual(Object.keys(result.metadata.deviceBehavior!), []);
  const omitted = capture('{"name":"A","connections":[]}');
  const nil = capture('{"name":"A","connections":[],"pages":null}');
  assert.equal(omitted.canonicalJSON, nil.canonicalJSON);
  assert.notEqual(omitted.sourceSha256, nil.sourceSha256);
  rejects(() => capture('{"name":"A","connections":[],"pages":[]}'));
  rejects(
    () =>
      capture(
        '{"name":"A","connections":[],"target":{"profileId":"fixture-phone","width":390,"height":844,"scale":3,"orientation":"portrait"}}',
      ),
    "target_mismatch",
  );
  const target = nativeJSON(id.target, (path) =>
    integerField(["target", ...path]),
  );
  assert.equal(
    capture(`{"name":"A","connections":[],"target":${target}}`, id).metadata
      .target.width,
    390,
  );
});

test("source cannot set computed identity fields or synthesize declarations", () => {
  for (const key of [
    "dashboardId",
    "revision",
    "entrypoint",
    "sdkVersion",
    "schemaVersion",
    "files",
    "digest",
  ])
    rejects(
      () => capture(`{"name":"A","connections":[],"${key}":null}`),
      "unknown_field",
    );
  rejects(() => capture('{"name":"A"}'), "required_field");
  rejects(() => capture('{"connections":[]}'), "required_field");
  rejects(
    () => capture('{"name":"A","connections":[{"alias":"home"}]}'),
    "required_field",
  );
  rejects(() =>
    capture(base, {
      ...identity(),
      entrypoint: "other.html",
    } as NativeConstructionIdentity),
  );
  rejects(() =>
    capture(base, {
      ...identity(),
      sdkVersion: "2",
    } as unknown as NativeConstructionIdentity),
  );
  rejects(() =>
    capture(base, {
      ...identity(),
      inherited: true,
    } as NativeConstructionIdentity),
  );
});

test("intrinsic visible bytes bypass hooks; shared and proxy inputs fail clearly", () => {
  let calls = 0;
  const bytes = Buffer.from("prefix" + base + "suffix").subarray(
    6,
    6 + base.length,
  );
  Object.defineProperty(bytes, "buffer", {
    get() {
      calls++;
      throw Error("hook");
    },
  });
  Object.defineProperty(bytes, "byteLength", {
    get() {
      calls++;
      throw Error("hook");
    },
  });
  Object.defineProperty(bytes, Symbol.iterator, {
    value() {
      calls++;
      throw Error("hook");
    },
  });
  assert.equal(
    captureNativeSourceMetadata(bytes, identity()).metadata.name,
    "Example",
  );
  assert.equal(calls, 0);
  rejects(
    () => captureNativeSourceMetadata(new Proxy(encode(base), {}), identity()),
    "representation",
  );
  rejects(
    () =>
      captureNativeSourceMetadata(
        new Uint8Array(new SharedArrayBuffer(16)),
        identity(),
      ),
    "representation",
  );
  rejects(
    () =>
      captureNativeSourceMetadata(
        new Uint16Array(16) as unknown as Uint8Array,
        identity(),
      ),
    "representation",
  );
  const id = identity();
  Object.defineProperty(id.target, "width", {
    enumerable: true,
    get() {
      calls++;
      return 390;
    },
  });
  rejects(() => capture(base, id), "representation");
  rejects(() => capture(base, new Proxy(identity(), {})), "representation");
  const nested = identity();
  nested.target = new Proxy(nested.target, {});
  rejects(() => capture(base, nested), "representation");
  assert.equal(calls, 0);
});

test("schema bounds reject malformed branch depth and collections before traversal", () => {
  rejects(() => capture(" ".repeat(5 * 1024 * 1024) + base), "size_limit");
  rejects(
    () => capture('{"name":"' + "x".repeat(129) + '","connections":[]}'),
    "schema",
  );
  rejects(
    () =>
      capture(
        '{"name":"A","connections":[' +
          Array(65).fill('{"alias":"home","required":false}').join(",") +
          "]}",
      ),
    "schema",
  );
  rejects(() =>
    capture(
      '{"name":' +
        "[".repeat(10000) +
        "0" +
        "]".repeat(10000) +
        ',"connections":[]}',
    ),
  );
  // Full collection budget is supported; no caller-wide ASCII cap.
  const declarations = Array.from({ length: 64 }, (_, i) => ({
    alias: `c${i}`,
    required: false,
  }));
  assert.equal(
    capture(
      JSON.stringify({ name: "😀".repeat(128), connections: declarations }),
    ).metadata.connections.length,
    64,
  );
});

test("accepted native metadata observations retain inventory-independent semantics", (t) => {
  const load = (p: string) =>
    JSON.parse(readFileSync(new URL(p, import.meta.url), "utf8"));
  const corpus = [
    ...load("./fixtures/native-package/CORPUS.json").cases,
    ...load("./fixtures/native-package-numeric-unicode/CORPUS.json")
      .observations,
  ];
  let accepted = 0;
  for (const item of corpus) {
    if (!item.canonicalUTF8) continue;
    const full = JSON.parse(
      item.inputManifestUTF8 ?? item.rawInputManifestUTF8 ?? item.canonicalUTF8,
    );
    // First establish the existing public constructor accepts this observation.
    const assets = item.assets?.map((a: { path: string; base64: string }) => ({
      path: a.path,
      data: Buffer.from(a.base64, "base64"),
    }));
    if (!assets?.length) continue;
    const { files: _files, digest: _digest, ...meta } = full;
    let pkg;
    try {
      pkg = createNativePackage(meta, assets);
    } catch (e) {
      if (e instanceof NativePackageError) continue;
      throw e;
    }
    if (pkg.manifest.entrypoint !== "index.html") continue;
    const {
      schemaVersion,
      dashboardId,
      revision,
      entrypoint,
      sdkVersion,
      target,
      ...source
    } = meta;
    const result = capture(nativeJSON(source, integerField), {
      schemaVersion,
      dashboardId,
      revision,
      entrypoint,
      sdkVersion,
      target,
    });
    const { files: _computed, digest: _actual, ...expected } = pkg.manifest;
    assert.equal(
      result.canonicalJSON,
      nativeJSON(expected, integerField),
      item.id,
    );
    accepted++;
  }
  assert.ok(
    accepted >= 20,
    `actual constructor observations compared: ${accepted}`,
  );
  t.diagnostic(
    `actual accepted constructor observations compared: ${accepted}`,
  );
});

test("real page inventory is checked only when real assets are supplied", () => {
  const result = capture(
    '{"name":"A","connections":[],"pages":[{"id":"main","name":"Main","path":"next.html"}]}',
  );
  assert.equal(result.metadata.pages![0].path, "next.html");
  rejects(
    () =>
      createNativePackage(result.metadata as NativePackageMetadata, [
        { path: "index.html", data: encode("<h1>A</h1>") },
      ]),
    "native_validation",
  );
  assert.equal(
    createNativePackage(result.metadata as NativePackageMetadata, [
      { path: "index.html", data: encode("<h1>A</h1>") },
      { path: "next.html", data: encode("<h1>B</h1>") },
    ]).manifest.pages![0].path,
    "next.html",
  );
});

test("EventScalar dictionary identity and deepest approved declarations are preserved", () => {
  const numeric = JSON.parse(
    readFileSync(
      new URL(
        "./fixtures/native-package-numeric-unicode/CORPUS.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const row = numeric.observations.find(
    (r: { id: string }) => r.id === "dictionary-ascii-forward",
  );
  const full = JSON.parse(row.inputManifestUTF8 ?? row.canonicalUTF8);
  const {
    schemaVersion,
    dashboardId,
    revision,
    entrypoint,
    sdkVersion,
    target,
    files: _files,
    digest: _digest,
    ...source
  } = full;
  const id = {
    schemaVersion,
    dashboardId,
    revision,
    entrypoint,
    sdkVersion,
    target,
  };
  source.eventRules[0].source.parameters = {
    é: -0,
    supplementary: "😀",
    nullable: null,
    explicitFalse: false,
    tiny: Number.MIN_VALUE,
    largest: Number.MAX_VALUE,
  };
  const good = capture(nativeJSON(source, integerField), id);
  assert.ok(Object.is(good.metadata.eventRules![0].source.parameters["é"], -0));
  assert.match(good.canonicalJSON, /"tiny":5e-324/);
  source.eventRules[0].source.parameters = { é: 1, "e\u0301": 2 };
  rejects(() => capture(nativeJSON(source, integerField), id), "ambiguous_key");
  source.eventRules[0].source.parameters = { value: { nested: [] } };
  rejects(() => capture(JSON.stringify(source), id));
  const deep = {
    name: "A",
    connections: [
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
    ],
    deviceBehavior: { audio: { autoplay: false } },
  };
  const result = capture(JSON.stringify(deep));
  assert.equal(
    result.metadata.connections[0].publicHTTP!.operations[0].parameters.filename
      .pathSegment!.maxLength,
    256,
  );
  assert.equal(result.metadata.deviceBehavior!.audio!.autoplay, false);
});
