# Native numeric and Unicode package observations

This separate follow-up uses unchanged public native source at
`859f9c2f492fea87ab64e49b3ea9037339e17478`. It does not modify the accepted
`native-package` oracle, SDK, schema, compiler, device or production behavior.

`CORPUS.json` contains 33 reproducible manifest observations and five direct
comparison probes. `COLLISIONS.json` contains two raw dictionary collision inputs
and their actually sampled native outcomes. Together they cover the eleven named
groups below. Each input uses fixed explicit manifest IDs. There is no random
revision or normalization. Inventory entries are synthetic one-byte metadata;
no assets or adversarial Unicode paths are written to disk. Pretty manifest bytes
are native re-encoding with the store's formatting flags, not a persisted store
file. Encoding a rejected manifest is never package acceptance.

`SOURCE.json` pins 75 accepted tracked files: 70 production/package/schema/SDK/
gallery inputs, plus the five accepted prior oracle files. It records exact Git
blob SHA1, SHA256, size and mode from immutable Git objects. Its SHA256 is pinned
in the new test. Ordinary verification checks this historical inventory, generator
and corpus provenance, and actual native observations. Only explicit export also
requires all 75 current files to match the historical source bytes. Unrelated
future production edits therefore do not automatically invalidate ordinary tests;
a behavior change still fails the frozen corpus comparison.

`PROVENANCE.json` records the source/corpus/collision/generator hashes, producer
Swift version, OS/build, architecture, timestamp, commands and qualification scope.
Keep the generated JSON bytes unchanged; do not format them.

## Reproduce and verify

Dependencies are local Controller/Core Swift packages. No dependency downloads,
services, compiler kit, application builds or device are required. From the
repository root, create an owned scratch directory and explicitly unset both
oracle export variables:

```sh
oracle_run_dir="$(mktemp -d /private/tmp/screenpunk-numeric-unicode.XXXXXX)"
mkdir -p "$oracle_run_dir/clang" "$oracle_run_dir/swift"
env -u SCREENPUNK_EXPORT_NUMERIC_UNICODE_ORACLE \
  -u SCREENPUNK_EXPORT_NATIVE_PACKAGE_ORACLE \
  CLANG_MODULE_CACHE_PATH="$oracle_run_dir/clang" \
  SWIFT_MODULECACHE_PATH="$oracle_run_dir/swift" \
  SWIFTPM_MODULECACHE_OVERRIDE="$oracle_run_dir/swift" \
  swift test --package-path packages/ScreenpunkController \
    --disable-sandbox --disable-automatic-resolution \
    --scratch-path "$oracle_run_dir/build" --cache-path "$oracle_run_dir/cache" \
    --filter PackageNumericUnicodeFixtureTests
```

The caller's sandbox remains in effect; `--disable-sandbox` avoids an unsupported
nested SwiftPM sandbox. Ordinary CI discovers this test and always executes the
native observations. It compares complete stable corpus bytes and checks each of
64 fresh decodes per collision input against the frozen sampled alternatives.
Missing, changed or newly observed bytes fail. There is no skipped verification.

Explicit export uses the same command with
`SCREENPUNK_EXPORT_NUMERIC_UNICODE_ORACLE="$oracle_run_dir/candidate"` assigned
instead of unsetting that variable. Keep the prior oracle export variable unset.
The destination must be absolute and **must not exist**. Existing directories are
refused, and committed files are never overwritten by export.

Export creates SOURCE, CORPUS, COLLISIONS and PROVENANCE candidate files, plus
`LOCAL-ONLY-collision-samples.json`, retaining all raw observed native outcomes.
Keep that sampling evidence in owned local storage; it is not committed fixture
data. Run another export into a different new directory in a fresh test process,
then compare SOURCE/CORPUS/COLLISIONS exactly. Producer timestamps in PROVENANCE
can differ. Review accepted source/toolchain changes and every changed observation
before explicitly copying a candidate. Rewriting checksums is not an update
procedure. Remove only owned scratch/cache directories after preserving evidence.

## Eleven groups and observed behavior

1. `dictionary-ascii-case-numeric-order`: forward/reversed raw member order;
   native JSON keys emit `10`, `2`, `A`, `_`, `a`. Direct member emission is needed
   in a future JS serializer; rebuilding a sorted object still enumerates numeric
   keys differently.
2. `dictionary-bmp-supplementary-order`: U+E000, U+FFFF, U+10000 and U+1F600
   forward/reversed. Native JSONEncoder emits that scalar order for this set.
   NSString literal comparison puts U+10000 before U+E000; it is not a substitute
   for the observed dictionary encoding.
3. `inventory-bmp-supplementary-order`: the same Unicode names in file arrays;
   unchanged Swift `<` emits the scalar order for this set. These non-ASCII paths
   are native metadata observations, outside the current ASCII manifest schema.
4. `dictionary-canonical-equivalent-single`: composed `é` versus decomposed
   `e`+U+0301, with a `z` anchor. Native JSONEncoder preserves spelling and emits
   `z` before composed `é`, but decomposed `e`+U+0301 before `z`.
5. `dictionary-canonical-equivalent-collision`: both equivalent spellings with
   distinct numeric values and opposite raw member order. Native decoding
   collapses them to one member. The sampled producer retained the first raw
   spelling/value in each direction: composed/1 forward, decomposed/2 reverse.
   All 64 samples per input in repeated fresh processes agreed. This is bounded
   evidence, not a promise that every Foundation/platform collision is stable or
   that the sampled alternative set is exhaustive. A new alternative fails
   ordinary verification and requires review. Do not fabricate a stable winner
   or apply a JS-object overwrite rule before observing the original JSON.
6. `inventory-canonical-equivalent-single-and-collision`: Swift file sorting
   places `Cafz.js` before both composed and decomposed accented paths, unlike
   raw dictionary-key ordering. Both equivalent paths together fail native
   validation with `duplicatePath`; their sorting tie preserves the input order
   in these observations. Arrays retain both spellings before validation.
7. `double-small-format-switch`: powers 1e-8 through 1e-3, adjacent binary64
   values around 1e-6/1e-4 and negatives. Observed output uses `1e-05`, whereas
   0.0001 is fixed; its lower neighbor stays scientific and upper neighbor fixed.
   One-digit signed exponents are padded in the native output. These token
   observations do not by themselves establish a universal formatting algorithm.
8. `double-large-format-switch`: powers 1e14 through 1e22, adjacent values
   around 1e16/1e21 and negatives. Native 1e15 emits a full integer token, while
   1e16 emits `1e+16`; the sampled lower neighbor of 1e16 is also scientific.
   JavaScript's general fixed/scientific switch differs, so exponent padding
   alone cannot implement native compatibility.
9. `double-zero-field-types`: Double parameter/condition/safe-area values retain
   negative-zero bit pattern `8000000000000000` and token `-0`; Int priority and
   publicHTTP staleSeconds decode raw `-0` to integer `0`. A field-aware codec is
   required. Negative-zero scale is observed separately from its schema rejection.
10. `double-rounding-range-edges`: decimal fractions, adjacent values at 1/2,
    least subnormal/normal and greatest finite Double, raw 2^53 boundary lexemes,
    1e400 and Int64 overflow. Raw 9007199254740993 and 9007199254740992 both decode
    to bits `4340000000000000`. 1e400 and 9223372036854775808 in an Int field fail
    decoding. The corpus records raw lexemes and actual resulting bits; it does
    not restore precision lost before a JS caller constructs its object.
11. `target-double-field-parity`: fractional scale 1.25 and safe-area top 0.5,
    neighboring scale limits, +/-zero and tiny positive/negative insets. All
    decoded target vectors pass this native manifest validator, including values
    outside strict schema ranges. This does not weaken schema: scale still must
    be >0 and <=8; safe-area values must be >=0 in the public/cloud schema.

Numeric batches contain at most 32 EventScalar parameters. Requested finite
Double inputs record Swift's raw input lexeme and exact 16-hex-digit binary64
bit pattern; the test asserts the native decoder preserved that requested value.
Explicit precision-loss/overflow raw lexemes have no invented expected bits.
Observed integers are stored as strings in sampling metadata to preserve the
distinction between native Int decoding and Double sign bits.

The comparison probes directly record Swift `==`/`<` and NSString default/literal
comparison. They do not infer JSONEncoder's implementation from those APIs.
Dictionary keys, file ordering and key identity therefore remain separate rules.

## Limits and next integration decision

This packet implements no JS serializer, SDK constructor, restriction policy,
package transport, private compiler or legacy digest migration. Rejecting
canonically equivalent duplicate keys may be appropriate for a new explicit
native constructor, but that is a later reviewed API decision; valid unique
Unicode keys must not be cut off simply to avoid comparator qualification.

The accepted prior oracle retains its 35 manifest vectors, four inventory probes
and default-gallery parser scope. This follow-up adds no ControllerService parser
or history evidence. Explicit-target coercion/safe-area replacement, empty-page
clearing, history inheritance, ZIP/device acceptance, rendering and hostile-source
containment remain unqualified. Numeric and comparator results are exact producer
observations; additional bounded differential tests are needed before claiming
arbitrary finite-Double or all-Unicode compatibility.
