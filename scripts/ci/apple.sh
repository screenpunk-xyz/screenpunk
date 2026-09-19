#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "apple.sh requires macOS"
  exit 1
fi

echo "=== runner ==="
uname -a
sw_vers || true
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version
  xcodebuild -showsdks || true
else
  echo "xcodebuild is required for apple-build-and-unit"
  exit 1
fi

./scripts/generate-xcode.sh

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required for apple-build-and-unit"
  exit 1
fi

(cd packages/ScreenpunkCore && swift test)
(cd packages/ScreenpunkApple && swift test)
(cd packages/ScreenpunkController && swift test)
(cd tools/screenpunk-mcp && swift build)

# Icon Composer resources require Xcode 26 or newer.
source "$ROOT/scripts/select-icon-xcode.sh"

xcodebuild -version

ios_proj="$ROOT/apps/ios/ScreenpunkiOS.xcodeproj"
if [[ ! -d "$ios_proj" ]]; then
  echo "missing generated iOS project: $ios_proj"
  exit 1
fi

echo "=== iOS 16 compile (iphonesimulator, no signing) ==="
xcodebuild \
  -project "$ios_proj" \
  -scheme ScreenpunkiOS \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$ROOT/.ci-derived/ios" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

sdk_list="$(xcodebuild -showsdks)"
if echo "$sdk_list" | grep -qE 'macosx(2[6-9]|[3-9][0-9])(\.|$)'; then
  echo "=== macOS 26+ SDK present; compiling ScreenpunkMac ==="
  xcodebuild \
    -project "$ROOT/apps/macos/ScreenpunkMac.xcodeproj" \
    -scheme ScreenpunkMac \
    -destination 'generic/platform=macOS,name=Any Mac' \
    -derivedDataPath "$ROOT/.ci-derived/macos" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
else
  echo "MACOS_26_SDK_UNAVAILABLE"
  echo "product Mac app stays macOS 26+; this runner cannot compile that target"
  echo "not treating a missing SDK as Apple UI evidence"
fi

echo "apple-build-and-unit finished"
echo "hidden WKWebView snapshot is attempted by apple-ui-and-preview, not claimed here"
