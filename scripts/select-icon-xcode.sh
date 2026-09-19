#!/usr/bin/env bash
# Source in the build process; never changes the system-wide xcode-select setting.
# Honor an explicit DEVELOPER_DIR, otherwise prefer the selected compatible Xcode.
screenpunk_icon_xcode_is_supported() {
  local version major
  version="$(DEVELOPER_DIR="$1" xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p')"
  major="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 26 ]]
}

screenpunk_select_icon_xcode() {
  local candidate host_version host_major
  host_version="$(sw_vers -productVersion 2>/dev/null || true)"
  host_major="${host_version%%.*}"
  if [[ ! "$host_major" =~ ^[0-9]+$ ]] || [[ "$host_major" -lt 26 ]]; then
    echo "Screenpunk Icon Composer builds require a macOS 26+ host (found ${host_version:-unknown})." >&2
    echo "The Mac asset renderer can crash on macOS 15 even with Xcode 26 installed; use the macos-26 CI image." >&2
    return 1
  fi
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    if ! screenpunk_icon_xcode_is_supported "$DEVELOPER_DIR"; then
      echo "Screenpunk app icons require Xcode 26+: DEVELOPER_DIR=$DEVELOPER_DIR" >&2
      return 1
    fi
    return 0
  fi
  candidate="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && screenpunk_icon_xcode_is_supported "$candidate"; then
    export DEVELOPER_DIR="$candidate"
    return 0
  fi
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    [[ -d "$candidate" ]] || continue
    if screenpunk_icon_xcode_is_supported "$candidate"; then
      export DEVELOPER_DIR="$candidate"
      echo "Using $DEVELOPER_DIR for Icon Composer resources"
      return 0
    fi
  done
  echo "Screenpunk app icons require Xcode 26+. Install it or set DEVELOPER_DIR." >&2
  return 1
}
screenpunk_select_icon_xcode
