#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "apple.sh requires macOS"
  exit 1
fi

# Validate the icon build host and select one toolchain before tests or builds.
source "$ROOT/scripts/select-icon-xcode.sh"

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

# This package currently uses generated XCTest discovery only. Fail closed if
# another framework or custom entry point is added instead of omitting its tests.
if grep -REq '(^|[[:space:]])import[[:space:]]+Testing([[:space:]]|$)|@(Test|Suite)([^[:alnum:]_]|$)' packages/ScreenpunkCore/Tests; then
  echo "direct XCTest runner requires review for Swift Testing tests"
  exit 1
else
  test_search_status=$?
  if (( test_search_status != 1 )); then
    echo "cannot inspect Core test sources"
    exit "$test_search_status"
  fi
fi
if custom_test_entries=$(find packages/ScreenpunkCore/Tests -type f \( -name LinuxMain.swift -o -name XCTestManifests.swift \) -print); then
  if [[ -n "$custom_test_entries" ]]; then
    echo "direct XCTest runner requires generated discovery, not a custom entry point"
    exit 1
  fi
else
  test_search_status=$?
  echo "cannot enumerate Core test entry points"
  exit "$test_search_status"
fi

mkdir -p "$ROOT/.ci-derived"
core_log="$ROOT/.ci-derived/core-apple.log"
# Bypass SwiftPM child-output capture while retaining the full generated suite.
run_full_core_xctest() {
  cd packages/ScreenpunkCore || return $?
  swift build --build-tests || return $?
  core_bin_dir=$(swift build --show-bin-path) || return $?
  core_test_bundle="$core_bin_dir/ScreenpunkCorePackageTests.xctest"
  if [[ ! -d "$core_test_bundle" ]]; then
    echo "missing generated ScreenpunkCore XCTest bundle"
    return 1
  fi
  xcrun xctest "$core_test_bundle"
}
if (run_full_core_xctest) >"$core_log" 2>&1; then
  core_status=0
else
  core_status=$?
fi
tail -n 200 "$core_log"
if (( core_status != 0 )); then
  echo "Core build or full XCTest run failed with exit status $core_status"
  exit "$core_status"
fi
if ! grep -qE "Executed [0-9]+ tests, with 0 failures" "$core_log"; then
  echo "Core XCTest did not report a clean full run"
  exit 1
fi
# SwiftPM buffers XCTest output until the process exits. Run the built XCTest
# bundle directly so a stalled test is visible and bounded on hosted runners.
(
  cd packages/ScreenpunkApple
  swift build --build-tests
  test_bundle="$(swift build --show-bin-path)/ScreenpunkApplePackageTests.xctest"
  python3 "$ROOT/scripts/ci/run-xctest.py" "$test_bundle"
)
(cd tools/screenpunk-distribution && swift test)
(cd packages/ScreenpunkController && swift test)
(cd packages/ScreenpunkAppleController && swift test)
# Match the release workflow: the pinned MCP dependency requires Swift 5 mode
# on Xcode 26; app and package tests above retain their normal settings.
(cd tools/screenpunk-mcp && swift build -Xswiftc -swift-version -Xswiftc 5)

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

python3 scripts/check-apple-runtime-features.py "$ROOT/.ci-derived/ios/Build/Products/Debug-iphonesimulator/Screenpunk.app"

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
  python3 scripts/check-apple-runtime-features.py "$ROOT/.ci-derived/macos/Build/Products/Debug/Screenpunk.app"
else
  echo "MACOS_26_SDK_UNAVAILABLE"
  echo "product Mac app stays macOS 26+; this runner cannot compile that target"
  echo "not treating a missing SDK as Apple UI evidence"
fi

echo "apple-build-and-unit finished"
echo "hidden WKWebView snapshot is attempted by apple-ui-and-preview, not claimed here"
