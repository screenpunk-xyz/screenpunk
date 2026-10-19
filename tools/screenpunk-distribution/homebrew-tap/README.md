# Screenpunk Homebrew tap — 1.0.2 final candidate

**Final local artifact; public publication pending.** Apple accepted submission
`bcf65310-83d1-4808-9cdd-ad454291ca8c`; the ticket is stapled and Gatekeeper
accepts the final DMG as Notarized Developer ID. Its final SHA-256 is
`2a50c732bbff31ab330b1dd589f601b270db9216be8b641ed6e8b039f40c3749`.

The cask has this final checksum. Publish the exact DMG at cli-v1.0.2 and verify
the hosted fetch before publishing the cask or advertising these commands.
Once published, install on Apple silicon with macOS14+
and standard /opt/homebrew, as the normal user without sudo:

```sh
brew tap screenpunk-xyz/tap https://github.com/screenpunk-xyz/homebrew-tap
brew install --cask screenpunk-cli
screenpunk setup
screenpunk doctor
screenpunk service status
screenpunk agent config --client codex
```

The cask directly links screenpunk and screenpunk-mcp. The first setup/workspace
request or MCP invocation prepares the verified bundled offline authoring kit
and starts the owned user LaunchAgent. No screenpunk-setup command, separate
installer, private software copy, or ~/.local/bin PATH edit is required.
Agent configuration is emitted for review; user configuration is not edited.
Pairing and deployment retain their human approval steps.

Use the same macOS account to install and use this release. Shared multi-account
prefixes, nonstandard Homebrew prefixes, Intel Macs, and macOS before14 are not
supported by this artifact. No Xcode or Screenpunk GUI app is required.

```sh
brew upgrade --cask screenpunk-cli
brew uninstall --cask screenpunk-cli
```

Both stop the exact verified service before software removal. Upgrade starts the
new service on next use. Workspace sources, external projects, machine state,
installed kits, and Keychain entries remain. Keep agent configuration only while
the CLI is installed; remove its Screenpunk entry manually if no longer wanted.

If activation fails, inspect `screenpunk service logs` and
`launchctl print gui/$(id -u)/com.screenpunk.workbench`, then retry
`screenpunk service start` after resolving the reported cause. If Brew removal
is interrupted after deactivation, retry the Brew operation; a successful
`brew reinstall --cask screenpunk-cli` rearms that package for first use.
An uncertain or mismatched running broker blocks removal while software remains.

Studio currently has 1.0.1 after the old disposable reset. After verified
publication, upgrade normally to 1.0.2. Its exact-checkpoint journal recovery
preserves Keychain and existing trust history. Do not rerun the old reset or
purge Toolchains. Unmatched history remains closed with a classified
preparation reason before service activation.

Publication remains: matching public DMG/sidecar, cask update in the tap, hosted
fetch validation, then clean Studio activation/upgrade/removal. Signed artifact,
notarization/staple, checksum, and independent source review are complete.
