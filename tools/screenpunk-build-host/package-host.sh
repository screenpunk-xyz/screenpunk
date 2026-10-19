#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: package-host.sh OUTPUT_UNIT SIGNING_IDENTITY VERIFIED_KIT_DIRECTORY CATALOG_ENTRY_ID" >&2
  exit 64
fi
output=$1
identity=$2
kit=$3
entry=$4
case "$output" in /*) ;; *) echo "OUTPUT_UNIT must be absolute" >&2; exit 64 ;; esac
case "$kit" in /*) ;; *) echo "VERIFIED_KIT_DIRECTORY must be absolute" >&2; exit 64 ;; esac
case "$entry" in
  *..*|*[!A-Za-z0-9._-]*|'') echo "Invalid catalog entry ID" >&2; exit 64 ;;
esac
if [ -z "$identity" ]; then echo "Explicit signing identity required" >&2; exit 64; fi
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "Refusing to overwrite an existing distribution unit" >&2
  exit 73
fi
if [ ! -f "$kit/bin/node" ] || [ ! -f "$kit/scripts/build.mjs" ] || [ ! -f "$kit/kit.json" ]; then
  echo "Verified kit lacks a required file" >&2
  exit 66
fi
if [ -n "$(find "$kit" -type l -print -quit)" ]; then
  echo "Verified kit must contain no symlinks" >&2
  exit 66
fi

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
identity=$("$here/../../scripts/ci/resolve-apple-team-identity.sh" \
  "$identity" "Developer ID Application")
service="$here/../screenpunk-build-service"
parent=$(dirname -- "$output")
stage=$(mktemp -d "$parent/.screenpunk-host.XXXXXXXX")
published=0
cleanup() { if [ "$published" -eq 0 ]; then rm -rf "$stage"; fi; }
trap cleanup EXIT INT TERM

swift build --package-path "$here" -c release
swift build --package-path "$service" -c release
host_bin=$(swift build --package-path "$here" -c release --show-bin-path)
service_bin=$(swift build --package-path "$service" -c release --show-bin-path)

ditto "$kit" "$stage"
app="$stage/Host/ScreenpunkBuildHost.app"
xpc="$app/Contents/XPCServices/ScreenpunkBuildService.xpc"
embedded="$xpc/Contents/Resources/AuthoringKit/$entry"
mkdir -p "$app/Contents/MacOS" "$xpc/Contents/MacOS" "$(dirname -- "$embedded")"
cp "$host_bin/ScreenpunkBuildHost" "$app/Contents/MacOS/ScreenpunkBuildHost"
cp "$service_bin/ScreenpunkBuildService" "$xpc/Contents/MacOS/ScreenpunkBuildService"
cp "$service/Resources/Info.plist" "$xpc/Contents/Info.plist"
ditto "$kit" "$embedded"
python3 - "$here/Resources/Info.plist" "$app/Contents/Info.plist" "$entry" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: data=plistlib.load(f)
data['ScreenpunkKitDirectory']=sys.argv[3]
with open(sys.argv[2],'wb') as f: plistlib.dump(data,f,sort_keys=True)
PY

# The input Node must already carry the intended inherited-sandbox entitlement and
# publisher identity. This assembler never re-signs it or mutates a published bundle.
codesign --sign "$identity" --options runtime \
  --entitlements "$service/Resources/BuildService.entitlements" "$xpc"
codesign --sign "$identity" --options runtime "$app"
codesign --verify --strict --deep "$app"
mv "$stage" "$output"
published=1
echo "$output"
