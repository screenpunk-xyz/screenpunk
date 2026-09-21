#!/usr/bin/env bash
# Build the product Mac app without a Developer ID and wrap it in a DMG for
# alpha testers. No Apple secrets, no notarization, no GitHub environment.
#
# "Unsigned" means no Developer ID and no notarization. The bundle still gets
# an ad-hoc signature (identity "-") because macOS 15 and later do not offer
# "Open Anyway" for a bundle with no signature at all. Ad-hoc signing needs no
# Apple account and proves nothing about who built the app; Gatekeeper reports
# the result as unverified and the first launch needs an explicit override.
#
# Usage: scripts/build-unsigned-dmg.sh [output-dir]
#   output-dir                     default dist/macos-unsigned (git-ignored)
#   DEVELOPER_DIR                  optional Xcode to use; must ship a macOS 26 SDK.
#                                  Unset: use the xcode-select default if it has
#                                  one, else the newest /Applications/Xcode*.app
#                                  that does. None found: MACOS_26_SDK_UNAVAILABLE.
#   SCREENPUNK_UNSIGNED_OUT        same as output-dir, for CI
#   SCREENPUNK_MARKETING_VERSION   CFBundleShortVersionString (default 0.1.0)
#   SCREENPUNK_BUILD_NUMBER        CFBundleVersion (default GITHUB_RUN_NUMBER, else git commit count)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-unsigned-dmg.sh requires macOS"
  exit 1
fi
for tool in xcodebuild xcode-select codesign hdiutil ditto shasum python3 /usr/libexec/PlistBuddy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool"
    exit 1
  fi
done

OUT_DIR="${1:-${SCREENPUNK_UNSIGNED_OUT:-$ROOT/dist/macos-unsigned}}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Same pattern as scripts/ci/apple.sh and the release helpers.
MACOS_26_SDK_RE='macosx(2[6-9]|[3-9][0-9])(\.|$)'

# An empty DEVELOPER_DIR (for example an unset workflow input) means "not set".
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  unset DEVELOPER_DIR
fi

developer_dir_has_macos_26_sdk() {
  local sdk
  for sdk in "$1"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk; do
    [[ -e "$sdk" ]] || continue
    case "$(basename "$sdk")" in
      MacOSX2[6-9]*.sdk | MacOSX[3-9][0-9]*.sdk) return 0 ;;
    esac
  done
  return 1
}

version_newer() {
  [[ "$1" != "$2" ]] &&
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)" == "$1" ]]
}

select_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    echo "DEVELOPER_DIR preset: ${DEVELOPER_DIR}"
    return 0
  fi
  local current
  current="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$current" ]] && developer_dir_has_macos_26_sdk "$current"; then
    echo "selected Xcode: ${current} (xcode-select default)"
    return 0
  fi
  local app dev ver best="" best_ver=""
  for app in /Applications/Xcode*.app; do
    dev="${app}/Contents/Developer"
    [[ -d "$dev" ]] || continue
    developer_dir_has_macos_26_sdk "$dev" || continue
    ver="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${app}/Contents/Info.plist" 2>/dev/null || echo 0)"
    if [[ -z "$best" ]] || version_newer "$ver" "$best_ver"; then
      best="$dev"
      best_ver="$ver"
    fi
  done
  [[ -n "$best" ]] || return 1
  export DEVELOPER_DIR="$best"
  echo "selected Xcode ${best_ver}: ${DEVELOPER_DIR} (xcode-select default ${current:-unknown} has no macOS 26 SDK)"
}

if ! select_developer_dir; then
  echo "MACOS_26_SDK_UNAVAILABLE"
  echo "no installed Xcode ships a macOS 26 SDK; the build uses its Liquid Glass APIs while deploying to macOS 14+"
  echo "install Xcode 26 or point DEVELOPER_DIR at one, then rerun"
  exit 1
fi

# Fail clearly on hosts that cannot run the native Mac icon renderer.
source "$ROOT/scripts/select-icon-xcode.sh"

echo "=== toolchain ==="
sw_vers || true
uname -m
xcodebuild -version
sdk_list="$(xcodebuild -showsdks)"
if ! echo "$sdk_list" | grep -qE "$MACOS_26_SDK_RE"; then
  echo "MACOS_26_SDK_UNAVAILABLE"
  echo "xcodebuild at ${DEVELOPER_DIR:-$(xcode-select -p)} reports no macOS 26 SDK"
  exit 1
fi
macos_sdk="$(echo "$sdk_list" | sed -nE 's/.*-sdk (macosx[0-9.]+).*/\1/p' | sort -t . -k 1,1 -k 2,2n | tail -n 1)"
echo "macOS SDK: ${macos_sdk}"

./scripts/generate-xcode.sh
mac_proj="${ROOT}/apps/macos/ScreenpunkMac.xcodeproj"
if [[ ! -d "$mac_proj" ]]; then
  echo "missing generated project: ${mac_proj}"
  exit 1
fi

git_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
marketing_version="${SCREENPUNK_MARKETING_VERSION:-0.1.0}"
build_number="${SCREENPUNK_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}}"

derived="${OUT_DIR}/derived"
stage="${OUT_DIR}/dmg-root"
dmg="${OUT_DIR}/Screenpunk-unsigned.dmg"
build_info="${OUT_DIR}/BUILD-INFO.txt"
rm -rf "$stage" "$dmg" "${dmg}.sha256" "$build_info"

# Remove obsolete command-line resource layout from earlier development builds.
rm -rf "$derived/Build/Products/Release/Screenpunk.app/Contents/MacOS/ScreenpunkApple_ScreenpunkApple.bundle" "$derived/Build/Products/Release/Screenpunk.app/Contents/MacOS/ScreenpunkController_ScreenpunkController.bundle"
echo "=== Release build: arm64, macOS 14+, ad-hoc identity (no Developer ID, no team) ==="
# Command-line settings override the project's CODE_SIGNING_ALLOWED=NO for this
# build only; apps/macos/project.yml stays unsigned for PR CI.
xcodebuild \
  -project "$mac_proj" \
  -scheme ScreenpunkMac \
  -configuration Release \
  -destination 'generic/platform=macOS,name=Any Mac' \
  -derivedDataPath "$derived" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  build

app="$(find "${derived}/Build/Products" -maxdepth 2 -type d -name 'Screenpunk.app' -print -quit)"
if [[ -z "$app" || ! -x "${app}/Contents/MacOS/Screenpunk" ]]; then
  echo "build finished but Screenpunk.app was not found under ${derived}/Build/Products"
  exit 1
fi

echo "=== bundled MCP server and preview helper ==="
swift build --package-path "$ROOT/tools/screenpunk-mcp" -c release -Xswiftc -swift-version -Xswiftc 5
mcp_bin="$(swift build --package-path "$ROOT/tools/screenpunk-mcp" -c release --show-bin-path)"
ditto "$mcp_bin/screenpunk-mcp" "$app/Contents/MacOS/screenpunk-mcp"
# Resource bundles live in Resources, outside the signed executable directory.
for resource in "$mcp_bin"/*.bundle; do
  [[ -d "$resource" ]] || continue
  rm -rf "$app/Contents/MacOS/$(basename "$resource")"
  ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
xcodebuild -project "$ROOT/tools/preview-host/ScreenpunkPreviewHost.xcodeproj" \
  -scheme ScreenpunkPreviewHost -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$OUT_DIR/preview-derived" ARCHS=arm64 CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
mkdir -p "$app/Contents/Helpers"
ditto "$OUT_DIR/preview-derived/Build/Products/Release/ScreenpunkPreviewHost.app" "$app/Contents/Helpers/ScreenpunkPreviewHost.app"
"$ROOT/scripts/bundle-authoring.sh" "$app"
codesign --force --sign - "$app/Contents/Resources/AuthoringKit/bin/node"
codesign --force --sign - "$app/Contents/Resources/AuthoringKit/node_modules/@esbuild/darwin-arm64/bin/esbuild"
codesign --force --sign - "$app/Contents/MacOS/screenpunk-mcp"
codesign --force --deep --sign - "$app"

echo "=== signature: must verify and must be ad-hoc ==="
codesign --verify --deep --strict --verbose=2 "$app"
sig_info="$(codesign -dvv "$app" 2>&1 || true)"
echo "$sig_info" | grep -E '^(Identifier|Format|Signature|TeamIdentifier|Authority)=' || true
if ! echo "$sig_info" | grep -q '^Signature=adhoc'; then
  echo "expected an ad-hoc signature; refusing to package an app signed with a real identity on this path"
  exit 1
fi
echo "=== Gatekeeper assessment (expected: rejected; nothing here is notarized) ==="
if spctl --assess --type execute --verbose=4 "$app" 2>&1; then
  echo "STATE: gatekeeper-accepted-unexpectedly (check the identity above)"
else
  echo "STATE: gatekeeper-rejected (expected for the unsigned alpha; first launch needs Open Anyway)"
fi

echo "=== packaged MCP and native preview acceptance ==="
python3 "$ROOT/scripts/check-packaged-mcp.py" "$app"

echo "=== DMG ==="
mkdir -p "$stage"
ditto "$app" "${stage}/Screenpunk.app"
ln -s /Applications "${stage}/Applications"
hdiutil create -volname Screenpunk -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
hdiutil verify -quiet "$dmg"

mount_point="$(mktemp -d "${TMPDIR:-/tmp}/screenpunk-dmg.XXXXXX")"
detach_dmg() {
  hdiutil detach "$mount_point" -quiet 2>/dev/null || hdiutil detach "$mount_point" -force -quiet 2>/dev/null || true
  rmdir "$mount_point" 2>/dev/null || true
}
trap detach_dmg EXIT
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_point" -quiet
test -d "${mount_point}/Screenpunk.app"
test -L "${mount_point}/Applications"
codesign --verify --deep --strict "${mount_point}/Screenpunk.app"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' -c 'Print CFBundleShortVersionString' -c 'Print CFBundleVersion' -c 'Print LSMinimumSystemVersion' \
  "${mount_point}/Screenpunk.app/Contents/Info.plist"
detach_dmg
trap - EXIT
rm -rf "$stage"

(cd "$OUT_DIR" && shasum -a 256 "$(basename "$dmg")" | tee "$(basename "$dmg").sha256")

xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
cat >"$build_info" <<EOF
artifact=Screenpunk-unsigned.dmg
state=unsigned: ad-hoc identity, no Developer ID, not notarized, not stapled
first_launch=System Settings > Privacy & Security > Open Anyway (see docs/macos-unsigned-dmg.md)
git_sha=${git_sha}
marketing_version=${marketing_version}
minimum_macos=14.0
architecture=arm64
build_number=${build_number}
xcode=${xcode_version}
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
macos_sdk=${macos_sdk}
built_on=$(sw_vers -productVersion 2>/dev/null || echo unknown) $(uname -m)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cat "$build_info"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Unsigned Mac DMG"
    echo
    echo "- State: unsigned (ad-hoc identity, no Developer ID), not notarized"
    echo "- Commit: \`${git_sha}\`"
    echo "- Xcode: ${xcode_version}; SDK: ${macos_sdk}"
    echo "- SHA-256: \`$(cut -d ' ' -f 1 "${dmg}.sha256")\`"
    echo "- First launch: System Settings → Privacy & Security → Open Anyway"
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "STATE: unsigned (ad-hoc identity; no Developer ID)"
echo "STATE: not-notarized"
echo "dmg=${dmg}"
echo "checksum=${dmg}.sha256"
echo "build_info=${build_info}"
