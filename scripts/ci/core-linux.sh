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
(cd packages/ScreenpunkCore && swift test 2>&1 | tee "$log")

if ! grep -qE "Executed [0-9]+ tests, with 0 failures" "$log"; then
  echo "swift test did not report a clean run"
  exit 1
fi

echo "core-linux ok"
echo "CryptoKit SAS vectors are Apple-only and are checked by apple-build-and-unit; TypeScript checks the same MACs here on Linux"
