#!/bin/bash
set -euo pipefail

# Produces a user-installable, signed offline release image. It never installs it.
if [ "$#" -ne 5 ]; then
  echo "usage: build-studio-release.sh VERSION OUTPUT_DMG VERIFIED_KIT_DIR RELEASE_KEY_FILE PINNED_NODE_ARCHIVE" >&2
  exit 64
fi
version=$1
output=$2
case "$version" in *[!A-Za-z0-9._-]*|'') echo "Invalid version" >&2; exit 64;; esac
case "$output" in /*.dmg) ;; *) echo "OUTPUT_DMG must be an absolute .dmg path" >&2; exit 64;; esac
if [ -e "$output" ]; then echo "Refusing to overwrite $output" >&2; exit 73; fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
kit_source=$3
key_file=$4
node_archive=$5
case "$kit_source:$key_file:$node_archive" in /*:/*:/*) ;; *) echo "All input paths must be absolute" >&2; exit 64;; esac
app_identity=98E00BBDF01DE542C912F86A40CB9AE616CBDCCC
entry=authoring-1.0.0-darwin-arm64
for file in "$key_file" "$kit_source/bin/node" "$kit_source/kit.json" "$node_archive"; do
  if [ ! -f "$file" ]; then echo "Missing required input: $file" >&2; exit 66; fi
done
actual_archive=$(shasum -a 256 "$node_archive" | awk '{print $1}')
if [ "$actual_archive" != bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057 ]; then
  echo "Pinned Node archive hash mismatch" >&2; exit 65
fi
if [ -n "$(find "$kit_source" -type l -print -quit)" ]; then
  echo "Authoring kit contains symlinks" >&2; exit 65
fi
mkdir -p "$(dirname "$output")"
stage=$(mktemp -d "$(dirname "$output")/.screenpunk-release.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/signed-kit" "$stage/kit-unit" "$stage/payload/bin" \
  "$stage/payload/libexec" "$stage/payload/Resources/Toolchains" \
  "$stage/payload/Resources/help" "$stage/payload/Resources/contracts" \
  "$stage/payload/LICENSES" "$stage/image"
export CLANG_MODULE_CACHE_PATH=/private/tmp/screenpunk-cli-build-cache/clang
export SWIFTPM_CACHE_PATH=/private/tmp/screenpunk-cli-build-cache/swiftpm
export XDG_CACHE_HOME=/private/tmp/screenpunk-cli-build-cache/xdg
ditto "$kit_source" "$stage/signed-kit"
entitlements="$repo_root/tools/screenpunk-build-service/Tests/NodeInherited.entitlements"
codesign --force --sign "$app_identity" --timestamp --options runtime \
  --identifier xyz.screenpunk.authoring.node --entitlements "$entitlements" \
  "$stage/signed-kit/bin/node"
codesign --force --sign "$app_identity" --timestamp --options runtime \
  --identifier xyz.screenpunk.authoring.esbuild --entitlements "$entitlements" \
  "$stage/signed-kit/node_modules/@esbuild/darwin-arm64/bin/esbuild"
codesign --force --sign "$app_identity" --timestamp --options runtime \
  --identifier xyz.screenpunk.authoring.fsevents --entitlements "$entitlements" \
  "$stage/signed-kit/node_modules/fsevents/fsevents.node"
codesign --verify --strict "$stage/signed-kit/bin/node"
codesign --verify --strict "$stage/signed-kit/node_modules/@esbuild/darwin-arm64/bin/esbuild"
codesign --verify --strict "$stage/signed-kit/node_modules/fsevents/fsevents.node"
/bin/sh "$repo_root/tools/screenpunk-build-host/package-host.sh" \
  "$stage/kit-unit/$entry" "$app_identity" "$stage/signed-kit" "$entry"
swiftc "$script_dir/scripts/sign-ed25519.swift" -o "$stage/sign-ed25519"
python3 "$script_dir/scripts/assemble-catalog.py" "$stage/kit-unit/$entry" \
  "$stage/payload/Resources/Toolchains/$entry.tar" \
  "$stage/payload/Resources/Toolchains/catalog-envelope.json" "$key_file" "$stage/sign-ed25519"
swift build --disable-sandbox -c release --package-path "$repo_root/tools/screenpunk-workbench"
swift build --disable-sandbox -c release --package-path "$script_dir"
cli_build=$(swift build --disable-sandbox -c release --package-path "$repo_root/tools/screenpunk-workbench" --show-bin-path)
cp "$cli_build/screenpunk" "$stage/payload/bin/screenpunk"
cp "$cli_build/screenpunk-mcp" "$stage/payload/bin/screenpunk-mcp"
cp "$cli_build/screenpunk-service" "$stage/payload/libexec/screenpunk-service"
for record in 'screenpunk xyz.screenpunk.cli bin' 'screenpunk-mcp xyz.screenpunk.mcp bin' 'screenpunk-service xyz.screenpunk.service libexec'; do
  read -r name identifier folder <<< "$record"
  codesign --force --sign "$app_identity" --timestamp --options runtime \
    --identifier "$identifier" "$stage/payload/$folder/$name"
  codesign --verify --strict "$stage/payload/$folder/$name"
done
cp "$repo_root/packages/ScreenpunkController/Sources/ScreenpunkController/Resources/help.json" "$stage/payload/Resources/help/"
cp "$repo_root/packages/ScreenpunkController/Sources/ScreenpunkController/Resources/mcp-catalog.json" "$stage/payload/Resources/help/"
planning_schemas="$repo_root/../../Planning-Files/Mac-CLI-M0/schemas"
if [ ! -d "$planning_schemas" ]; then echo "Missing CLI contract schemas" >&2; exit 66; fi
cp "$planning_schemas"/*.json "$stage/payload/Resources/contracts/"
cp "$repo_root/LICENSE" "$repo_root/NOTICE" "$stage/payload/LICENSES/"
python3 - "$repo_root/authoring/package-lock.json" "$stage/payload/SBOM.json" "$version" <<'PY'
import json,sys
lock=json.load(open(sys.argv[1]))
components=[{"name":name,"version":item.get("version","unknown"),"integrity":item.get("integrity")}
            for name,item in sorted(lock["packages"].items()) if name]
components.insert(0,{"name":"Screenpunk CLI, MCP, service, and build host","version":sys.argv[3],"origin":"this source checkout"})
components.insert(1,{"name":"Node.js","version":"24.21.0","archiveSha256":"bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"})
with open(sys.argv[2],"w") as stream: json.dump({"schemaVersion":1,"components":components},stream,separators=(",",":"))
PY
release="$stage/image/Screenpunk CLI $version"
"$script_dir/.build/release/screenpunk-package" assemble-release "$stage/payload" "$release" "$version" "$key_file"
"$script_dir/.build/release/screenpunk-package" verify-release "$release"
cat > "$stage/image/Install Screenpunk CLI.command" <<'INSTALL'
#!/bin/bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive=$(find "$here" -maxdepth 1 -type d -name 'Screenpunk CLI *' -print -quit)
if [ -z "$archive" ]; then echo 'Release folder missing' >&2; exit 66; fi
if [ "$(id -u)" -eq 0 ]; then echo 'Run this installer as your normal user, not root.' >&2; exit 77; fi
cli="$archive/bin/screenpunk"
"$cli" install plan "$archive"
echo
echo 'Copy the exact Confirmation token above, then paste it here to install this release.'
read -r -p 'Confirmation token: ' token
if [ -z "$token" ]; then echo 'Installation cancelled.' >&2; exit 1; fi
"$cli" install apply "$archive" "$token"
INSTALL
chmod 755 "$stage/image/Install Screenpunk CLI.command"
cat > "$stage/image/README.txt" <<'README'
Screenpunk CLI for Apple silicon, macOS 14 or newer.

Open this notarized image and run "Install Screenpunk CLI.command" as your normal
user. Review the exact install plan and enter its Confirmation token. This is a
per-user installation; no Xcode, sudo, or Mac GUI app is required.

To inspect before installing, run the release folder's bin/screenpunk with
"install plan" and the release folder's absolute path. The bundled offline
catalog and toolchain are authenticated again during installation.
README
hdiutil create -quiet -srcfolder "$stage/image" -volname "Screenpunk CLI $version" \
  -format UDZO -ov "$output"
codesign --force --sign "$app_identity" --timestamp "$output"
codesign --verify --verbose=2 "$output"
echo "Signed distribution image: $output"
shasum -a 256 "$output"
