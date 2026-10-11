#!/bin/bash
set -euo pipefail
# Retain the immutable signed kit/catalog: re-signing under sequence 1 would
# create conflicting catalog history for existing users.
if [ "$#" -ne 4 ]; then
  echo 'usage: build-homebrew-release.sh VERSION OUTPUT_DMG RELEASE_KEY_FILE VERIFIED_PREVIOUS_RELEASE' >&2
  exit 64
fi
version=$1
output=$2
key_file=$3
previous=$4
case "$version" in *[!A-Za-z0-9._-]*|'') exit 64;; esac
case "$output:$key_file:$previous" in /*.dmg:/*:/*) ;; *) exit 64;; esac
if [ -e "$output" ]; then echo "Refusing to overwrite $output" >&2; exit 73; fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
export CLANG_MODULE_CACHE_PATH=/private/tmp/screenpunk-cli-build-cache/clang
export SWIFTPM_CACHE_PATH=/private/tmp/screenpunk-cli-build-cache/swiftpm
export XDG_CACHE_HOME=/private/tmp/screenpunk-cli-build-cache/xdg
swift build --disable-sandbox -c release --package-path "$script_dir"
"$script_dir/.build/release/screenpunk-package" verify-release "$previous"
swift build --disable-sandbox -c release --package-path "$repo_root/tools/screenpunk-workbench"
cli_build=$(swift build --disable-sandbox -c release --package-path "$repo_root/tools/screenpunk-workbench" --show-bin-path)
mkdir -p "$(dirname "$output")"
stage=$(mktemp -d "$(dirname "$output")/.screenpunk-homebrew-release.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/image"
ditto "$previous" "$stage/payload"
rm "$stage/payload/release-auth.json" "$stage/payload/release-manifest.json"
cp "$cli_build/screenpunk" "$stage/payload/bin/screenpunk"
cp "$cli_build/screenpunk-mcp" "$stage/payload/bin/screenpunk-mcp"
cp "$cli_build/screenpunk-service" "$stage/payload/libexec/screenpunk-service"
mkdir -p "$stage/payload/Resources/Cloud"
python3 - "$stage/payload/Resources/Cloud/controller.json" "${SCREENPUNK_CLOUD_API_ORIGIN:-https://staging.screenpunk.xyz}" <<'PY'
import json,sys,urllib.parse
path,origin=sys.argv[1:]
url=urllib.parse.urlsplit(origin)
if url.scheme!='https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('','/'):
    raise SystemExit('Invalid Screenpunk cloud API origin')
with open(path,'w') as stream: json.dump({'schemaVersion':1,'apiOrigin':origin},stream,separators=(',',':'))
PY
identity=98E00BBDF01DE542C912F86A40CB9AE616CBDCCC
for record in 'screenpunk xyz.screenpunk.cli bin' 'screenpunk-mcp xyz.screenpunk.mcp bin' 'screenpunk-service xyz.screenpunk.service libexec'; do
  read -r name identifier folder <<< "$record"
  codesign --force --sign "$identity" --timestamp --options runtime \
    --identifier "$identifier" "$stage/payload/$folder/$name"
  codesign --verify --strict "$stage/payload/$folder/$name"
done
python3 - "$stage/payload/SBOM.json" "$version" <<'PY'
import json,sys
path,version=sys.argv[1:]
with open(path) as stream: value=json.load(stream)
value['components'][0]['version']=version
with open(path,'w') as stream: json.dump(value,stream,separators=(',',':'))
PY
cp "$repo_root/packages/ScreenpunkController/Sources/ScreenpunkController/Resources/help.json" "$stage/payload/Resources/help/"
cp "$repo_root/packages/ScreenpunkController/Sources/ScreenpunkController/Resources/mcp-catalog.json" "$stage/payload/Resources/help/"
release="$stage/image/Screenpunk CLI $version"
"$script_dir/.build/release/screenpunk-package" assemble-release "$stage/payload" "$release" "$version" "$key_file"
"$script_dir/.build/release/screenpunk-package" verify-release "$release"
cmp "$previous/Resources/Toolchains/catalog-envelope.json" "$release/Resources/Toolchains/catalog-envelope.json"
cmp "$previous/Resources/Toolchains/authoring-1.0.0-darwin-arm64.tar" "$release/Resources/Toolchains/authoring-1.0.0-darwin-arm64.tar"
cat > "$stage/image/README.txt" <<'README'
Screenpunk CLI for Apple silicon, macOS 14 or newer.

Install with the Screenpunk Homebrew cask:
  brew tap screenpunk-xyz/tap https://github.com/screenpunk-xyz/homebrew-tap
  brew install --cask screenpunk-cli
  screenpunk setup

Homebrew owns screenpunk, screenpunk-mcp, and their immutable software.
The first service request prepares the bundled offline kit and starts the
owned user LaunchAgent. No Xcode, sudo, or Mac GUI app is required.
Use the same macOS account for installation and CLI/MCP use. This release
supports the standard Apple-silicon Homebrew prefix, /opt/homebrew.

Upgrade: brew upgrade --cask screenpunk-cli
Remove:  brew uninstall --cask screenpunk-cli
Removal stops the verified service and preserves user data and workspaces.
README
hdiutil create -quiet -srcfolder "$stage/image" -volname "Screenpunk CLI $version" -format UDZO "$output"
codesign --force --sign "$identity" --timestamp "$output"
codesign --verify --strict "$output"
echo "Signed distribution image: $output"
shasum -a 256 "$output"
