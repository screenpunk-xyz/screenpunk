#!/usr/bin/env bash
# Run before the enclosing app is signed. Does not run project/npm lifecycle scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Usage: bundle-authoring.sh /path/to/Screenpunk.app}"
cache="$ROOT/.build/authoring-downloads"
mkdir -p "$cache"
archive="$cache/node-v24.21.0-darwin-arm64.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz -o "$archive"
fi
npm --prefix "$ROOT/authoring" ci --ignore-scripts
SCREENPUNK_NODE_ARCHIVE="$archive" node "$ROOT/authoring/scripts/kit.mjs" "$app/Contents/Resources/AuthoringKit"

python3 "$ROOT/scripts/check-authoring-kit.py" "$app/Contents/Resources/AuthoringKit"
