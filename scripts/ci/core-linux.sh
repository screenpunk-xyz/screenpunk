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
# Observe only the regular log; never pipe or signal the Core runner.
core_observer_directory=$(mktemp -d "$ROOT/.ci-derived/core-observer.XXXXXX")
core_observer_started=$SECONDS
stop_core_observer() {
  if ! : >"$core_observer_directory/stop"; then
    echo "CORE_PROGRESS observer stop flag unavailable"
    # This is our unreaped observer child, never an inferred runner PID.
    kill "$core_observer_pid" 2>/dev/null || :
  fi
  if wait "$core_observer_pid"; then
    :
  else
    echo "CORE_PROGRESS observer unavailable"
  fi
  rm -f "$core_observer_directory/stop" || echo "CORE_PROGRESS stop flag cleanup unavailable"
  rmdir "$core_observer_directory" || echo "CORE_PROGRESS observer directory cleanup unavailable"
}
core_observer_exit() {
  core_observer_exit_status=$?
  stop_core_observer
  trap - EXIT
  exit "$core_observer_exit_status"
}
: >"$log"
(
  while [[ ! -f "$core_observer_directory/stop" ]]; do
    for (( core_observer_tick=0; core_observer_tick<12; core_observer_tick++ )); do
      sleep 5
      if [[ -f "$core_observer_directory/stop" ]]; then exit 0; fi
    done
    if core_observer_bytes=$(wc -c <"$log") &&
       core_observer_marker=$(tail -n 40 "$log" | awk '/^PROMOTION_LOCALIZATION capacity\.operation\.[0-9]+\.(begin|end)$/ { marker=$0 } END { print marker }'); then
      core_observer_bytes="${core_observer_bytes//[[:space:]]/}"
      echo "CORE_PROGRESS elapsed_seconds=$((SECONDS-core_observer_started)) bytes=$core_observer_bytes marker=${core_observer_marker:-no-recent-marker}"
    else
      echo "CORE_PROGRESS elapsed_seconds=$((SECONDS-core_observer_started)) observation=unavailable"
    fi
  done
) &
core_observer_pid=$!
trap core_observer_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Observer cleanup belongs only to the parent that owns its child PID.
if (trap - EXIT INT TERM; run_full_xctest) >"$log" 2>&1; then
  swift_status=0
else
  swift_status=$?
fi
stop_core_observer
trap - EXIT INT TERM
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
