# Release workflow

Operator instructions for turning a green `main` into signed artifacts. CI
runs on every PR automatically; releases are manual, from a trusted
revision, inside a protected GitHub environment. Nothing here signs up for
Apple services, accepts agreements, registers identifiers, or uploads to
the App Store on your behalf.

The workflows are implemented: [Mac Release](../.github/workflows/macos-release.yml),
[iOS TestFlight](../.github/workflows/ios-testflight.yml), and
[Mac Unsigned DMG](../.github/workflows/macos-unsigned-dmg.yml). Signing and
publication still depend on configured credentials, explicit dispatch inputs,
and successful run evidence. A local development-signed install is not a public
release. See [apple-release.md](apple-release.md) for workflow input details.

## One repository, independent application releases

Keep applications and their shared contracts in this monorepo. Mac, iOS,
future Windows, and future services distributed as Docker images can each have
their own version, build, release notes, and publication schedule. A Docker
image versions the service it packages, rather than inventing an unrelated
application version. Windows and Docker workflows are not implemented yet.

PRs should deliver one coherent change: prefer app-specific PRs for isolated
fixes, and use cross-app PRs when a feature or protocol requires coordinated
implementation. Unrelated changes should ship through separate PRs. See
[CONTRIBUTING.md](../CONTRIBUTING.md) and the PR template.

Before releasing one application, record its tested compatibility with the
other released applications and protocol/schema versions. Devices do not
update together. Shared changes must preserve supported older clients or
explicitly gate unsupported behavior and document the upgrade order.

Version and tag each published application independently. For new GitHub
release tags, use a platform suffix compatible with the current Mac workflow's
`v`-plus-digit validation, such as `v0.2.0-macos` or `v0.2.0-ios` (examples,
not existing releases). Use an explicit title such as **Screenpunk for Mac
0.2.0** and mark alpha/beta entries as prereleases. Do not reuse a tag or imply
that another application was released by the same entry. Record the source
commit, app version, and build number in release notes; verify the built
version, since the current Mac `release_tag` input does not set it.

Mac and iOS release workflows are dispatched independently today, although
both run the shared Apple precheck. CI currently runs the complete required
suite on every PR, including documentation PRs. Future selective CI should
run affected app checks and all dependent checks for shared changes; this
policy does not claim path filtering or separate per-app CI already exists.

## Downloads and release history

The README is the user-facing download index. Keep one row per application
with platform requirements, current public version, stable/beta/planned status,
and a direct release or install-channel link. Until a build is published,
label testing instructions as testing and planned platforms as unavailable.
Never use an expiring Actions artifact as the normal public download.

Use the repository's [All releases](https://github.com/screenpunk-xyz/screenpunk/releases)
page for the full chronological history. Label each entry by application.
Link README rows to the specific platform release, rather than the repository's
single `releases/latest` destination, which may point to a different app.
iOS rows should use a verified TestFlight or App Store install link when
available; Docker should use the published image and quickstart.

When publishing, update the affected README row and release notes with version,
requirements, compatibility, installation instructions, and known limitations.
Name future assets clearly by platform, version, and architecture. The current
Mac workflow emits `Screenpunk.dmg` and its checksum and a generic release
title; edit the title/notes to identify Mac before announcing the release.
Workflow changes for automated naming are separate implementation work.

## What runs on every PR

| Required job | Runner | Checks |
| --- | --- | --- |
| `contracts-and-sdk` | `ubuntu-24.04` | Schema fixtures, TypeScript SDK tests, package validator, HTTP/WS adapter vectors (`./scripts/ci/linux.sh`) |
| `core-linux` | `ubuntu-24.04` with pinned Swift container | ScreenpunkCore tests on Linux (`./scripts/ci/core-linux.sh`) |
| `security-and-hygiene` | `ubuntu-24.04` | LICENSE/NOTICE, brand provenance, bundle IDs, fixture presence, credential-like strings |
| `apple-build-and-unit` | `macos-15` | Swift package tests, Mac build when the macOS 26 SDK is present, iOS 16 compile (`./scripts/ci/apple.sh`) |
| `apple-ui-and-preview` | `macos-15` | Hidden WKWebView snapshot probe; uploads a real PNG only (`./scripts/ci/preview.sh`) |
| `required-checks` | `ubuntu-24.04` | Passes only when all five above succeeded |

Merge policy: merge only after `required-checks` is green on the current PR
head, review feedback is resolved, and applicable repository approval rules
are satisfied. Never weaken or bypass a required check. PR builds are
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
   `.github/workflows/`) > Run workflow. Choose `main` after verifying its exact SHA. Leave
   `publish_github_release` false for an artifact-only run, or enable it and
   supply `release_tag` for publication. Approve the
   `apple-release` deployment when GitHub prompts you.
2. The run builds the arm64 macOS 14+ app (using the macOS 26+ SDK), signs nested contents inside out
   (`screenpunk-mcp`, the preview helper, frameworks, then the app) with
   the Developer ID Application identity and hardened runtime, applies only
   the entitlements documented in the repository, packages a DMG, submits
   it to Apple's notary service, staples the DMG ticket, verifies signing and stapling, attempts
   `spctl --assess`, writes a
   SHA-256 checksum, uploads the artifact, and publishes a GitHub Release
   when the signing job succeeds and publication is enabled. The hosted
   runner may report Gatekeeper assessment as incomplete without failing;
   verify Gatekeeper on a real Mac before announcing the download.
3. Download the DMG and its checksum. Verify on a Mac, ideally a clean one:

```sh
shasum -a 256 Screenpunk.dmg
# Compare the hash with Screenpunk.dmg.sha256 (which may contain a runner path).
spctl -a -vv -t open --context context:primary-signature Screenpunk.dmg
hdiutil attach Screenpunk.dmg
codesign --verify --deep --strict --verbose=2 /Volumes/Screenpunk/Screenpunk.app
xcrun stapler validate Screenpunk.dmg
```

4. Drag the app to `/Applications`, launch it, and confirm Gatekeeper opens
   it without a warning. Configure one agent client against the bundled
   `screenpunk-mcp` and confirm `list_devices` answers.
5. Edit the release notes using the checklist below.

If any stage fails, no release is published and the run log says which
stage. Unsigned output is never published as a normal download; if you need
to share an unsigned build for testing, share the CI artifact link and say
so. The **Mac Unsigned DMG** workflow exists for exactly that
([macos-unsigned-dmg.md](macos-unsigned-dmg.md)); it uses no secrets and
no environment.

## iOS: signed IPA and TestFlight

Boundary: automation archives and exports a signed IPA, and uploads to
TestFlight only when you dispatch the upload. The agreed finish is
"ready for the operator's TestFlight upload", not an autonomous upload or
an App Store submission.

1. Actions > **iOS TestFlight** > Run workflow on the verified `main`
   revision with `upload_to_testflight` false. Approve the `apple-release`
   deployment. It archives, exports, and retains the signed IPA artifact.
2. For TestFlight, dispatch **iOS TestFlight** with `upload_to_testflight`
   true. This performs a new archive/export and uploads that run's IPA; it
   does not upload a previously exported artifact. Verify the source SHA,
   app version, and build number again before dispatch.
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
- [ ] Target application, version, build number, release channel, and tested
      cross-app compatibility recorded.
- [ ] Public release title identifies the application; README download row
      links to the verified release or install channel and states availability.
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
      the screen for five seconds, open the device menu, choose **Disconnect**, and confirm.
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
  fixed by redeploying or rolling back from the Mac, or through the five-second two-finger device menu and confirmed
  **Disconnect** action.

## Status words to use in reports

Use these separately and do not collapse them: implementation merged, CI
verified, physically verified, Mac signed and notarized, iOS IPA exported,
TestFlight uploaded, TestFlight processed, tester installed. A missing
secret or a pending physical result is an open gate, not a failure and not
a success.
