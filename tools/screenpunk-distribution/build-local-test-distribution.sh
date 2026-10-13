#!/bin/sh
set -eu

# Creates a measured, unsigned local test artifact only. It never installs it.
# The authoring source bundle is deliberately marked incomplete: it does not
# contain the offline Node/compiler dependency closure required for release.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
planning_root=$(CDPATH= cd -- "$repo_root/../.." && pwd)/Planning-Files
version=${1:-0.0.0-local-test}
output=${2:-/private/tmp/screenpunk-workbench-${version}-local-test}
case "$output" in
  /private/tmp/*) ;;
  *) echo 'Output must be under /private/tmp for this local test script.' >&2; exit 64 ;;
esac
if [ -e "$output" ]; then echo "Output already exists: $output" >&2; exit 73; fi

export CLANG_MODULE_CACHE_PATH=/private/tmp/sp-m5-swift-cache/clang
export SWIFTPM_CACHE_PATH=/private/tmp/sp-m5-swift-cache/swiftpm
export XDG_CACHE_HOME=/private/tmp/sp-m5-swift-cache/xdg
swift build --disable-sandbox -c release --package-path "$repo_root/tools/screenpunk-workbench"
swift build --disable-sandbox -c release --package-path "$script_dir"

work=$(mktemp -d /private/tmp/sp-distribution-payload.XXXXXX)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
payload="$work/payload"
mkdir -p "$payload/bin" "$payload/libexec" "$payload/Resources/AuthoringKit/source" \
  "$payload/Resources/help" "$payload/Resources/contracts" "$payload/LICENSES"
cli_build="$repo_root/tools/screenpunk-workbench/.build/release"
cp "$cli_build/screenpunk" "$payload/bin/screenpunk"
cp "$cli_build/screenpunk-mcp" "$payload/bin/screenpunk-mcp"
cp "$cli_build/screenpunk-service" "$payload/libexec/screenpunk-service"
chmod 700 "$payload/bin/screenpunk" "$payload/bin/screenpunk-mcp" "$payload/libexec/screenpunk-service"

for directory in scripts templates react ui icons licenses; do
  cp -R "$repo_root/authoring/$directory" "$payload/Resources/AuthoringKit/source/$directory"
done
for file in package.json package-lock.json toolchain.json catalog.json tsconfig.json README.md; do
  cp "$repo_root/authoring/$file" "$payload/Resources/AuthoringKit/source/$file"
done
cat > "$payload/Resources/AuthoringKit/LOCAL-TEST-ONLY.txt" <<'NOTE'
This artifact contains actual authoring source and standalone Screenpunk executables.
It does not contain the offline Node/compiler/dependency closure, approved catalog,
release signature, or notarization. Do not treat it as a production installer.
NOTE
cp "$repo_root/packages/ScreenpunkController/Sources/ScreenpunkController/Resources/help.json" "$payload/Resources/help/help.json"
cp "$repo_root/packages/ScreenpunkController/Sources/ScreenpunkController/Resources/mcp-catalog.json" "$payload/Resources/help/mcp-catalog.json"
cp "$planning_root/Mac-CLI-M0/schemas/"*.json "$payload/Resources/contracts/"
cp "$repo_root/LICENSE" "$payload/LICENSES/LICENSE"
cp "$repo_root/NOTICE" "$payload/LICENSES/NOTICE"
cat > "$payload/SBOM.json" <<'JSON'
{"schemaVersion":1,"classification":"local-test-incomplete","components":[{"name":"Screenpunk standalone SwiftPM executables","origin":"this checkout"},{"name":"AuthoringKit source","origin":"this checkout","offlineCompilerClosureIncluded":false}]}
JSON

"$script_dir/.build/release/screenpunk-package" assemble-local-test "$payload" "$output" "$version"
echo "Local test artifact: $output"
