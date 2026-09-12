#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

node --version
test -f LICENSE
grep -q "Apache License" LICENSE
test -f NOTICE
./scripts/verify-brand.mjs
./scripts/verify-offline-fixture-resource.sh

cd "$ROOT/sdk"
if [[ ! -d node_modules ]]; then
  npm ci
fi
npm test

cd "$ROOT"
node --test "tests/**/*.test.mjs"
node --test examples/weather/test.mjs examples/home-assistant/test.mjs
node --test tests/mcp/*.test.mjs

echo "linux contracts-and-sdk ok"
echo "ScreenpunkCore Swift tests on Linux run in core-linux (./scripts/ci/core-linux.sh)"
