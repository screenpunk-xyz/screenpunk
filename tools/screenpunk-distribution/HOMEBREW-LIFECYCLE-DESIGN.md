# Homebrew-owned package lifecycle

Status: 1.0.2 built, signed, Apple accepted, stapled, and verified locally.
Public publication and clean Studio lifecycle qualification remain.
The public 1.0.1 release remains immutable; 1.0.2 adds exact-checkpoint
catalog journal recovery and classified errors before service activation.

## Studio cause and correction

Studio launchd registration/execution succeeded (gui/503, runs 1, exit 8),
but startup logged release_untrusted. The startup guard compared standardized
URLs whose directory trailing-slash forms differed before Controller existed.
InstallationPaths.validateServiceDirectories now compares exact standardized
paths and is integrated into installedServiceTrust. Full signed-release,
executable identity, and fixed home/runtime directory checks remain.

## Ownership and first use

The cask links screenpunk and screenpunk-mcp directly into the standard arm64
Homebrew prefix /opt/homebrew from its versioned Caskroom release. No second
software copy, ~/.local selector, or private command launcher is created.
The same macOS account installs and uses this private, ownership-verified
package; nonstandard prefixes and multi-account sharing are unsupported.

Brew installer script invokes package rearm: verify the release and clear only this
root's removal fence. It imports no kit, writes no LaunchAgent, and starts no
process. Persistent activation is deliberately outside Brew install rollback.

The first setup/workspace/ordinary broker request or MCP startup verifies the
package, imports its exact signed offline kit, and starts its owned launchd
job. service start and idle reconnect use launchctl kickstart, never a detached
Process for this package. service run --foreground is refused for the package
CLI. Source-development foreground paths remain outside production authority.
Read-only service status/lifecycle and doctor do not auto-start a missing broker.
Pairing, credential, migration, and deployment approval flows are unchanged.

## Removal and upgrades

Brew uninstall script invokes the staged signed CLI's package deactivate
before unlinking commands or purging staging. It verifies the complete package,
exact disk plist, loaded launchd path/program/arguments, broker home, and native
running executable identity. Live verified brokers drain/stop; positively owned
stopped jobs can unregister without a reachable broker. Unknown/mismatched jobs
fail closed, leaving Brew software available. A separate controller-owner lock
blocks cleanup if an unregistered broker still owns that home.

A private lifecycle lock serializes package requests. Successful deactivation
also atomically publishes a root-specific removal fence, so an invocation after
the hook returns cannot restart the service before Brew deletes its root.
A reinstall or upgrade's process-free installer command clears the relevant
fence. Failed fence publication leaves no partial marker and can be retried.

Upgrade stops the previous service, retains user state, and installs the new
package. The new service starts on next use. Homebrew rollback restores old
software and its installer command rearms the old root; it also starts on next use.
No website instructions should promise immediate service activation during
Brew install, upgrade, or rollback.

User data, workspaces, external projects, kits, and Keychain entries are outside
Brew software deletion. The CLI legacy install/update/uninstall routes refuse
Homebrew-managed invocations and direct users to brew. Legacy software ownership
is a conflict requiring explicit recovery, not silent adoption or deletion.

## Recovery and evidence

Fresh activation failure preserves the original startup cause and cleanup
cause in separate fields. Successful cleanup removes only the owned plist;
failed cleanup retains resources for diagnosis. service logs exposes recognized
redacted events even when failed startup recovery removed the plist.

Disposable-root tests cover fresh start, idle reconnect/removal, absent job
with retained plist, never-activated removal, unreachable live broker, unknown
state, detached owner, legacy software conflict, removal fence interleaving,
failed fence publication/retry, and rearm rejection on unknown job state.
Production prefix classification and error presentation have focused CLI tests.
No personal-host activation, runtime installation, or Studio cleanup was run.
Isolated /tmp Brew staging tests cover cask artifact mechanics, not the actual
/opt/homebrew production managed service; the clean Studio test remains needed.

## Signing

Build-homebrew-release.sh rebuilds and signs CLI/MCP/service for a new immutable
version, authenticates the old release before reusing its signed offline kit,
and compares the retained catalog and kit archive byte-for-byte. Catalog
sequence 1 must not be re-signed with different payload at the same sequence.
Original 1.0.0 DMG and public release assets are never overwritten.

## Completed-artifact startup gate

Homebrew installer scripts run before binary artifacts. Rearm therefore captures
the previous config.json inode/mtime in an atomic root-specific install gate.
Startup requires a new config record (written atomically after all artifacts
succeed), a committed arm64 receipt for this version recording both binary
artifacts, and both direct command links to this root. First-link exposure with
second-artifact failure cannot start a broker. Same-version reinstall requires
a new completed-artifact config too. Upgrade rollback restores the old receipt
and completes old artifacts/config before old first-use startup is allowed.
The gate uses Brew records only as installation-completion evidence; complete
signed payload and native process trust remain independent requirements.

Service enable/disable production context already selects the detected package
root and package version for its LaunchdUserAdapter and native identity probe;
it does not use the legacy selector for a Homebrew invocation.
