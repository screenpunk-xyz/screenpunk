#!/usr/bin/env bash
# Sign, package, notarize, and staple the Mac app. Optional GitHub Release is a separate job.
set +x
set -euo pipefail
# shellcheck source=apple-signing-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple-signing-common.sh"

require_env APPLE_TEAM_ID
require_macos_26_sdk
import_p12 MAC_SIGNING_CERT_P12_BASE64 MAC_SIGNING_CERT_PASSWORD

./scripts/generate-xcode.sh
mac_proj="${ROOT}/apps/macos/ScreenpunkMac.xcodeproj"
enable_generated_signing "$mac_proj"

archive_path="${RELEASE_DIR}/ScreenpunkMac.xcarchive"
export_dir="${RELEASE_DIR}/macos-export"
export_plist="${WORK_DIR}/macos-exportOptions.plist"
mkdir -p "$export_dir"

cat >"$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
EOF

echo "=== macOS 26+ arm64 archive (Developer ID, hardened runtime) ==="
xcodebuild archive \
  -project "$mac_proj" \
  -scheme ScreenpunkMac \
  -destination 'generic/platform=macOS,name=Any Mac' \
  -archivePath "$archive_path" \
  -derivedDataPath "${RELEASE_DIR}/macos-derived" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp"

echo "=== Developer ID export ==="
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_plist"

app="$(find "$export_dir" -name 'Screenpunk.app' -type d | head -n 1)"
if [[ -z "$app" ]]; then
  echo "Developer ID export failed: Screenpunk.app not found"
  exit 1
fi

echo "=== nested Mach-O signing (inside-out; no --deep) ==="
# Product apps do not yet embed MCP, controller, or preview-host. Sign any
# nested Mach-O that appears later, then the wrapper app.
while IFS= read -r bin; do
  [[ -z "$bin" ]] && continue
  if [[ "$bin" == "$app/Contents/MacOS/Screenpunk" ]]; then
    continue
  fi
  codesign --force --options runtime --timestamp --sign "Developer ID Application" "$bin"
done < <(
  find "$app/Contents" -type f -print0 2>/dev/null \
    | xargs -0 file \
    | awk -F: '/Mach-O/{print $1}' \
    | awk '{ print gsub(/\//, "/") "\t" $0 }' \
    | sort -t $'\t' -nr \
    | cut -f2-
)

if [[ -d "${app}/Contents/Resources/screenpunk-mcp" || -x "${app}/Contents/MacOS/screenpunk-mcp" ]]; then
  echo "nested MCP binary present and signed"
else
  echo "STATE: nested-mcp-absent (app target does not embed tools/screenpunk-mcp yet)"
fi
if [[ -d "${app}/Contents/Helpers" ]]; then
  echo "nested helpers present and signed"
else
  echo "STATE: nested-helpers-absent (controller / preview-host not embedded yet)"
fi

codesign --force --options runtime --timestamp --sign "Developer ID Application" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "=== entitlements on exported app (no extra hardened-runtime exceptions applied here) ==="
codesign -d --entitlements :- "$app" 2>/dev/null || echo "no entitlements plist on app"

stage="${RELEASE_DIR}/dmg-root"
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$app" "$stage/Screenpunk.app"
ln -s /Applications "$stage/Applications"

dmg="${RELEASE_DIR}/Screenpunk.dmg"
rm -f "$dmg"
hdiutil create -volname Screenpunk -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "Developer ID Application" "$dmg"

require_env ASC_KEY_ID
require_env ASC_ISSUER_ID
require_env ASC_PRIVATE_KEY
key_path="$(write_asc_private_key)"
notary_log="${LOG_DIR}/notarytool-submit.log"

echo "=== notarize DMG ==="
if ! run_redacted "$notary_log" xcrun notarytool submit "$dmg" \
  --key "$key_path" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait \
  --timeout 30m; then
  echo "notarytool submit failed (details redacted)"
  exit 1
fi
if ! grep -Eq 'status:[[:space:]]*Accepted' "$notary_log"; then
  echo "notarization did not report Accepted"
  exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --deep --strict --verbose=2 "$dmg"
echo "=== Gatekeeper assess (hosted runner; confirm again on a real Mac) ==="
spctl --assess --type open --context context:primary-signature --verbose "$dmg" || echo "STATE: spctl-assess-incomplete-on-runner"

shasum -a 256 "$dmg" | tee "${dmg}.sha256"
echo "STATE: signed"
echo "STATE: notarized"
echo "STATE: stapled"
echo "dmg=${dmg}"
echo "checksum=${dmg}.sha256"
echo "STATE: github-release not performed by this script"
