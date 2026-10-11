#!/usr/bin/env bash
# Archive and export a signed iOS IPA. Does not upload and does not submit.
set +x
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/validate-ios-release-metadata.py" inputs

# shellcheck source=apple-signing-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple-signing-common.sh"

# Icon Composer resources require Xcode 26 or newer.
source "$ROOT/scripts/select-icon-xcode.sh"

# Only the reviewed protected staging input may configure this internal archive.
require_env IOS_STAGING_INFO_PLIST_BASE64
require_env IOS_STAGING_INFO_SHA256
staging_info="${WORK_DIR}/Info-staging.plist"
validate_staging_info() {
  python3 - "$1" "$ROOT" "$WORK_DIR" "${2:-}" <<'PY_STAGING'
import base64
import hashlib
import importlib.util
import os
import plistlib
import re
import stat
import sys
import zipfile

mode, root, work, artifact = sys.argv[1:]

def fail(key):
    raise ValueError(key)

def bounded_plist(path, limit=262144):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            fail("InfoPlist")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            fail("InfoPlist")
        return plistlib.loads(raw)
    finally:
        os.close(fd)

try:
    encoded = os.environ.get("IOS_STAGING_INFO_PLIST_BASE64", "")
    digest = os.environ.get("IOS_STAGING_INFO_SHA256", "")
    if len(encoded) > 349528 or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("IOS_STAGING_INFO_SHA256")
    raw = base64.b64decode(encoded, validate=True)
    if not raw or len(raw) > 262144 or hashlib.sha256(raw).hexdigest() != digest:
        fail("IOS_STAGING_INFO_PLIST_BASE64")
    supplied = plistlib.loads(raw)
    if not isinstance(supplied, dict):
        fail("InfoPlist")
    template = bounded_plist(os.path.join(root, "apps/ios/Info.plist"))
    spec = importlib.util.spec_from_file_location("staging_generator", os.path.join(root, "scripts/generate-ios-staging-config.py"))
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    firebase = {key: supplied.get(info_key) for key, info_key in generator.FIELDS.items()}
    firebase["IS_ANALYTICS_ENABLED"] = False
    expected = generator.build_info(firebase, template, expected_project="screenpunk-stg-6f6e615a",
        expected_bundle="xyz.screenpunk.ios", api_origin="https://staging.screenpunk.xyz")
    # Equality also preserves every unrelated template key and Calendar entry.
    if supplied != expected:
        fail("InfoTemplate")
    if mode == "prepare":
        directory = os.open(work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fd = os.open("Info-staging.plist", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "wb", closefd=False) as stream:
                    stream.write(raw)
                    stream.flush()
                os.fsync(fd)
            finally:
                os.close(fd)
            os.fsync(directory)
        finally:
            os.close(directory)
    elif mode in ("archive", "ipa"):
        if mode == "archive":
            actual = bounded_plist(os.path.join(artifact, "Products/Applications/Screenpunk.app/Info.plist"))
        else:
            with zipfile.ZipFile(artifact) as archive:
                members = [i for i in archive.infolist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", i.filename)]
                if len(members) != 1 or members[0].file_size > 262144:
                    fail("IPAInfoPlist")
                actual = plistlib.loads(archive.read(members[0]))
        if not isinstance(actual, dict):
            fail("InfoPlist")
        for key in list(generator.FIELDS.values()) + ["ScreenpunkCloudAPIOrigin"]:
            if actual.get(key) != expected[key]:
                fail(key)
        urls = actual.get("CFBundleURLTypes")
        if not isinstance(urls, list):
            fail("CFBundleURLTypes")
        cloud = [v for v in urls if isinstance(v, dict) and v.get("CFBundleURLName") == "Screenpunk Cloud OAuth"]
        if len(cloud) != 1 or cloud[0].get("CFBundleURLSchemes") != [expected["ScreenpunkCloudGoogleCallbackScheme"]]:
            fail("ScreenpunkCloudGoogleCallbackScheme")
        calendar = [v for v in urls if isinstance(v, dict) and v.get("CFBundleURLName") == "Google Calendar OAuth"]
        # The existing Release settings deliberately leave Calendar unconfigured.
        if len(calendar) != 1 or calendar[0].get("CFBundleURLSchemes") != [""] or actual.get("ScreenpunkGoogleCalendarClientID") != "":
            fail("GoogleCalendarReleaseConfiguration")
        metadata = {"CFBundleIdentifier": "xyz.screenpunk.ios", "CFBundleShortVersionString": os.environ["IOS_MARKETING_VERSION"],
            "CFBundleVersion": os.environ["IOS_BUILD_NUMBER"], "MinimumOSVersion": "16.0", "UIDeviceFamily": [1, 2]}
        for key, value in metadata.items():
            if actual.get(key) != value:
                fail(key)
    else:
        fail("ValidationMode")
except Exception:
    # Never render exception text, plist contents, credentials, or URLs.
    print("staging archive configuration validation failed", file=sys.stderr)
    sys.exit(1)
print("staging archive configuration validated (" + mode + ")")
PY_STAGING
}
validate_staging_info prepare

require_apple_team_id
import_p12 IOS_SIGNING_CERT_P12_BASE64 IOS_SIGNING_CERT_PASSWORD "Apple Distribution"
install_ios_profile

./scripts/generate-xcode.sh
ios_proj="${ROOT}/apps/ios/ScreenpunkiOS.xcodeproj"

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
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "${RELEASE_DIR}/ios-derived" \
  MARKETING_VERSION="${IOS_MARKETING_VERSION}" \
  CURRENT_PROJECT_VERSION="${IOS_BUILD_NUMBER}" \
  INFOPLIST_FILE="$staging_info" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY_SHA1}" \
  PROVISIONING_PROFILE="${PROFILE_UUID}" \
  PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME}"

validate_staging_info archive "$archive_path"

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
python3 "$ROOT/.github/workflows/scripts/validate-ios-release-metadata.py" ipa "$ipa"
validate_staging_info ipa "$ipa"
cp "$ipa" "${RELEASE_DIR}/Screenpunk.ipa"
echo "STATE: signed-ipa-export"
echo "ipa=${RELEASE_DIR}/Screenpunk.ipa"
echo "STATE: testflight-upload not performed by this script"
echo "STATE: app-store-submission not performed (forbidden in this path)"
