#!/usr/bin/env bash
# Keep the Apple-host bundled copy identical to examples/offline-fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/examples/offline-fixture"
DST="$ROOT/packages/ScreenpunkApple/Sources/ScreenpunkApple/Resources/offline-fixture"
for f in index.html app.js styles.css manifest.json; do
  if ! cmp -s "$SRC/$f" "$DST/$f"; then
    echo "offline fixture resource drifted: $f"
    exit 1
  fi
done
echo "offline fixture resource matches examples/offline-fixture"
