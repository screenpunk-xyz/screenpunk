#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

node --version
test -f LICENSE
grep -q "Apache License" LICENSE
test -f NOTICE
./scripts/verify-brand.mjs

cd "$ROOT/sdk"
if [[ ! -d node_modules ]]; then
  npm ci
fi
npm test

echo "linux contracts-and-sdk ok"
