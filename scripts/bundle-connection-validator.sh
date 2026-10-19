#!/bin/bash
# Build-only: an app-owned parser/runtime closure, independent of installed kits.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?Usage: bundle-connection-validator.sh DESTINATION [NODE_ARCHIVE]}"
cache="$ROOT/.build/authoring-downloads"
archive="${2:-$cache/node-v24.21.0-darwin-arm64.tar.gz}"
mkdir -p "$cache"
if [[ ! -f "$archive" ]]; then
 curl --fail --location --proto '=https' --tlsv1.2 https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz -o "$archive"
fi
python3 - "$ROOT/authoring/toolchain.json" "$archive" <<'PY'
import hashlib,json,sys
pin=json.load(open(sys.argv[1]))['node']
if hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest()!=pin['sha256']:raise SystemExit('Node archive acceptance mismatch')
PY
npm --prefix "$ROOT/authoring" ci --ignore-scripts
npm --prefix "$ROOT/authoring/connection-validator" ci --ignore-scripts
node "$ROOT/authoring/connection-validator/bundle.mjs" "$destination"
stage=$(mktemp -d "$cache/validator-node.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
/usr/bin/tar -xzf "$archive" -C "$stage"
cp "$stage/node-v24.21.0-darwin-arm64/bin/node" "$destination/node"
cp "$stage/node-v24.21.0-darwin-arm64/LICENSE" "$destination/NODE-LICENSE.txt"
chmod 755 "$destination/node"
python3 - "$destination" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.iterdir()) if p.is_file() and p.name not in ('inventory.json','node')}
(root/'inventory.json').write_text(json.dumps({'schemaVersion':1,'node':'24.21.0','typescript':'5.9.3','parse5':'7.3.0','unsignedNodeSha256':hashlib.sha256((root/'node').read_bytes()).hexdigest(),'files':files},sort_keys=True,indent=2))
PY
