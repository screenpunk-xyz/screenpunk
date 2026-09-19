#!/usr/bin/env bash
# Archive and export a signed iOS IPA. Does not upload and does not submit.
set +x
set -euo pipefail
# shellcheck source=apple-signing-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple-signing-common.sh"

# Icon Composer resources require Xcode 26 or newer.
source "$ROOT/scripts/select-icon-xcode.sh"

require_env APPLE_TEAM_ID
import_p12 IOS_SIGNING_CERT_P12_BASE64 IOS_SIGNING_CERT_PASSWORD
install_ios_profile

./scripts/generate-xcode.sh
ios_proj="${ROOT}/apps/ios/ScreenpunkiOS.xcodeproj"
enable_generated_signing "$ios_proj"

archive_path="${RELEASE_DIR}/ScreenpunkiOS.xcarchive"
export_dir="${RELEASE_DIR}/ios-export"
export_plist="${WORK_DIR}/ios-exportOptions.plist"
mkdir -p "$export_dir"

cat >"$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>xyz.screenpunk.ios</key>
    <string>${PROFILE_NAME}</string>
  </dict>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

echo "=== iOS device archive (signed, not uploaded) ==="
xcodebuild archive \
  -project "$ios_proj" \
  -scheme ScreenpunkiOS \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "${RELEASE_DIR}/ios-derived" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE="${PROFILE_UUID}" \
  PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME}"

export_log="${LOG_DIR}/ios-export.log"
echo "=== iOS IPA export (destination=export; no App Store submit) ==="
if ! run_redacted "$export_log" xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_plist"; then
  echo "app-store-connect export failed; retrying method=app-store"
  /usr/libexec/PlistBuddy -c 'Set :method app-store' "$export_plist"
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_plist"
fi

ipa="$(find "$export_dir" -name '*.ipa' -type f | head -n 1)"
if [[ -z "$ipa" ]]; then
  echo "signed IPA export failed: no .ipa in export directory"
  exit 1
fi
cp "$ipa" "${RELEASE_DIR}/Screenpunk.ipa"
echo "STATE: signed-ipa-export"
echo "ipa=${RELEASE_DIR}/Screenpunk.ipa"
echo "STATE: testflight-upload not performed by this script"
echo "STATE: app-store-submission not performed (forbidden in this path)"
