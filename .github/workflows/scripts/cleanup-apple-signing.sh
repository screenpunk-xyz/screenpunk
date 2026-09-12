#!/usr/bin/env bash
# Always-run cleanup for temporary Keychain, profiles, and API key files.
set +x
set -euo pipefail
# shellcheck source=apple-signing-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apple-signing-common.sh"
cleanup_apple_signing
echo "removed temporary Apple signing material from the runner"
