#!/usr/bin/env bash
# Attempt a hidden AppKit/WKWebView snapshot on macOS. Never write a placeholder PNG.
# Exit 0 after an honest SNAPSHOT_UNAVAILABLE record when the runner cannot produce one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SNAPSHOT_UNAVAILABLE reason=not_darwin"
  echo "preview.sh requires macOS; this host cannot produce WKWebView evidence"
  exit 1
fi

test -f tools/preview-host/project.yml
test -f apps/ios/project.yml
test -f apps/macos/project.yml

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "SNAPSHOT_UNAVAILABLE reason=no_xcodebuild"
  echo "xcodebuild is required to compile the preview helper"
  exit 1
fi

./scripts/generate-xcode.sh

preview_proj="$ROOT/tools/preview-host/ScreenpunkPreviewHost.xcodeproj"
if [[ ! -d "$preview_proj" ]]; then
  echo "missing generated preview-host project"
  exit 1
fi

derived="$ROOT/.ci-derived/preview"
echo "=== compiling preview-host (feasibility helper, macOS 14 deploy) ==="
if ! xcodebuild \
  -project "$preview_proj" \
  -scheme ScreenpunkPreviewHost \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
then
  echo "SNAPSHOT_UNAVAILABLE reason=preview_host_compile_failed"
  echo "recorded compile failure; not substituting a fake PNG"
  mkdir -p "$ROOT/tests/feasibility/preview"
  printf '%s\n' "SNAPSHOT_UNAVAILABLE reason=preview_host_compile_failed" \
    > "$ROOT/tests/feasibility/preview/last-attempt.txt"
  exit 0
fi

app="$(find "$derived/Build/Products" -name 'ScreenpunkPreviewHost.app' -print -quit || true)"
if [[ -z "$app" || ! -x "$app/Contents/MacOS/ScreenpunkPreviewHost" ]]; then
  echo "SNAPSHOT_UNAVAILABLE reason=preview_host_binary_missing"
  mkdir -p "$ROOT/tests/feasibility/preview"
  printf '%s\n' "SNAPSHOT_UNAVAILABLE reason=preview_host_binary_missing" \
    > "$ROOT/tests/feasibility/preview/last-attempt.txt"
  exit 0
fi

out="$ROOT/tests/feasibility/preview/last-snapshot.png"
rm -f "$out"
mkdir -p "$(dirname "$out")"
attempt="$ROOT/tests/feasibility/preview/last-attempt.txt"

set +e
SCREENPUNK_SNAPSHOT=1 \
SCREENPUNK_SNAPSHOT_OUT="$out" \
"$app/Contents/MacOS/ScreenpunkPreviewHost" >"$attempt.stdout" 2>"$attempt"
status=$?
set -e
if [[ -s "$attempt.stdout" ]]; then
  cat "$attempt.stdout"
fi
if [[ -s "$attempt" ]]; then
  cat "$attempt" >&2
fi

if [[ -f "$out" ]]; then
  magic="$(xxd -p -l 8 "$out" 2>/dev/null || true)"
  if [[ "$magic" == 89504e470d0a1a0a* ]]; then
    echo "SNAPSHOT_OK path=${out}"
    echo "real PNG produced by WKWebView takeSnapshot; dimensions/contents still need review"
    package_out="$ROOT/tests/feasibility/preview/last-package-snapshot.png"
    rm -f "$package_out"
    set +e
    SCREENPUNK_SNAPSHOT=1 \
    SCREENPUNK_PACKAGE_DIR="$ROOT/examples/offline-fixture" \
    SCREENPUNK_SNAPSHOT_OUT="$package_out" \
    SCREENPUNK_READY_TIMEOUT=20 \
    "$app/Contents/MacOS/ScreenpunkPreviewHost" >>"$attempt.stdout" 2>>"$attempt"
    set -e
    if [[ -f "$package_out" ]]; then
      package_magic="$(xxd -p -l 8 "$package_out" 2>/dev/null || true)"
      if [[ "$package_magic" == 89504e470d0a1a0a* ]]; then
        echo "PACKAGE_SNAPSHOT_OK path=${package_out}"
      else
        echo "PACKAGE_SNAPSHOT_UNAVAILABLE reason=not_png"
        rm -f "$package_out"
      fi
    else
      echo "PACKAGE_SNAPSHOT_UNAVAILABLE — recorded; not substituting a placeholder"
    fi
    exit 0
  fi
  echo "SNAPSHOT_UNAVAILABLE reason=not_png"
  echo "wrote a file that is not a PNG; deleting it so it cannot be treated as evidence"
  rm -f "$out"
  printf '%s\n' "SNAPSHOT_UNAVAILABLE reason=not_png status=${status}" > "$attempt"
  exit 0
fi

if ! grep -q "SNAPSHOT_UNAVAILABLE" "$attempt" 2>/dev/null; then
  printf '%s\n' "SNAPSHOT_UNAVAILABLE reason=no_image status=${status}" > "$attempt"
fi
echo "SNAPSHOT_UNAVAILABLE — no real PNG. Not substituting a placeholder."
exit 0
