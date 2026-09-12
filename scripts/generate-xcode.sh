#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.46.0}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen ${XCODEGEN_VERSION} is required on macOS. Install that pin and rerun."
  exit 1
fi

installed="$(xcodegen --version 2>/dev/null || true)"
echo "xcodegen: ${installed}"

generate() {
  local spec="$1"
  (cd "$(dirname "$spec")" && xcodegen generate --spec "$(basename "$spec")")
}

generate "$ROOT/apps/ios/project.yml"
generate "$ROOT/apps/macos/project.yml"
generate "$ROOT/tools/preview-host/project.yml"
echo "generated Xcode projects from specs"
