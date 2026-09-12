#!/usr/bin/env bash
# Install the pinned XcodeGen 2.46.0 release onto PATH.
# Prints the directory that contains the `xcodegen` binary (stdout).
# Logs go to stderr so callers can `export PATH="$(./scripts/ci/install-xcodegen.sh):$PATH"`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.46.0}"
XCODEGEN_URL="${XCODEGEN_URL:-https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip}"
XCODEGEN_SHA256="${XCODEGEN_SHA256:-4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806}"
TOOLS_ROOT="${SCREENPUNK_TOOLS:-$ROOT/.tools}"
DEST="${TOOLS_ROOT}/xcodegen-${XCODEGEN_VERSION}"
BIN_DIR="${DEST}/bin"

log() { printf '%s\n' "$*" >&2; }

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    log "need shasum or sha256sum to verify XcodeGen"
    exit 1
  fi
}

version_of() {
  local bin="$1"
  "$bin" --version 2>/dev/null || true
}

matches_pin() {
  local text="$1"
  [[ "$text" == *"$XCODEGEN_VERSION"* ]]
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  log "XcodeGen ${XCODEGEN_VERSION} is a macOS tool; refusing to install on $(uname -s)"
  exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
  installed="$(version_of xcodegen)"
  if matches_pin "$installed"; then
    log "using existing xcodegen on PATH: ${installed}"
    dirname "$(command -v xcodegen)"
    exit 0
  fi
  log "ignoring PATH xcodegen (${installed}); want ${XCODEGEN_VERSION}"
fi

if [[ -x "${BIN_DIR}/xcodegen" ]]; then
  installed="$(version_of "${BIN_DIR}/xcodegen")"
  if matches_pin "$installed"; then
    log "using cached ${BIN_DIR}/xcodegen: ${installed}"
    printf '%s\n' "$BIN_DIR"
    exit 0
  fi
  log "cached binary is ${installed}; reinstalling ${XCODEGEN_VERSION}"
  rm -rf "$DEST"
fi

mkdir -p "$TOOLS_ROOT"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/xcodegen.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

zip_path="${tmp}/xcodegen.zip"
log "downloading XcodeGen ${XCODEGEN_VERSION}"
curl -fsSL --retry 4 --retry-delay 2 -o "$zip_path" "$XCODEGEN_URL"

got="$(sha256_file "$zip_path")"
if [[ "$got" != "$XCODEGEN_SHA256" ]]; then
  log "XcodeGen zip SHA-256 mismatch"
  log "  expected ${XCODEGEN_SHA256}"
  log "  got      ${got}"
  exit 1
fi

unzip -q "$zip_path" -d "$tmp"
if [[ ! -x "${tmp}/xcodegen/bin/xcodegen" ]]; then
  log "xcodegen.zip did not contain xcodegen/bin/xcodegen"
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$TOOLS_ROOT"
mv "${tmp}/xcodegen" "$DEST"

installed="$(version_of "${BIN_DIR}/xcodegen")"
if ! matches_pin "$installed"; then
  log "installed binary version is ${installed}, expected ${XCODEGEN_VERSION}"
  exit 1
fi

log "installed xcodegen: ${installed}"
printf '%s\n' "$BIN_DIR"
