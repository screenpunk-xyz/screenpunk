# First Studio activation failure: read-only diagnostics

The reported `installation_recovery_required` means activation failed and its
recovery also failed. The production cleanup path contacts the broker before
unregistering it, so a broker that never became reachable can produce this
result. The original activation error is currently hidden by that result.
Registration, process startup, and health verification remain possible causes.

Run these commands in the same Studio account that ran setup. They inspect
state and do not retry installation, start a service, or remove files.

```sh
/bin/launchctl print "gui/$(id -u)/com.screenpunk.workbench"
/bin/ls -ld "$HOME/.local/share/screenpunk/current" \
  "$HOME/.local/share/screenpunk/versions/1.0.0" \
  "$HOME/.local/bin/screenpunk" "$HOME/.local/bin/screenpunk-mcp" \
  "$HOME/Library/LaunchAgents/com.screenpunk.workbench.plist"
/usr/bin/tail -n 40 "$HOME/Library/Application Support/Screenpunk/Logs/service.log"
"/opt/homebrew/Caskroom/screenpunk-cli/1.0.0/Screenpunk CLI 1.0.0/bin/screenpunk" \
  --json --no-input --timeout 2 service status
```

The launchd result distinguishes an absent registration from a registered
process with an exit status. The service log can retain its startup error even
when there is no broker socket. The staged CLI status command is available
even if the per-user launcher is absent. Missing-file or unavailable results
are useful evidence; keep them with the command output.

Do not rerun setup or remove installation state until this evidence identifies
the failed phase and the current ownership/runtime state. The frozen r3 image
has not been changed by this investigation.
