#!/usr/bin/env bash
# Upload a signed IPA to App Store Connect for TestFlight processing.
# Never submits the build for App Store review.
set +x
set -euo pipefail
# shellcheck source=apple-signing-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple-signing-common.sh"

# No App Store review send is implemented. Do not add one.

require_env ASC_KEY_ID
require_env ASC_ISSUER_ID
require_env ASC_PRIVATE_KEY

ipa="${IPA_PATH:-${RELEASE_DIR}/Screenpunk.ipa}"
if [[ ! -f "$ipa" ]]; then
  echo "signed IPA not found; export must succeed before upload"
  exit 1
fi

write_asc_private_key >/dev/null
log="${LOG_DIR}/ios-testflight-upload.log"

echo "=== App Store Connect upload (TestFlight processing only) ==="
if xcrun --find iTMSTransporter >/dev/null 2>&1; then
  if ! run_redacted "$log" xcrun iTMSTransporter \
    -m upload \
    -assetFile "$ipa" \
    -apiKey "$ASC_KEY_ID" \
    -apiIssuer "$ASC_ISSUER_ID" \
    -v warning; then
    echo "iTMSTransporter upload failed (details redacted)"
    exit 1
  fi
else
  if ! run_redacted "$log" xcrun altool \
    --upload-app \
    --type ios \
    --file "$ipa" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"; then
    echo "altool upload failed (details redacted)"
    exit 1
  fi
fi

echo "STATE: uploaded-to-app-store-connect"
echo "STATE: apple-processing pending on App Store Connect / TestFlight"
echo "STATE: app-store-submission not performed"
echo "STATE: installation pending operator testers after Apple processing"
