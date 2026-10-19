# Native package construction

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../../docs/screen-authoring-persistence.md).


`@screenpunk/sdk/native-package` is an additive **Node-only** entry point. Its
`NATIVE_PACKAGE_PROFILE` is `screenpunk-native-manifest-v1`. The profile identifier
travels beside the package; it is not an extra manifest field and does not enter
the deployment digest. The existing SDK package helpers, browser entry point,
examples and historical package digests retain their existing behavior. Consumers
must select a profile explicitly, never try both digest algorithms or infer a
profile from a successful hash comparison.

```ts
import {
  createNativePackage,
  NATIVE_PACKAGE_PROFILE,
} from "@screenpunk/sdk/native-package";

const result = createNativePackage(
  {
    schemaVersion: 1,
    sdkVersion: "1",
    dashboardId: "11111111-1111-4111-8111-111111111111",
    revision: "22222222-2222-4222-8222-222222222222",
    name: "My screen",
    entrypoint: "index.html",
    target: {
      profileId: "resolved-phone-profile",
      width: 390,
      height: 844,
      scale: 3,
      orientation: "portrait",
    },
    connections: [],
  },
  [{ path: "index.html", data: new TextEncoder().encode("<p>Hello</p>") }],
);
if (result.profile !== NATIVE_PACKAGE_PROFILE) throw new Error("wrong profile");
```

The caller supplies explicit resolved target, IDs, revision and declarations.
The constructor chooses no target, generates no revision, installs nothing and
does not compile, access files, provision providers, render, publish or make a ZIP.
It snapshots the actual visible `Uint8Array`/Buffer storage through captured
typed-array intrinsics, without consulting a caller's iterator or shadowed
buffer/offset/length getters, computes each SHA-256/size, sorts the
inventory, projects native optional properties, and returns the native canonical
JSON/digest plus the persisted pretty `manifestJSON`. No trailing newline is
added. Input `files` or `digest` is an error, even if undefined; those are computed.

The result, manifest, arrays and asset wrappers are frozen. Every `asset.data`
read returns a fresh copy of the retained snapshot. Mutating an input or returned
copy cannot change the retained package. A transport must snapshot and reverify
the bytes it actually writes, check logical entries, limits and its declared
profile, and issue its own qualified result. This assembly object is not proof of
archive import, device delivery, rendering or hostile-source containment.

## Input intersection

The output satisfies the pinned public dashboard-manifest v1 schema and the
implemented native package validation relations. The schema assertions are kept
in a dependency-free projection and compared against the authoritative schema in
tests. The API accepts plain structured data, not raw JSON text: objects with data
properties, dense arrays, valid Unicode strings, booleans, null scalars and finite
numbers. Accessors, `toJSON` hooks, custom object prototypes, symbols, cycles,
unpaired UTF-16 surrogates and shared byte buffers are rejected. This is data
validation, not an isolation boundary for hostile JavaScript objects or proxies.
It cannot recover a duplicate key or an original numeric lexeme already lost by
a caller's JSON parser or arithmetic.

Snapshots follow the schema before recursing: unknown fields and object-valued
scalars fail immediately; declared array/dictionary bounds apply before visiting
members. Valid schema paths have a fixed maximum depth, without an arbitrary
small node or scalar cap. Callers handling serialized input must bound their parse
and encoded-data work by the existing 50 MiB package envelope before invoking
these structured APIs; metadata-only canonicalization is not a raw-input parser
or a hostile-object work/memory sandbox. Construction checks the exact final
persisted-manifest plus asset envelope separately.

- Unknown fields fail with their field path. Required native fields are never
  synthesized from Swift initializer defaults. Only declared optional Codable
  properties project null/undefined to absence. Required EventScalar null remains
  null; empty optional objects/arrays and explicit false remain present when the
  schema permits them. Empty `pages` is rejected by the schema.
- File/entrypoint/page paths retain exact spelling. Their ASCII restriction comes
  from the existing v1 schema. Additional transport identity checks reject empty
  or dot segments and control characters; paths are never normalized in a digest.
  Native-only Unicode paths, embedded `..` names and zero-byte inventory records
  are outside this profile. Asset `manifest.json` is reserved for the computed
  manifest. Unicode content, names and dictionary keys remain supported.
- Canonically equivalent dictionary keys, such as `é` and `e\u0301`, are rejected
  together before native decoding can collapse their identities. Single keys keep
  their raw spelling. JSON dictionary sorting compares raw Unicode scalars/UTF-8;
  inventory sorting uses NFC scalar comparison, matching Swift `String.<`. These
  are different comparisons. No locale sorting, UTF-16 ordering, integer-key
  enumeration ordering or key normalization is used for JSON encoding.
- Public HTTP, service, camera, navigation and device declarations retain native
  relations: unique connection identities, at most eight public HTTP connections,
  public origins, declaration exclusivity, known pages/operations, required
  conditions, bounded leases and native service permissions. Validation is not
  provider authorization or DNS/egress enforcement.
- At most 2000 nonempty assets are accepted. Aggregate **asset inventory** is
  bounded by 50 MiB. Construction further requires assets **plus the exact UTF-8
  persisted `manifest.json`** to fit in 50 MiB; `expandedBytes` reports that total.
  Metadata-only canonicalization checks the inventory budget, not an archive.
  ZIP compression, extra entries, headers and compressed limits are transport
  concerns; adding another entry consumes additional expanded budget.

`canonicalNativeManifest` and `nativeDeploymentDigest` validate an explicitly
supplied inventory and compute its native identity; they do not read or verify
asset bytes or validate a supplied digest against its history. A well-formed
optional digest is omitted from canonical input, as native `DeploymentDigest`
does. Use the constructor when hashes must be computed from bytes.

## Numbers and compatibility

Every native Int field requires a safe JavaScript integer. This includes schema
major, target width/height, inventory sizes, declaration max-age/staleness,
public parameter minimum/maximum/path-segment length, poll interval, priority,
timeouts and lease duration. The existing schema ranges still apply: for example
target dimensions 1…10000, priority −100…100 and timeouts 1…3600. Generic operation
`maxAgeSeconds` has no schema maximum, but values above `Number.MAX_SAFE_INTEGER`
are rejected instead of claiming exact native Int identity. Legacy helpers are
not changed to apply this new restriction.

Native Double fields are target scale, every safe-area edge, event source
parameter numbers and filter/condition `equals` numbers. They accept every finite
binary64 value where the schema permits it: scale must be >0 and ≤8, safe-area
edges ≥0, and event scalars have no magnitude cap. Double negative zero remains
`-0`; Int negative zero projects to `0`. Infinity and NaN fail. A structured
JavaScript number denotes its actual binary64 value, not a promise that a prior
decimal string or unsafe integer arithmetic was lossless.

The formatter searches the exact binary64 rounding interval using BigInt. It
chooses the fewest significant decimal digits, the nearest candidate, and an even
last digit on an exact tie. This follows [Swift 6.3.3's published formatter
policy](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/stdlib/public/core/FloatingPointToString.swift).
Notation follows the implementation: an output exponent below −4 or a magnitude
strictly above `2^53` uses exponent notation, with a sign and at least two exponent
digits. Exactly `2^53` stays fixed. The source's overview mentions `2^54`; its
exponent-bias/branch code and actual native observations establish `2^53`.

[Foundation's encoder](https://github.com/swiftlang/swift-foundation/blob/a211bea22b6fa5b041c37592aaf50c7b3db5c354/Sources/FoundationEssentials/JSON/JSONEncoder.swift)
uses the floating-point description and removes a final `.0`.
[Its writer](https://github.com/swiftlang/swift-foundation/blob/a211bea22b6fa5b041c37592aaf50c7b3db5c354/Sources/FoundationEssentials/JSON/JSONWriter.swift)
documents raw UTF-8 key sorting, with a historical compatibility branch; this
upstream revision is explanatory source, not a claim that it identifies Apple's
shipped binary. Swift's [String comparator](https://github.com/swiftlang/swift/blob/064859e41d68596f486c5d724401cb370f260409/stdlib/public/core/StringComparison.swift)
uses NFC comparison. The implementation does not assume JavaScript's shortest
decimal tie policy: [ECMAScript recommends nearest/ties-even only in a
note](https://tc39.es/ecma262/2023/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-tostring).

## Qualification and migration

The frozen native corpus is the byte oracle. Tests cover all 35 initial manifest
vectors, all 33 numeric/Unicode observations, native numeric bit patterns,
dictionary collision permutations and the normalized resolved gallery parser
result. Supported cases compare canonical/digest bytes; the constructor compares
native persisted pretty manifests and asset inventories. Native-only/schema-only
or invalid cases have explicit rejection expectations. The raw native random
revision evidence remains in the original corpus provenance; the normalized
gallery vector is not represented as unmodified random output.

These vectors do not cover explicit-target/history parser branches or archive,
compiler, provider, rendering and device paths. Native optional projection and
numeric encoding are model semantics; they do not implement authoring argument
parsing. New Swift/Foundation or Unicode normalization versions require renewed
differential qualification, including boundary/tie and canonical-equivalence
cases. Finite sampling is evidence, not an exhaustive proof across every runtime.

The current native oracle was produced on **macOS 26.6.2 with Swift 6.3.3**.
SDK qualification uses Node 24.11.1 (V8 13.6, ICU 77.1, Unicode 16.0); the exact
normalization-table version in Apple's shipped Swift/Foundation is not identified.
Unicode normalization stability applies to the shared assigned repertoire, not
arbitrary characters introduced in later versions. The tested runtime/corpus
scope must remain explicit. **Older supported iOS/iPadOS Foundation reencoding
is unqualified**, including older iPads. Native delivery must wait for that
runtime matrix or an explicitly shared native canonical profile if differences
appear. Matching this macOS oracle does not establish older-device compatibility.

Run `npm ci --ignore-scripts` from `sdk`, then explicitly run `npm test` and
`npm run build` using the lockfile. The browser bundle remains unchanged and does
not import this module. Future private orchestration supplies resolved metadata
and assets and handles ZIP transport only. Legacy records retain their original
validator profile and digest; explicit conversion creates a new immutable native
package/revision. This entry point enables no private cloud import or delivery
path automatically.

## Capturing authored source metadata

The Node-only `captureNativeSourceMetadata(sourceJSON, identity)` export on
`@screenpunk/sdk/native-package` captures an explicit construction snapshot before
compilation. It returns deeply frozen `metadata`, its native `canonicalJSON` and
SHA256 `sha256`, plus `sourceSha256` over the exact supplied bytes. It does not
produce a manifest, invent an asset inventory, inherit a previous revision, or
approve a device or permission. Use `createNativePackage(result.metadata, assets)`
with real compiled assets to check entrypoint/page existence and compute the
finished manifest and digest.

`sourceJSON` is a synchronously copied `Uint8Array` (including a Buffer slice),
limited to 5 MiB. Intrinsic storage reads ignore caller accessors and iterators;
proxy views and shared backing storage are rejected. Decode is fatal UTF-8, with
no BOM stripping: a UTF-8 BOM is rejected. The source document must have `name`
and `connections`; optional fields are `target`, `pages`, `defaultPageId`,
`eventRules`, and `deviceBehavior`. Unknown and computed fields are rejected.
Omitted or null optional Codable fields project to absence, without defaults or
inheritance. Explicit empty values remain subject to the existing native schema
and semantic validation. `screenpunk-screen.json` is a separate asset; this API
does not infer or copy it.

`NativeConstructionIdentity` explicitly supplies schemaVersion 1, dashboardId
and revision UUIDs, sdkVersion `"1"`, `entrypoint: "index.html"`, and the resolved
native target. A supplied source target must match the target's native canonical
projection exactly. No fixture target, connection, or permission is synthesized.
The header is copied through the same schema-directed data-property snapshot;
accessors, proxies, unknown keys, and unsupported representations are rejected.

The strict JSON decoder detects duplicate **decoded** object keys, including
escaped aliases, before either value could be overwritten. Existing native
projection also rejects ambiguous NFC-equivalent dictionary keys and unpaired
surrogates. The parser follows the derived manifest schema: unknown branches and
unexpected scalar containers are rejected without recursive traversal, collection
bounds apply while decoding, and a defensive nesting ceiling of 32 exceeds the
current finite schema depth. The 5 MiB byte ceiling bounds tokens and total work.
Numbers use finite binary64 representation for Double fields, preserving negative
zero. Int fields additionally require the original decimal lexeme to be an exact
mathematical integer in the safe JavaScript integer range: a rounded token such
as `1.0000000000000001` is rejected. There is no string/boolean/number coercion.

Canonical metadata reuses the existing native JSON serializer and schema-derived
Int paths. Its hash is distinct from the raw source hash: optional null omission,
JSON whitespace, and equivalent number spellings can yield identical projected
metadata but different source bytes. Store the exact source snapshot/hash as well
as the canonical construction snapshot/hash; JSONB or `JSON.stringify` is not a
lossless canonical identity. For a durable build, resolve/allocate its identity
once before construction and recover that same identity on retry. Caller intent
hashes should not include newly allocated server IDs. This API does not implement
that persistence or authorization policy, and old records missing a snapshot must
not reconstruct it from a mutable project/head during publication.

This additive boundary does not change the Mac controller's old source parser,
fallbacks, or inheritance behavior. The native canonical profile remains qualified
only within the Foundation/toolchain scope described above, not on every supported
older iOS/iPadOS release.
