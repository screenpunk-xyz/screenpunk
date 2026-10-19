# Native package byte oracle

These fixtures were emitted by the unchanged native models, `DeploymentDigest`,
`PackageValidator`, and `ControllerService` at public commit
`276c94b89ac7c6feb0e742116eaf2ebf55775240`. They are a native serialization and
manifest-validation oracle for a later shared SDK correction. They do not qualify
ZIP transfer, device acceptance, rendering, compilation, or untrusted source.
No production source, SDK implementation, schema, or iOS files changed.

`SOURCE.json` records 70 immutable Git blob identities, SHA256 hashes, byte sizes,
and modes covering the Controller/Core production Swift source and package
manifests, the public SDK package/limits source, wire schema, and gallery metadata.
Its digest is pinned in the new native test; changing inventory checksums cannot
silently approve changed historical provenance. Ordinary verification checks this
pinned historical inventory and recomputes every native observation against the
frozen corpus. It does not require unrelated current production files to remain
byte-identical to the historical snapshot. Explicit candidate export additionally
verifies all 70 current source bytes and Git blob hashes against that snapshot;
exporting from a new source snapshot requires explicit source review.

`CORPUS.json` contains 35 manifest vectors, four inventory-only boundary probes,
and one real controller gallery parser vector.
Each manifest vector records input UTF-8, small asset bytes/hashes, decode outcome,
exact native validation issues, canonical UTF-8, native deployment digest, sorted
inventory UTF-8, and manifest UTF-8 in the native persisted writer's format when
encoding succeeds. Rejected vectors can encode successfully; those bytes are
observations, not accepted or published packages. The tiny assets are synthetic
package inputs, **not compiled gallery output or dependency/license evidence**.
The gallery name and parser input come from the accepted gallery `screen.json`.

`PROVENANCE.json` records the exact corpus/generator/source hashes, Swift toolchain,
OS/build, architecture, generation time, source verification policy, normalization
and qualification limits.
Preserve these raw generated files; do not pass them through a formatter.

## Ordinary verification

From the repository root, create an owned directory and run the focused native
test. All package dependencies are local (`ScreenpunkController` →
`ScreenpunkCore`); automatic dependency resolution is disabled.

```sh
oracle_run_dir="$(mktemp -d /private/tmp/screenpunk-package-oracle.XXXXXX)"
mkdir -p "$oracle_run_dir/clang" "$oracle_run_dir/swift"
env -u SCREENPUNK_EXPORT_NATIVE_PACKAGE_ORACLE \
CLANG_MODULE_CACHE_PATH="$oracle_run_dir/clang" \
SWIFT_MODULECACHE_PATH="$oracle_run_dir/swift" \
SWIFTPM_MODULECACHE_OVERRIDE="$oracle_run_dir/swift" \
swift test --package-path packages/ScreenpunkController \
  --disable-sandbox --disable-automatic-resolution \
  --scratch-path "$oracle_run_dir/build" --cache-path "$oracle_run_dir/cache" \
  --filter PackageCompatibilityFixtureTests
```

`--disable-sandbox` avoids SwiftPM's nested macOS sandbox when the caller is
already sandboxed. Scratch/module caches remain in the owned directory. Ordinary
CI discovers this XCTest automatically and recomputes native observations,
compares every frozen corpus byte, verifies provenance, historical source inventory
and generator integrity, and
fails for missing or changed fixtures. It does not skip fixture verification or
regenerate committed files. Historical producer toolchain metadata is retained;
new toolchains must reproduce the bytes or trigger review.

## Explicit candidate export

Only setting `SCREENPUNK_EXPORT_NATIVE_PACKAGE_ORACLE` enables export. It must be
an absolute **new** output directory; existing directories are rejected. Run the
same command above with this additional environment assignment:

```sh
CLANG_MODULE_CACHE_PATH="$oracle_run_dir/clang" \
SWIFT_MODULECACHE_PATH="$oracle_run_dir/swift" \
SWIFTPM_MODULECACHE_OVERRIDE="$oracle_run_dir/swift" \
SCREENPUNK_EXPORT_NATIVE_PACKAGE_ORACLE="$oracle_run_dir/candidate" \
swift test --package-path packages/ScreenpunkController \
  --disable-sandbox --disable-automatic-resolution \
  --scratch-path "$oracle_run_dir/build" --cache-path "$oracle_run_dir/cache" \
  --filter PackageCompatibilityFixtureTests
```

The public candidate files are `SOURCE.json`, `CORPUS.json`, and `PROVENANCE.json`.
Export also retains two `LOCAL-ONLY-native-parser-*.json` evidence files with the
actual unmodified random-revision persisted manifest and its hash. Keep those in
owned local evidence only; never copy them into the committed corpus. The test first
checks all 70 current production files against the pinned historical source and
exercises all native observations. A reviewer compares
the candidate corpus byte-for-byte against the frozen corpus; candidate provenance
will record a new timestamp/platform. No committed file is replaced automatically.
After review, explicitly copy only the accepted raw candidate files. Rewriting a
checksum to match an edited fixture is not an update procedure. Remove only the
owned scratch/cache/export directory when its evidence is no longer needed.

## Recorded semantics and remaining disagreements

- Nested input key permutations produce the same native canonical bytes. Numeric
  dictionary keys encode lexically (`"10"` before `"2"`); ASCII inventory ordering
  is `A.js`, `_.js`, `a.js`. JavaScript property enumeration and `localeCompare`
  cannot be substituted for these observations.
- Composed and decomposed Unicode names preserve different UTF-8 and digests.
  Supplementary characters, dictionary key ordering, slash/quote/backslash,
  newline/tab and U+2028/U+2029 escaping are recorded as actual native bytes.
- Optional null decodes to absence and canonical omission. Empty behavior and
  explicit `audio.autoplay: false` stay distinct. Empty pages fail native semantic
  validation; invalid audio null and required-name null fail decoding.
- Native Double encoding includes integer/fraction/precision/exponent vectors,
  `1e-07` and `-0`. Input `9007199254740993` rounds to native Double
  `9007199254740992`; the fixture records that loss, not an endorsement of a future
  unrestricted numeric interface. JSON `1e400` fails decoding. Non-JSON programmatic
  values are not part of this bounded corpus.
- The real controller parser resolves omitted target to its native fixture target.
  Explicit target coercion and safe-area replacement remain source-grounded risks
  outside this first gallery parser vector; a future adapter must qualify them.
- Controller storage generates a random revision. The test first verifies the
  **actual unmodified persisted file** against the native writer. It then sets
  only the exported typed record's revision to the explicit fixture UUID and
  recomputes its digest through `DeploymentDigest`. Exported parser canonical and
  pretty bytes are **normalized native re-encoding**, not the original persisted
  file; this normalization is explicit in provenance. No store lifecycle or
  production generator is modified.
- Native `PackageValidator` accepts zero-length assets, `foo..bar`, empty/dot path
  components and NFD paths; the SDK/schema/cloud intersection is narrower. Actual
  traversal and encoded traversal reject. No paths are materialized from those
  adversarial vectors; only the fixed safe parser assets are stored temporarily.
- Metadata-only probes accept exactly 2,000 assets and 50 MiB declared expanded
  bytes, and reject the next count/byte. They allocate no 50 MiB payload and do not
  claim file-hash, archive or device validation. Native inventory excludes
  `manifest.json`; cloud ZIP counting/expanded bytes include it. The compressed
  25 MiB transport limit and this counting disagreement remain outside this packet.
- Native manifest checks are weaker/different in places than strict JSON Schema
  and SDK checks. Freeze these observations; do not weaken schema or advertise
  broad package acceptance to make the runtimes agree. The next shared/public
  semantics change must consume this oracle and qualify its explicit intersection.

There is no native ZIP exporter in the inspected package path. Compatibility must
compare logical entries, native manifest/digest bytes, limits and native acceptance;
it must not demand native ZIP byte equality. No shared SDK correction, private
package adapter, archive writer or production containment is implemented here.
