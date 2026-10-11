#!/bin/sh
set -eu

service_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d /private/tmp/screenpunk-xpc-smoke.XXXXXX)
if [ "${SCREENPUNK_KEEP_SMOKE:-0}" = 1 ]; then
  echo "Smoke bundle: $scratch"
else
  trap 'rm -rf "$scratch"' EXIT
fi
app="$scratch/XPCSmokeHost.app"
xpc="$app/Contents/XPCServices/ScreenpunkBuildService.xpc"
kit="$xpc/Contents/Resources/AuthoringKit/fixture"
mkdir -p "$app/Contents/MacOS" "$xpc/Contents/MacOS" "$kit/bin" "$kit/scripts"

cd "$service_dir"
swift build --disable-sandbox
binary_dir=$(swift build --disable-sandbox --show-bin-path)
cp "$binary_dir/ScreenpunkBuildService" "$xpc/Contents/MacOS/ScreenpunkBuildService"
cp Resources/Info.plist "$xpc/Contents/Info.plist"
cp Tests/SmokeHost-Info.plist "$app/Contents/Info.plist"
cp /usr/local/bin/node "$kit/bin/node"
cat > "$kit/scripts/build.mjs" <<'EOF'
import fs from 'node:fs';
let outside = 'allowed';
let network = 'allowed';
try { fs.readFileSync('/Users/gsuter/Repo/Screenpunk/README.md'); } catch { outside = 'denied'; }
try { await fetch('http://127.0.0.1:54321', { signal: AbortSignal.timeout(1500) }); } catch { network = 'denied'; }
fs.mkdirSync(process.argv[3], { recursive: true });
fs.writeFileSync(process.argv[3] + '/sandbox.json', JSON.stringify({ outside, network }));
EOF

codesign --force --sign - --entitlements Tests/NodeInherited.entitlements "$kit/bin/node"
codesign --force --sign - --entitlements Resources/BuildService.entitlements "$xpc"
swiftc Tests/XPCSmokeHost.swift -o "$app/Contents/MacOS/XPCSmokeHost"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
if [ "${SCREENPUNK_TAMPER_SMOKE:-0}" = 1 ]; then
  echo '// post-sign tamper' >> "$kit/scripts/build.mjs"
fi
"$app/Contents/MacOS/XPCSmokeHost"
