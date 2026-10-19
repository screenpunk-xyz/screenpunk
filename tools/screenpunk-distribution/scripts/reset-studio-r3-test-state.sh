#!/bin/bash
# Only the user-approved disposable r3 test state on Generator is in scope.
# Preserve Toolchains with its catalog journal alongside the Keychain checkpoint.
# Default is preflight only. --apply performs the checked removal.
set -euo pipefail
apply=false
case "${1-}" in '') ;; --apply) apply=true;; *) echo 'usage: reset-studio-r3-test-state.sh [--apply]' >&2; exit 64;; esac
[ "$#" -le 1 ] || exit 64
die() { echo "Reset stopped: $*" >&2; exit 1; }
[ "$(id -u)" = 503 ] && [ "$(id -un)" = generator ] && [ "$HOME" = /Users/generator ] ||
  die 'This reset is only for generator (uid 503) on the tested Studio.'
[ "$(/opt/homebrew/bin/brew --prefix)" = /opt/homebrew ] || die 'Unexpected Homebrew prefix.'
installedCasks=$(/opt/homebrew/bin/brew list --cask --versions) || die 'Cannot inspect installed casks.'
cask=$(printf '%s\n' "$installedCasks" | /usr/bin/awk '$1 == "screenpunk-cli" { print }')
case "$cask" in ''|'screenpunk-cli 1.0.0') ;; *) die 'Unexpected cask version.';; esac
root=/Users/generator/.local/share/screenpunk
state='/Users/generator/Library/Application Support/Screenpunk'
plist=/Users/generator/Library/LaunchAgents/com.screenpunk.workbench.plist
target=gui/503/com.screenpunk.workbench
cli=/Users/generator/.local/bin/screenpunk
mcp=/Users/generator/.local/bin/screenpunk-mcp
owned() { [ "$(/usr/bin/stat -f '%u' "$1")" = 503 ] || die "Unexpected owner: $1"; }
directory() { [ -d "$1" ] && [ ! -L "$1" ] || die "Expected real directory: $1"; owned "$1"; }
regular() { [ -f "$1" ] && [ ! -L "$1" ] || die "Expected regular file: $1"; owned "$1"; }
link() { [ -L "$1" ] && [ "$(/usr/bin/readlink "$1")" = "$2" ] || die "Unexpected link: $1"; owned "$1"; }
present() { [ -e "$1" ] || [ -L "$1" ]; }
optionalLink() { if present "$1"; then link "$1" "$2"; fi; }
for parent in /Users/generator /Users/generator/.local /Users/generator/.local/share \
  /Users/generator/.local/bin /Users/generator/Library \
  '/Users/generator/Library/Application Support' /Users/generator/Library/LaunchAgents; do
  directory "$parent"
done
legacyPresent=false
if present "$root"; then
  legacyPresent=true
  directory "$root"; directory "$root/versions"; directory "$root/versions/1.0.0"
  regular "$root/installation.json"; link "$root/current" versions/1.0.0
fi
if present "$state"; then directory "$state"; fi
optionalLink "$cli" "$root/current/bin/screenpunk"
optionalLink "$mcp" "$root/current/bin/screenpunk-mcp"
extract() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
if $legacyPresent; then
[ "$(extract "$root/installation.json" owner)" = screenpunk-workbench-v1 ] &&
  [ "$(extract "$root/installation.json" schemaVersion)" = 1 ] &&
  [ "$(extract "$root/installation.json" canonicalRoot)" = "$root" ] || die 'Installation marker mismatch.'
fi
if present "$plist"; then
regular "$plist"
[ "$(extract "$plist" Label)" = com.screenpunk.workbench ] || die 'LaunchAgent label mismatch.'
expected=("$root/current/libexec/screenpunk-service" --foreground --home "$state/Controller" --runtime-directory "$state/Runtime")
for index in 0 1 2 3 4 5; do
  [ "$(extract "$plist" "ProgramArguments.$index")" = "${expected[$index]}" ] || die 'LaunchAgent arguments mismatch.'
done
if extract "$plist" ProgramArguments.6 >/dev/null 2>&1; then die 'Unexpected extra service arguments.'; fi
[ "$(extract "$plist" RunAtLoad)" = false ] && [ "$(extract "$plist" KeepAlive)" = false ] || die 'Unexpected launch policy.'
fi
shopt -s dotglob nullglob
if $legacyPresent; then
for entry in "$root"/*; do
  case "$entry" in "$root/current"|"$root/versions"|"$root/installation.json") ;; *) die "Unexpected installation member: $entry";; esac
done
for entry in "$root/versions"/*; do [ "$entry" = "$root/versions/1.0.0" ] || die 'Unexpected installed version.'; done
fi
for entry in "$state"/*; do
  case "$entry" in "$state/Controller"|"$state/Runtime"|"$state/Logs"|"$state/Toolchains") ;; *) die "Unexpected state member: $entry";; esac
done
for tree in "$root" "$state"; do
  present "$tree" || continue
  unexpected=$(/usr/bin/find -x "$tree" ! -user generator -print)
  [ -z "$unexpected" ] || die "Non-owned files under $tree"
done
jobPresent=false
errorFile=$(/usr/bin/mktemp /private/tmp/screenpunk-studio-reset.XXXXXXXX)
trap '/bin/rm -f -- "$errorFile"' EXIT
if job=$(/bin/launchctl print "$target" 2>"$errorFile"); then
jobPresent=true
[[ "$job" == *'state = not running'* ]] || die 'Service state changed; a running/unknown service needs fresh diagnosis.'
if echo "$job" | /usr/bin/grep -Eq '^[[:space:]]*pid = [1-9][0-9]*'; then die 'Service has a process.'; fi
loaded=$(echo "$job" | /usr/bin/sed 's/^[[:space:]]*//')
echo "$loaded" | /usr/bin/grep -Fxq "path = $plist" || die 'Loaded plist path mismatch.'
echo "$loaded" | /usr/bin/grep -Fxq "program = $root/current/libexec/screenpunk-service" || die 'Loaded executable mismatch.'
loadedArgs=$(echo "$loaded" | /usr/bin/sed -n '/^arguments = {$/,/^}$/p' | /usr/bin/sed '1d;$d')
expectedArgs=$(printf '%s\n' "$root/current/libexec/screenpunk-service" --foreground --home "$state/Controller" --runtime-directory "$state/Runtime")
[ "$loadedArgs" = "$expectedArgs" ] || die 'Loaded service arguments mismatch.'
else
  status=$?
  [ "$status" = 113 ] && /usr/bin/grep -Fq 'Could not find service "com.screenpunk.workbench" in domain for user gui: 503' "$errorFile" ||
    die 'Cannot verify job absence; do not infer absence from another error.'
fi
echo 'Verified exact owned r3 resources (already removed resources are accepted for resuming cleanup).'
echo 'Apply will unregister that job, uninstall the bootstrap cask, and remove only these exact paths:'
printf '%s\n' "$plist" "$cli" "$mcp" "$root" "$state/Controller" "$state/Runtime" "$state/Logs"
echo 'Toolchains (including its catalog journal), Keychain items and unrelated files/software are retained.'
$apply || exit 0
if $jobPresent; then
  /bin/launchctl bootout "$target"
  if /bin/launchctl print "$target" >/dev/null 2>"$errorFile"; then die 'Job remains registered after bootout.'; else
    status=$?
    [ "$status" = 113 ] && /usr/bin/grep -Fq 'Could not find service "com.screenpunk.workbench" in domain for user gui: 503' "$errorFile" ||
      die 'Cannot verify job absence after bootout.'
  fi
fi
if [ -n "$cask" ]; then /opt/homebrew/bin/brew uninstall --cask screenpunk-xyz/tap/screenpunk-cli; fi
# Recheck exact ownership/link targets after Homebrew completes.
if present "$plist"; then regular "$plist"; /bin/rm -- "$plist"; fi
for launcher in "$cli" "$mcp"; do
  present "$launcher" || continue
  optionalLink "$launcher" "$root/current/bin/$(basename "$launcher")"
  /bin/rm -- "$launcher"
done
for tree in "$root" "$state/Controller" "$state/Runtime" "$state/Logs"; do
  present "$tree" || continue
  directory "$tree"
  /bin/rm -rf -- "$tree"
done
echo 'Removed the disposable r3 runtime. Toolchains/catalog journals and Keychain items remain.'
