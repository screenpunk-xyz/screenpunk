#!/usr/bin/env bash
# Shared helpers for Apple release workflows. Never print secret values.
# shellcheck disable=SC2034
set +x
set -euo pipefail

if [[ "${SCREENPUNK_APPLE_SIGNING_COMMON:-}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
SCREENPUNK_APPLE_SIGNING_COMMON=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

WORK_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/screenpunk-apple-signing"
RELEASE_DIR="${RUNNER_TEMP:-$ROOT/.release}/screenpunk-release"
KEYCHAIN_PATH="${WORK_DIR}/app-signing.keychain-db"
CERT_PATH="${WORK_DIR}/signing.p12"
PROFILE_PATH="${WORK_DIR}/ios.mobileprovision"
PROFILE_PLIST="${WORK_DIR}/ios-profile.plist"
ASC_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
LOG_DIR="${WORK_DIR}/logs"

mkdir -p "$WORK_DIR" "$RELEASE_DIR" "$LOG_DIR"
chmod 700 "$WORK_DIR"

mask_value() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    printf '::add-mask::%s\n' "$value"
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required apple-release input: ${name}"
    echo "set it on the GitHub environment apple-release; do not paste values into issues, chat, or source"
    exit 1
  fi
}

filter_auth_log() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  sed -e '/-----BEGIN/,/-----END/d' \
      -e '/[Bb]earer /d' \
      -e '/[Pp]assword/d' \
      -e '/passwd/d' \
      -e '/private[[:space:]]*key/Id' \
      -e '/apiKey/d' \
      -e '/api_key/d' \
      "$path" || true
}

run_redacted() {
  local log="$1"
  shift
  set +e
  "$@" >"$log" 2>&1
  local status=$?
  set -e
  filter_auth_log "$log"
  return "$status"
}

decode_base64_to_file() {
  local dest="$1"
  umask 077
  # Reads stdin; works with wrapped or unwrapped base64.
  base64 --decode >"$dest"
  chmod 600 "$dest"
}

enable_generated_signing() {
  local pbx="$1/project.pbxproj"
  if [[ ! -f "$pbx" ]]; then
    echo "missing generated project: ${pbx}"
    exit 1
  fi
  # Ephemeral generated project only. Source project.yml stays unsigned for PR CI.
  sed -i.bak 's/CODE_SIGNING_ALLOWED = NO/CODE_SIGNING_ALLOWED = YES/g' "$pbx"
  rm -f "${pbx}.bak"
}

write_asc_private_key() {
  require_env ASC_KEY_ID
  require_env ASC_PRIVATE_KEY
  mkdir -p "$ASC_KEY_DIR"
  chmod 700 "$ASC_KEY_DIR"
  local dest="${ASC_KEY_DIR}/AuthKey_${ASC_KEY_ID}.p8"
  umask 077
  printf '%s\n' "$ASC_PRIVATE_KEY" >"$dest"
  chmod 600 "$dest"
  printf '%s\n' "$dest"
}

cleanup_apple_signing() {
  set +e
  if [[ -f "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1
  fi
  rm -f "$CERT_PATH" "$PROFILE_PATH" "$PROFILE_PLIST"
  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    rm -f "${ASC_KEY_DIR}/AuthKey_${ASC_KEY_ID}.p8"
  fi
  if [[ -n "${INSTALLED_PROFILE_PATH:-}" && -f "${INSTALLED_PROFILE_PATH}" ]]; then
    rm -f "$INSTALLED_PROFILE_PATH"
  fi
  rm -rf "$WORK_DIR"
  set -e
}

import_p12() {
  local p12_b64_var="$1"
  local password_var="$2"
  require_env "$p12_b64_var"
  require_env "$password_var"

  if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
    KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
  fi
  mask_value "$KEYCHAIN_PASSWORD"
  mask_value "${!password_var}"

  printf '%s' "${!p12_b64_var}" | decode_base64_to_file "$CERT_PATH"

  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  # Do not print import output; it can include certificate details and errors with material.
  if ! security import "$CERT_PATH" -P "${!password_var}" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null 2>&1; then
    echo "certificate import failed (details redacted)"
    exit 1
  fi
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  security list-keychain -d user -s "$KEYCHAIN_PATH" login.keychain-db
  echo "imported signing certificate into a temporary keychain"
}

install_ios_profile() {
  require_env IOS_PROVISIONING_PROFILE_BASE64
  printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | decode_base64_to_file "$PROFILE_PATH"
  security cms -D -i "$PROFILE_PATH" >"$PROFILE_PLIST" 2>/dev/null
  PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$PROFILE_PLIST")"
  PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print Name' "$PROFILE_PLIST")"
  if [[ -z "${PROFILE_UUID:-}" || -z "${PROFILE_NAME:-}" ]]; then
    echo "provisioning profile UUID or Name missing"
    exit 1
  fi
  local dest_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$dest_dir"
  INSTALLED_PROFILE_PATH="${dest_dir}/${PROFILE_UUID}.mobileprovision"
  cp "$PROFILE_PATH" "$INSTALLED_PROFILE_PATH"
  echo "installed iOS distribution profile (name printed, contents not dumped)"
  echo "profile_name=${PROFILE_NAME}"
}

require_macos_26_sdk() {
  local sdk_list
  sdk_list="$(xcodebuild -showsdks)"
  if ! echo "$sdk_list" | grep -qE 'macosx(2[6-9]|[3-9][0-9])(\.|$)'; then
    echo "MACOS_26_SDK_UNAVAILABLE"
    echo "Mac release requires a hosted image with the macOS 26 SDK; unsigned CI may still compile iOS"
    exit 1
  fi
}
