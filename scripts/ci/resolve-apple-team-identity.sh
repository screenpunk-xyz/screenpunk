#!/usr/bin/env bash
# Resolve one usable code-signing identity for Screenpunk's committed team.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: resolve-apple-team-identity.sh REQUESTED_IDENTITY CERTIFICATE_TYPE" >&2
  exit 64
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
config="${root}/config/apple-team.xcconfig"
team="$(sed -nE 's/^SCREENPUNK_APPLE_TEAM_ID[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' "$config")"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "public Apple team configuration is missing or invalid" >&2
  exit 1
fi
security find-identity -v -p codesigning \
  | python3 "${root}/scripts/ci/select-apple-signing-identity.py" "$team" "$2" "$1"
