#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.46.0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "generate-xcode.sh requires macOS"
  exit 1
fi

XCODEGEN_BIN_DIR="$("$ROOT/scripts/ci/install-xcodegen.sh")"
export PATH="${XCODEGEN_BIN_DIR}:$PATH"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen ${XCODEGEN_VERSION} is required on macOS after install"
  exit 1
fi

installed="$(xcodegen --version 2>/dev/null || true)"
if [[ "$installed" != *"$XCODEGEN_VERSION"* ]]; then
  echo "xcodegen pin mismatch: ${installed} (want ${XCODEGEN_VERSION})"
  exit 1
fi
echo "xcodegen: ${installed}"

generate() {
  local spec="$1"
  (cd "$(dirname "$spec")" && xcodegen generate --spec "$(basename "$spec")")
}

generate "$ROOT/apps/ios/project.yml"
generate "$ROOT/apps/macos/project.yml"
generate "$ROOT/tools/preview-host/project.yml"
echo "generated Xcode projects from specs"
