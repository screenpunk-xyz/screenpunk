# Unsigned Mac DMG (alpha)

Operator notes for the unsigned alpha artifact. This path uses no Apple
secrets, no Developer ID certificate, no notarization, and no GitHub
environment. It exists so testers can run the Mac app before the signed
[Mac Release](apple-release.md#mac-signed--notarized-path) workflow has
its secrets. It is not a release and is never published as a GitHub
Release ([release-workflow.md](release-workflow.md)).

"Unsigned" here means no Developer ID and no notarization. The build still
applies an ad-hoc signature (`codesign -s -`) to the bundle, because macOS
15 and later do not offer **Open Anyway** for a bundle with no signature at
all. Ad-hoc signing needs no Apple account and proves nothing about who
built the app; Gatekeeper reports it as unverified.

## Build in GitHub Actions

1. GitHub → Actions → **Mac Unsigned DMG** → **Run workflow**. Pick the
   branch, normally `main` at a SHA whose `required-checks` is green. Leave
   `developer_dir` empty unless you need a specific Xcode.
2. The job runs `./scripts/build-unsigned-dmg.sh` on `macos-15`. The
   script uses the newest installed Xcode that ships a macOS 26 SDK (the
   image's default Xcode 16.4 does not). If no such Xcode exists the job
   fails with `MACOS_26_SDK_UNAVAILABLE`; it never lowers the deployment
   target or skips the build. This workflow is not part of
   `required-checks` and does not change them.
3. Open the finished run's **Summary** page and download the
   `screenpunk-macos-unsigned-dmg` artifact (14-day retention). The zip
   contains `Screenpunk-unsigned.dmg`, `Screenpunk-unsigned.dmg.sha256`,
   and `BUILD-INFO.txt` (git SHA, Xcode, SDK, build number).

Share the Actions run link, not a re-upload, and say that the build is
unsigned.

## Build locally

On a Mac with an Xcode that has the macOS 26 SDK:

```sh
./scripts/build-unsigned-dmg.sh                       # writes dist/macos-unsigned/
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer ./scripts/build-unsigned-dmg.sh
./scripts/build-unsigned-dmg.sh /tmp/screenpunk-dmg   # custom output directory
```

Output: `Screenpunk-unsigned.dmg`, its `.sha256`, and `BUILD-INFO.txt`.
`dist/` is git-ignored. `SCREENPUNK_MARKETING_VERSION` and
`SCREENPUNK_BUILD_NUMBER` override the `0.1.0` / run-number stamp.

## Install and first launch

1. Unzip the artifact. Optional check from that folder:
   `shasum -a 256 -c Screenpunk-unsigned.dmg.sha256`.
2. Double-click `Screenpunk-unsigned.dmg` to mount it.
3. Drag **Screenpunk** onto the **Applications** shortcut in the DMG window,
   then eject the DMG. Keep the app in `/Applications`; agent clients
   reference the executable by absolute path
   ([mcp-install.md](mcp-install.md#if-you-move-or-rename-the-app)).
4. First launch: open Screenpunk from Applications. macOS blocks it with
   "Apple could not verify Screenpunk is free of malware". Click **Done**.
5. System Settings → **Privacy & Security** → scroll to **Security** →
   **Open Anyway** next to the Screenpunk message → **Open Anyway** again →
   authenticate. macOS saves the exception; later launches open normally.
6. Each new build has a new ad-hoc identity, so repeat steps 4–5 after
   replacing the app. The Local Network prompt on first pairing
   ([setup.md](setup.md#install-the-mac-app)) also returns.

Control-click → **Open** was the pre-Sequoia shortcut; macOS 15 removed it,
and Screenpunk requires macOS 14 or newer, so use the Settings path. Terminal
alternative for a DMG you built yourself or downloaded from this
repository's Actions run:

```sh
xattr -d com.apple.quarantine /Applications/Screenpunk.app
```

That removes the download quarantine so the app opens without the prompt.
Do not do it for a DMG from anywhere else.

## What this is not

- Not signed with a Developer ID, not notarized, not stapled. Gatekeeper
  rejects it until the operator overrides.
- Not a GitHub Release, TestFlight build, or App Store build.
- Not physical-test evidence. Record device and OS separately.

## Files

- `scripts/build-unsigned-dmg.sh` — Xcode selection, Release arm64 build
  with the ad-hoc identity, `codesign --verify`, DMG, mount check, SHA-256,
  `BUILD-INFO.txt`.
- `.github/workflows/macos-unsigned-dmg.yml` — `workflow_dispatch` only,
  `macos-15`, no environment, no secrets, artifact upload.
