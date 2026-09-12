# Release workflow

Operator instructions for turning a green `main` into signed artifacts. CI
runs on every PR automatically; releases are manual, from a trusted
revision, inside a protected GitHub environment. Nothing here signs up for
Apple services, accepts agreements, registers identifiers, or uploads to
the App Store on your behalf.

Status: the release workflow files are being written (Milestone 5). This
document fixes the names, inputs, and steps they must match; the YAML must
use exactly the secret and variable names below. Until those workflows
merge and you have added the secrets, every build is unsigned and the
project reports "signing pending".

## What runs on every PR

| Required job | Runner | Checks |
| --- | --- | --- |
| `contracts-and-sdk` | `ubuntu-24.04` | Schema fixtures, TypeScript SDK tests, package validator, HTTP/WS adapter vectors (`./scripts/ci/linux.sh`) |
| `security-and-hygiene` | `ubuntu-24.04` | LICENSE/NOTICE, brand provenance, bundle IDs, fixture presence, credential-like strings |
| `apple-build-and-unit` | `macos-15` | Swift package tests, Mac build when the macOS 26 SDK is present, iOS 16 compile (`./scripts/ci/apple.sh`) |
| `apple-ui-and-preview` | `macos-15` | Hidden WKWebView snapshot probe; uploads a real PNG only (`./scripts/ci/preview.sh`) |
| `required-checks` | `ubuntu-24.04` | Passes only when all four above succeeded |

Merge policy: merge after `required-checks` is green; do not wait for a
second review; never weaken or bypass a required check. PR builds are
unsigned. Obsolete PR runs are cancelled; release runs are not. Artifacts
are fixtures and sanitized screenshots only, retained 7 days.

Runner images and pinned actions are listed in [toolchain.md](toolchain.md).

## One-time setup you do

1. Apple Developer Program membership for Screenpunk, Inc. Note the
   ten-character Team ID from the Membership page.
2. Register the bundle IDs in the developer portal: `xyz.screenpunk.ios`
   (an App ID is needed for its distribution profile) and
   `xyz.screenpunk.macos`. Code already uses these proposed IDs; nothing
   in the repository claims they are registered until you do this.
3. Create the App Store Connect app record for `xyz.screenpunk.ios`.
   TestFlight needs it.
4. Certificates: **Developer ID Application** (Mac, distribution outside the
   App Store) and **Apple Distribution** (iOS). Create them in Xcode >
   Settings > Accounts > Manage Certificates or in the portal. Export each
   from Keychain Access as a `.p12` with a password. Keep the private keys
   in your Keychain; the `.p12` files are what CI imports.
5. An App Store distribution provisioning profile for
   `xyz.screenpunk.ios`, downloaded as `.mobileprovision`.
6. An App Store Connect API key: Users and Access > Integrations > App
   Store Connect API > Team Keys. Download the `.p8` once (it cannot be
   downloaded again) and note the Key ID and Issuer ID. The same key type
   works for notarization (`notarytool`) and for TestFlight upload; use
   separate keys if you want different roles for each.
7. GitHub environment: repository Settings > Environments > New >
   `apple-release`. Add yourself as a required reviewer and restrict
   deployment branches to `main`.
8. Add the secrets and the variable to that environment, not at repository
   level.

| Name | Kind | How to produce |
| --- | --- | --- |
| `APPLE_TEAM_ID` | Environment variable | Team ID from the developer account |
| `MAC_SIGNING_CERT_P12_BASE64` | Secret | `base64 -i DeveloperIDApplication.p12 \| pbcopy` |
| `MAC_SIGNING_CERT_PASSWORD` | Secret | Password chosen at export |
| `IOS_SIGNING_CERT_P12_BASE64` | Secret | `base64 -i AppleDistribution.p12 \| pbcopy` |
| `IOS_SIGNING_CERT_PASSWORD` | Secret | Password chosen at export |
| `IOS_PROVISIONING_PROFILE_BASE64` | Secret | `base64 -i Screenpunk_AppStore.mobileprovision \| pbcopy` |
| `ASC_KEY_ID` | Secret | Key ID shown next to the API key |
| `ASC_ISSUER_ID` | Secret | Issuer ID shown above the key list |
| `ASC_PRIVATE_KEY` | Secret | Full contents of the `.p8` file, including the BEGIN/END lines |

Never paste any of these into chat, issues, PR descriptions, or commits.
Rotate by replacing the secret and revoking the old certificate or key at
Apple. The workflows import certificates into a temporary Keychain with a
per-run password, delete that Keychain and the profile in an always-run
cleanup step, mask secret values, and never echo decoded material or
authentication output.

## Mac release: signed DMG, notarized, GitHub Release

Preconditions: `required-checks` is green on the `main` SHA you chose, and
the TEST_PLAN evidence for that SHA is recorded.

1. GitHub > Actions > the Mac release workflow (its file is under
   `.github/workflows/`) > Run workflow. Choose `main`, enter the version
   tag and, if the workflow asks, the exact SHA. Approve the
   `apple-release` deployment when GitHub prompts you.
2. The run builds the arm64 macOS 26+ app, signs nested contents inside out
   (`screenpunk-mcp`, the preview helper, frameworks, then the app) with
   the Developer ID Application identity and hardened runtime, applies only
   the entitlements documented in the repository, packages a DMG, submits
   it to Apple's notary service, staples the ticket, verifies with
   `codesign --verify --deep --strict` and `spctl --assess`, writes a
   SHA-256 checksum, uploads the artifact, and publishes a GitHub Release
   only if every step succeeded.
3. Download the DMG and its checksum. Verify on a Mac, ideally a clean one:

```sh
shasum -a 256 -c Screenpunk-<version>.dmg.sha256
spctl -a -vv -t open --context context:primary-signature Screenpunk-<version>.dmg
hdiutil attach Screenpunk-<version>.dmg
codesign --verify --deep --strict --verbose=2 /Volumes/Screenpunk/Screenpunk.app
xcrun stapler validate /Volumes/Screenpunk/Screenpunk.app
```

4. Drag the app to `/Applications`, launch it, and confirm Gatekeeper opens
   it without a warning. Configure one agent client against the bundled
   `screenpunk-mcp` and confirm `list_devices` answers.
5. Edit the release notes using the checklist below.

If any stage fails, no release is published and the run log says which
stage. Unsigned output is never published as a normal download; if you need
to share an unsigned build for testing, share the CI artifact link and say
so.

## iOS: signed IPA and TestFlight

Boundary: automation archives and exports a signed IPA, and uploads to
TestFlight only when you dispatch the upload. The agreed finish is
"ready for the operator's TestFlight upload", not an autonomous upload or
an App Store submission.

1. Actions > the iOS archive workflow > Run workflow on `main`. Approve the
   `apple-release` deployment. The run archives with the Apple Distribution
   certificate and profile, exports the IPA, and uploads it as a workflow
   artifact.
2. When you want that build in TestFlight, dispatch the upload workflow
   (or the upload input, if the archive workflow provides one) for the same
   run. It uploads with the App Store Connect API key.
3. In App Store Connect > TestFlight, wait for processing. Answer the
   export compliance question yourself; Screenpunk uses only standard
   HTTPS/TLS, but the declaration is yours to make.
4. Add internal testers and, if wanted, an external group. External groups
   go through Beta App Review, which takes time and may ask questions;
   reviewer notes explaining user-authored local dashboards and the
   restricted native bridge are in
   [apple-review-position.md](apple-review-position.md).
5. Testers install from the TestFlight app.

Report these as separate facts, never as one "shipped":

| Stage | Evidence |
| --- | --- |
| Build succeeded | CI run |
| Archive and signed export | Workflow artifact, signing identity in the log |
| Uploaded | Upload run, App Store Connect build number |
| Processed by Apple | Build visible in TestFlight |
| Beta review (external only) | Status in App Store Connect |
| Installed by a tester | Tester confirmation, device and OS recorded |

For physical testing before TestFlight, install from Xcode to your own
device ([setup.md](setup.md#from-source-onto-your-own-device)).

## Release checklist

- [ ] `main` SHA with `required-checks` green.
- [ ] TEST_PLAN evidence recorded for this SHA: which devices and OS
      versions were physically verified.
- [ ] Release notes separate verified devices from intended compatibility.
      iOS 16 and physical iPad count only with real evidence, not from a
      successful compile.
- [ ] Known limitations listed, including hidden-render, isolation, and
      App Review positions still open.
- [ ] Mac: DMG checksum, `spctl`, `codesign`, and `stapler validate` pass on
      a clean Mac; app launches; MCP answers.
- [ ] iOS: signed export verified; the upload decision and its outcome are
      recorded separately.
- [ ] Logs and artifacts contain no secrets, home dashboard data, or
      credentials.
- [ ] Release notes tell users how to reset a device: hold two fingers on
      the screen for ten seconds, then tap **Unlink**.
- [ ] [implementation-status.md](implementation-status.md) updated with
      artifact IDs and signing status.

## What the workflows will not do

- Sign or notarize PR builds.
- Publish unsigned output as a normal download.
- Upload to TestFlight or submit to App Store review without your dispatch.
- Create Apple accounts, register identifiers, or accept agreements.
- Bypass a failing check or `required-checks`.

## Recovering from a bad release

- Mac: mark the GitHub Release as a pre-release or delete its assets. There
  is no auto-updater, so nothing pulls the bad build; users re-download.
  Installed devices keep their local dashboards regardless.
- iOS: expire the build in App Store Connect > TestFlight.
- Devices are never affected by a release action; a dashboard problem is
  fixed by redeploying or rolling back from the Mac, or with the two-finger
  Unlink on the device.

## Status words to use in reports

Use these separately and do not collapse them: implementation merged, CI
verified, physically verified, Mac signed and notarized, iOS IPA exported,
TestFlight uploaded, TestFlight processed, tester installed. A missing
secret or a pending physical result is an open gate, not a failure and not
a success.
