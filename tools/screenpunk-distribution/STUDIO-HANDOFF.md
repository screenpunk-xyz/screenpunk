# Screenpunk CLI 1.0.0 — Apple-silicon Studio handoff

**Release state (2026-09-30): Apple notarization accepted and stapled.** The
accepted r3 submission ID is `0417b1d4-3240-419a-81aa-77e78b5b93fb`.
Install from `releases/Screenpunk-CLI-1.0.0-arm64.dmg`, whose post-staple
SHA-256 is `a787684791309d0b939df0f9957d18bacf376cb3718ef1361585eba2a18deb60`.
The staple, Gatekeeper assessment (`Notarized Developer ID`), code signature,
and disk-image checksum all verified on the release image.

This release is a per-user, offline-first macOS 14+ installer image. It contains
`screenpunk`, `screenpunk-mcp`, `screenpunk-service`, the signed headless build
host/XPC service, and the pinned Node 24.21.0 authoring toolchain. Xcode is not
needed on the Studio. It does not replace or launch the Screenpunk Mac GUI app.
This CLI release does not enable the separately developed GUI test app's new
approval/control path; that path needs its own matching app and service build.

## Install on the Studio

1. Transfer the final `Screenpunk-CLI-1.0.0-arm64.dmg` intact and verify its
   SHA-256 against the checksum supplied with the release.
2. Open the notarized image and run `Install Screenpunk CLI.command` as the
   normal Studio user, without `sudo`.
3. Read the complete install plan, then paste its exact `Confirmation` token
   when prompted. The CLI re-verifies the signed release and the bundled
   catalog/toolchain before selecting the version and starting its user service.
4. Run `~/.local/bin/screenpunk doctor`,
   `~/.local/bin/screenpunk service status`, and
   `~/.local/bin/screenpunk agent config --client codex` (or `cursor`, `claude`,
   or `generic`). Add `~/.local/bin` to `PATH` if desired; the installer does
   not edit shell startup files or agent configuration.

The selected CLI lives under `~/.local/share/screenpunk/versions/1.0.0`, with
`~/.local/bin/screenpunk` and `~/.local/bin/screenpunk-mcp` launchers. The
user service is registered in `~/Library/LaunchAgents`. Workspace sources,
external projects, and existing GUI installations are retained.

## Verification and scope

The release is authenticated by a dedicated Ed25519 key
`screenpunk-release-2026-09`; only its public key is compiled into the CLI.
The signed catalog is `stable` sequence 1, has no download origin, and pins
one embedded arm64 authoring kit. Five exact Developer ID publisher IDs are
approved: build host, build service, Node, esbuild, and fsevents. The key's
configured validity ends at 2028-10-01T00:00:00Z; rotate the private key and
publish an updated CLI trust anchor before then. The release private key and
Apple signing/API credentials are never included in the image.

The source build and archive were tested on an Apple-silicon Mac: production
release verification, read-only installation planning, a network-denied fresh
screen build, and a full 25,724-file offline kit import into disposable roots
with real free-space and native publisher checks. The installer was not
applied on the packaging Mac, and a clean Studio installation has not yet
been tested. The Studio should run the checks above after installation.
