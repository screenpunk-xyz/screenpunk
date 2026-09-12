#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "apple.sh requires macOS"
  exit 1
fi

./scripts/generate-xcode.sh

if command -v swift >/dev/null 2>&1; then
  (cd packages/ScreenpunkCore && swift test)
  (cd packages/ScreenpunkApple && swift build)
  (cd packages/ScreenpunkController && swift build)
  (cd tools/screenpunk-mcp && swift build)
fi

echo "apple-build-and-unit bootstrap steps finished"
echo "hidden render / simulator UI tests are not implemented yet"
