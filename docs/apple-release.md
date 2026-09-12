# Apple release workflows

Manual, secrets-bearing release paths. PR CI stays unsigned. This document
lists GitHub **names** only. Never put certificate, profile, or API key
material in git, issues, pull requests, or chat.

States are reported separately: unsigned CI, signed export, notarized,
uploaded, Apple processing, review, installation, and physical testing.
A green required-checks run is not a signed or uploaded release.

## Non-goals

- No App Store submission or review send
- No autonomous iOS upload (the operator must dispatch upload)
- No Apple account signup, agreement acceptance, or app-record creation by
  automation
- No Mac App Store path and no auto-updater for the alpha
- No `pull_request` / `push` triggers on release workflows

## Workflows

Dispatch from a revision that already has green `required-checks`. Obsolete
PR CI may cancel; **release runs do not cancel**.

| Workflow | File | Environment | Default finish |
| --- | --- | --- | --- |
| iOS TestFlight | `.github/workflows/ios-testflight.yml` | `apple-release` | Signed IPA artifact. TestFlight upload only if `upload_to_testflight` is true |
| Mac Release | `.github/workflows/macos-release.yml` | `apple-release` | Signed, notarized, stapled DMG plus SHA-256. GitHub Release only if `publish_github_release` is true |

Runner pin matches CI: `macos-15`. `macos-latest` is not used. Mac release
fails if the image has no macOS 26 SDK (`MACOS_26_SDK_UNAVAILABLE`).

Both workflows run unsigned `./scripts/ci/apple.sh` first, then sign only if
that precheck passed.

## Exact GitHub names

Create these on the **`apple-release` environment** (not repository-wide
unless you also lock the environment). Values are entered in GitHub
Settings only.

| Name | Kind | Use |
| --- | --- | --- |
| `APPLE_TEAM_ID` | Environment **variable** | 10-character Apple Developer Team ID |
| `IOS_SIGNING_CERT_P12_BASE64` | Environment **secret** | Apple Distribution certificate + private key, PKCS#12, base64 |
| `IOS_SIGNING_CERT_PASSWORD` | Environment **secret** | Password for that PKCS#12 |
| `IOS_PROVISIONING_PROFILE_BASE64` | Environment **secret** | App Store / App Store Connect distribution profile for `xyz.screenpunk.ios`, base64 |
| `MAC_SIGNING_CERT_P12_BASE64` | Environment **secret** | Developer ID Application certificate + private key, PKCS#12, base64 |
| `MAC_SIGNING_CERT_PASSWORD` | Environment **secret** | Password for that PKCS#12 |
| `ASC_KEY_ID` | Environment **secret** | App Store Connect API key id |
| `ASC_ISSUER_ID` | Environment **secret** | App Store Connect issuer id |
| `ASC_PRIVATE_KEY` | Environment **secret** | Contents of the `.p8` key (PEM). Used for notarization and optional TestFlight upload |

There is no `KEYCHAIN_PASSWORD` secret. Each run generates a temporary
Keychain password, masks it, and deletes the Keychain in an `always()`
cleanup step.

Do not add Apple ID / app-specific passwords. These workflows authenticate
with the App Store Connect API key only.

Proposed bundle IDs (not claimed registered): `xyz.screenpunk.ios`,
`xyz.screenpunk.macos`. Preview helper `xyz.screenpunk.preview-host` is not
part of these release products.

## Operator setup

Do this in the existing Apple Developer / App Store Connect account. Do not
create a new Apple ID or accept agreements on anyone else's behalf.

1. Confirm the Developer Program membership can issue **Apple Distribution**
   and **Developer ID Application** certificates.
2. Register bundle IDs if they are not already registered. Availability is
   operator-owned; this repo only proposes the IDs above.
3. Create or keep the iOS app record in App Store Connect. Automation does
   not create it.
4. Export an Apple Distribution certificate as PKCS#12 and an App Store
   Connect distribution provisioning profile for `xyz.screenpunk.ios`.
   Encode each file as base64 on your machine (`base64 -i file` on macOS)
   and paste only into GitHub secret fields.
5. Export a Developer ID Application certificate as PKCS#12 and store it
   the same way. A Developer ID profile is not required for this alpha
   (no Mac App Store, no extra entitlements).
6. Create an App Store Connect API key. App Manager (or the minimum role
   that can upload builds and submit notarization). Copy Key ID, Issuer ID,
   and the `.p8` contents into the `ASC_*` secrets. Prefer a dedicated key
   that can be revoked.
7. In the GitHub repository: Settings → Environments → New environment →
   name **`apple-release`** exactly.
8. Protect that environment: required reviewers, wait timer optional, and
   deployment branches limited to `main` and version tags. Do not give
   fork PRs access.
9. On `apple-release`, add the variable and secrets in the table above.
   Confirm names match character-for-character.
10. Dispatch **iOS TestFlight** or **Mac Release** from the Actions tab on
    the green revision. Leave the upload / GitHub Release checkboxes off
    until you have inspected the signed artifact.

## iOS TestFlight

Inputs:

- `upload_to_testflight` (boolean, default **false**). When false, the job
  stops at a signed IPA artifact (`screenpunk-ios-ipa`, 14-day retention).
  When true, it uploads that IPA to App Store Connect. It does **not**
  submit for App Store review.

Finish line for this repo: the operator can run the workflow and, when they
opt in, place a build into TestFlight processing. Apple processing, beta
review, tester assignment, and device install remain operator / Apple work.

| State | Who sets it |
| --- | --- |
| unsigned compile / unit tests | `apple-precheck` and required CI |
| signed IPA export | `ios-sign-export` |
| uploaded to App Store Connect | only if `upload_to_testflight` |
| Apple processing / TestFlight visibility | Apple, after upload |
| internal tester install | operator in App Store Connect |
| physical device acceptance | operator on hardware |

### Internal testers

After Apple finishes processing:

1. App Store Connect → the iOS app → TestFlight.
2. Add internal testers (App Store Connect Users). External groups may
   trigger Beta App Review; that is an operator choice, not this workflow.
3. Install from the TestFlight app on a physical iPhone or iPad.

### Local device install (before TestFlight)

On a Mac with Xcode, from this repo:

```sh
./scripts/generate-xcode.sh
open apps/ios/ScreenpunkiOS.xcodeproj
```

Select your team, a connected device, and Run. That is a development
install, not a TestFlight or signed-distribution proof. Source
`project.yml` keeps `CODE_SIGNING_ALLOWED=NO` so PR CI stays unsigned;
Xcode will ask you to enable signing locally.

iOS 16 compilation is covered in CI. Execution on iOS 16 still needs a
physical device if hosted images lack that simulator. See
[toolchain.md](toolchain.md).

### Privacy and reviewer notes

Purpose strings already in the iOS target:

- `NSLocalNetworkUsageDescription` — paired Mac discovery
- `NSBonjourServices` — `_screenpunk._tcp`

Alpha position (not an acceptance promise): see
[apple-review-position.md](apple-review-position.md). Dashboards are
user-authored local packages; the native host owns credentials and
approved HTTP/WebSocket; JavaScript cannot use raw tokens or unrestricted
networking. No in-app purchase, Screenpunk account, or cloud runtime.

`PrivacyInfo.xcprivacy` is not in the app targets yet. Adding it requires
an apps/ change and is out of scope for these workflows.

## Mac signed / notarized path

Inputs:

- `publish_github_release` (boolean, default **false**)
- `release_tag` (required when publishing; must match `v` + a digit, for
  example `v0.1.0-alpha`). Existing tags are not overwritten.

The job archives arm64 macOS 26+, exports Developer ID, enables hardened
runtime, packages a UDZO DMG, notarizes with `notarytool`, staples, verifies
`codesign`, and uploads `screenpunk-macos-dmg` (DMG + SHA-256, 14-day
retention). A GitHub Release is created only after that success, and only
when the operator opts in. Unsigned output is never published as a user
download.

| Entitlement / flag | Applied | Why |
| --- | --- | --- |
| Hardened runtime (`--options runtime`) | Yes | Notarization / Gatekeeper |
| Timestamp | Yes | Signed with a secure timestamp |
| App Sandbox | No | Direct Developer ID delivery, not Mac App Store |
| `allow-jit` / unsigned executable memory | No | Not required by the current app |
| `disable-library-validation` | No | Not required |
| Network client / Bonjour entitlements | No | App is not sandboxed; usage strings live in Info.plist |

Nested signing walks Mach-O binaries inside-out if they exist. The current
Mac app target does **not** embed `screenpunk-mcp`, the controller product,
or the preview helper. Those remain a later apps/ packaging change. The
workflow records `nested-mcp-absent` / `nested-helpers-absent` and still
notarizes the wrapper app.

Confirm Gatekeeper on a real Mac: checksum the DMG against the artifact,
open it, and move Screenpunk to Applications. Hosted `spctl` is not a
substitute for that check.

## Local Mac unsigned verify

```sh
./scripts/generate-xcode.sh
./scripts/ci/apple.sh
```

If the machine has no macOS 26 SDK, `apple.sh` prints
`MACOS_26_SDK_UNAVAILABLE` and still compiles iOS. The Mac **release**
workflow treats that as failure.

## What this repo cannot finish

- Creating the `apple-release` environment and storing secret values
- Registering bundle IDs and the App Store Connect app record
- Issuing Apple certificates and the iOS distribution profile
- First successful dispatch (needs those secrets and a macOS 26 SDK image)
- Embedding MCP / controller / preview-host in the Mac app bundle
- Privacy manifests in the app targets
- Apple processing, TestFlight review, and physical install evidence
