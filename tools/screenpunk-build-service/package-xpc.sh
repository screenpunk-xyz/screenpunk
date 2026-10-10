#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: package-xpc.sh APP_BUNDLE CODESIGN_IDENTITY VERIFIED_KIT_DIRECTORY" >&2
  exit 64
fi

app_bundle=$1
signing_identity=$2
kit_directory=$3
case "$app_bundle" in
  /*.app) ;;
  *) echo "APP_BUNDLE must be an absolute .app bundle path" >&2; exit 64 ;;
esac
if [ ! -d "$app_bundle/Contents/MacOS" ]; then
  echo "APP_BUNDLE is missing Contents/MacOS" >&2
  exit 66
fi
if [ ! -f "$kit_directory/bin/node" ] || [ ! -f "$kit_directory/scripts/build.mjs" ]; then
  echo "VERIFIED_KIT_DIRECTORY must contain bin/node and scripts/build.mjs" >&2
  exit 66
fi
case "$(basename -- "$kit_directory")" in
  *..*|*[!A-Za-z0-9._-]*|'') echo "Kit directory must use its catalog-derived portable name" >&2; exit 64 ;;
esac

service_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
signing_identity=$("$service_dir/../../scripts/ci/resolve-apple-team-identity.sh" \
  "$signing_identity" "Developer ID Application")
cd "$service_dir"
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
target="$app_bundle/Contents/XPCServices/ScreenpunkBuildService.xpc"
if [ -e "$target" ]; then
  echo "Existing build service bundle must be removed by the release packager" >&2
  exit 73
fi
mkdir -p "$target/Contents/MacOS"
mkdir -p "$target/Contents/Resources/AuthoringKit"
cp "$binary_dir/ScreenpunkBuildService" "$target/Contents/MacOS/ScreenpunkBuildService"
cp Resources/Info.plist "$target/Contents/Info.plist"
cp -R "$kit_directory" "$target/Contents/Resources/AuthoringKit/"
codesign --force --options runtime --entitlements Resources/BuildService.entitlements --sign "$signing_identity" "$target"
codesign --verify --strict --verbose=2 "$target"
echo "$target"
