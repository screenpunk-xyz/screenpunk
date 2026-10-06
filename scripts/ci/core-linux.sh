#!/usr/bin/env bash
# Portable ScreenpunkCore evidence on Linux: pairing, isolation, grants, offline
# recovery, unlink, and package validation run against the same fixture files
# the TypeScript SDK consumes. This is not Apple/WKWebView evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "core-linux.sh requires a Swift toolchain (swift.org Linux release or the swift:noble image)"
  exit 1
fi

echo "=== toolchain ==="
uname -a
swift --version

for fixture in \
  tests/feasibility/pairing/vectors.json \
  tests/feasibility/isolation/attacks.json \
  tests/adapters/vectors.json \
  schemas/fixtures/valid/connection-grant.json \
  schemas/fixtures/valid/connection-grant-ws.json \
  schemas/fixtures/valid/minimal.json \
  examples/offline-fixture/manifest.json
do
  test -f "$fixture" || { echo "missing shared fixture: $fixture"; exit 1; }
done

echo "=== ScreenpunkCore swift test (Linux) ==="
mkdir -p "$ROOT/.ci-derived"
log="$ROOT/.ci-derived/core-linux.log"
# This package currently uses generated XCTest discovery only. Fail closed if
# another framework or custom entry point is added instead of omitting its tests.
if grep -REq '(^|[[:space:]])import[[:space:]]+Testing([[:space:]]|$)|@(Test|Suite)([^[:alnum:]_]|$)' packages/ScreenpunkCore/Tests; then
  echo "direct XCTest runner requires review for Swift Testing tests"
  exit 1
else
  test_search_status=$?
  if (( test_search_status != 1 )); then
    echo "cannot inspect Core test sources"
    exit "$test_search_status"
  fi
fi
if custom_test_entries=$(find packages/ScreenpunkCore/Tests -type f \( -name LinuxMain.swift -o -name XCTestManifests.swift \) -print); then
  if [[ -n "$custom_test_entries" ]]; then
    echo "direct XCTest runner requires generated discovery, not a custom entry point"
    exit 1
  fi
else
  test_search_status=$?
  echo "cannot enumerate Core test entry points"
  exit "$test_search_status"
fi

# Run the full generated binary directly: SwiftPM's child output capture can
# stall before the suite finishes.
# Run the complete unfiltered XCTest suite in Release with testing enabled.
run_full_xctest() {
  cd packages/ScreenpunkCore || return $?
  swift build -c release --build-tests -Xswiftc -enable-testing || return $?
  test_bin_dir=$(swift build -c release --show-bin-path) || return $?
  test_binary="$test_bin_dir/ScreenpunkCorePackageTests.xctest"
  if [[ ! -f "$test_binary" || ! -x "$test_binary" ]]; then
    echo "missing generated ScreenpunkCore XCTest executable"
    return 1
  fi
  "$test_binary"
}
if (run_full_xctest) >"$log" 2>&1; then
  swift_status=0
else
  swift_status=$?
fi
tail -n 200 "$log"
if (( swift_status != 0 )); then
  echo "Core build or full XCTest run failed with exit status $swift_status"
  exit "$swift_status"
fi

if ! grep -qE "Executed [0-9]+ tests, with 0 failures" "$log"; then
  echo "swift test did not report a clean run"
  exit 1
fi

echo "core-linux ok"
echo "CryptoKit SAS vectors are Apple-only and are checked by apple-build-and-unit; TypeScript checks the same MACs here on Linux"
