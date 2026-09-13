# Alpha setup

Operator guide for running the Screenpunk alpha at home. Everything runs on
your Mac and your iPhone or iPad over your own network. There is no
Screenpunk account, sign-in, cloud service, or telemetry, and the product is
useful without any of them: the Mac authors and deploys, the device runs
the dashboard on its own afterwards.

Status: the alpha is built milestone by milestone. This guide describes the
complete alpha flow. Sections whose implementation has not merged yet open
with a *Pending* line naming the owning milestone;
[implementation-status.md](implementation-status.md) records what is on
`main` today.

## What you need

| Item | Requirement |
| --- | --- |
| Mac | Apple silicon, macOS 26 or newer. Awake and logged in while you author, preview, and deploy; not needed afterwards |
| iPhone or iPad | iOS/iPadOS 16 or newer. One universal app; iPad runs full-screen |
| Network | Both machines on the same local network. Bonjour (mDNS) discovery is preferred; manual host and port works without it. Screenpunk never scans the network |
| Agent client | Codex, Claude Desktop, or Cursor on the same Mac, connected over local MCP; see [mcp-install.md](mcp-install.md) |
| Services (optional) | Home Assistant, a weather API, or any HTTP/WebSocket API with your own credentials. The bundled offline example needs none |
| Power | External power for a device that will display for hours |

Using Screenpunk needs no Apple Developer account. Building from source and
installing on your own device needs Xcode and a developer team. Signed
downloads come from the [release workflow](release-workflow.md).

## Install the Mac app

### From a signed release

*Pending: release workflow.*

1. Download `Screenpunk-<version>.dmg` and its `.sha256` file from the
   GitHub Release.
2. Verify: `shasum -a 256 -c Screenpunk-<version>.dmg.sha256`.
3. Open the DMG, drag Screenpunk to `/Applications`, eject the DMG.
4. Launch Screenpunk once so macOS verifies the notarization ticket. The
   first time you add a device, macOS asks for Local Network access. Allow
   it; discovery and pairing need it.

Keep the app in `/Applications`. Agent clients reference the executable
inside the bundle by absolute path, so moving or renaming the app breaks
those references until you update them
([details](mcp-install.md#if-you-move-or-rename-the-app)).

### From the unsigned alpha DMG

Until the signed release has its secrets, the **Mac Unsigned DMG** Actions
workflow produces `Screenpunk-unsigned.dmg` as a run artifact: no Developer
ID, not notarized. Download it from the Actions run, mount, drag Screenpunk
to Applications, and allow the first launch under System Settings →
Privacy & Security → **Open Anyway**. Steps and limits:
[macos-unsigned-dmg.md](macos-unsigned-dmg.md).

### From source

Requirements: Xcode with the macOS 26 SDK; Node 22 only if you also run the
Linux checks. Pinned versions are in [toolchain.md](toolchain.md).

```sh
git clone https://github.com/screenpunk-xyz/screenpunk.git
cd screenpunk
./scripts/generate-xcode.sh          # installs pinned XcodeGen 2.46.0, writes .xcodeproj
open apps/macos/ScreenpunkMac.xcodeproj
```

Build and run the `ScreenpunkMac` scheme. Generated projects set
`CODE_SIGNING_ALLOWED: NO` so CI builds stay unsigned; an unsigned local
build runs on your own Mac. Do not commit `.xcodeproj` files: edit
`project.yml` and regenerate.

## Install the iPhone/iPad app

### TestFlight

*Pending: release workflow; operator-run upload.*

After you dispatch the TestFlight workflow and Apple finishes processing,
testers install from the TestFlight app. See
[release-workflow.md](release-workflow.md#ios-signed-ipa-and-testflight)
for the boundary: automation produces the signed build; upload, Apple
processing, review, and installation are separate steps you drive.

### From source onto your own device

1. Connect the device by cable and trust this Mac when the device asks.
2. `./scripts/generate-xcode.sh`, then `open apps/ios/ScreenpunkiOS.xcodeproj`.
3. In Xcode select the `ScreenpunkiOS` target, Signing & Capabilities,
   enable *Automatically manage signing*, and pick your team. Regenerating
   the project discards this; pick it again or pass
   `DEVELOPMENT_TEAM=<team id> CODE_SIGNING_ALLOWED=YES` on the
   `xcodebuild` command line. Do not put your team in `project.yml`.
4. Choose the device as the run destination and run. If iOS asks, approve
   the developer under Settings > General > VPN & Device Management.

Builds signed with a personal (free) team expire after a few days and must
be reinstalled. Use a paid team for the 24-hour soak.

## First launch on the device

The device shows **Ready to pair** with brief instructions. Allow Local
Network access when asked. If you declined, turn it on later under Settings
> Privacy & Security > Local Network > Screenpunk, or from the Connection
item in the app's header menu.

There is nothing else to configure on the device. Authoring, approvals, and
deployment all happen on the Mac.

## Pair

*Pending: Milestone 3.*

1. Keep Screenpunk foreground on the device. It advertises
   `_screenpunk._tcp` only while on screen, and the advertisement carries
   only a protocol version and an opaque device ID.
2. On the Mac choose **Add Device**. Pick the device from the list, or
   enter its host and port manually; the device shows them when you ask on
   its unpaired screen.
3. Compare the six-digit matching code on both screens. Confirm on both,
   and only if they match exactly. Codes expire after two minutes; five
   failed confirmations pause pairing.
4. Choose **Portrait** or **Landscape**. The device stores and applies it.
   Changing it later needs a new preview and deployment so an old design is
   not stretched silently.

One Mac owns a device. A second Mac is rejected until the device is unlinked
([unlink-and-recovery.md](unlink-and-recovery.md)). Pairing authorizes
management of the device; it grants no access to any service.

## Connections

*Pending: Milestones 2 and 4.*

Connections hold the credentials and permitted operations that dashboards
may use. Configure them on the Mac under Screenpunk > Connections. An agent
can propose one (`propose_connection`), but only you approve it, in the
native dialog.

- Enter a token once. It is stored in the Mac Keychain and never shown
  again. Only the credentials a deployed dashboard needs are provisioned to
  the device's Keychain, over the paired channel.
- Home Assistant: create a dedicated HA user and a long-lived access token
  for Screenpunk. Screenpunk limits what dashboards can call, but it cannot
  narrow the HA token itself; revoking it is an HA action.
- HTTPS certificate validation stays on. Plain `http://` or `ws://` to a
  LAN service (typical for HA) works only when you approve it explicitly,
  and that link is unencrypted.
- Redirects are refused by default; approve the new destination instead.
- Weather and other public APIs: use your own API key and check the
  provider's terms. Polling is at least 15 seconds, weather 15 minutes.
- Timed automatic writes are never part of the starter examples and need
  an explicitly named operation permission.

## Author and preview

*Pending: Milestone 2.*

Install the MCP server in your agent client
([mcp-install.md](mcp-install.md)) and ask the agent for a dashboard. The
agent writes a package, validates it, and calls `preview_dashboard`; the
Mac renders it in a hidden WKWebView and returns the actual PNG to the
chat, tagged with the revision digest and target size. The workbench window
does not need to be open; it stays available for manual inspection.

Preview is live: "Live preview — actions control your devices". Tapping a
Home Assistant control in a preview toggles the real entity. Taking a
screenshot clicks nothing.

## Deploy

*Pending: Milestone 3.*

Approve the previewed revision in chat and let the agent call
`deploy_dashboard`, or press **Deploy** in the device page on the Mac.
Deployment reports queued, transferring, validating, activating, then
active or failed. The device must be foreground and reachable; an offline
device fails clearly and you retry after it reconnects. Nothing is queued
silently. A failed transfer leaves the current dashboard in place.

Version history and **Roll back** live on the Mac. Rollback is a normal
deployment of an older revision. The device holds one current dashboard and
shows no history.

## Keep the device displaying

- Screenpunk keeps the screen awake while its dashboard is foreground. It
  cannot run while suspended, in the background, or from the lock screen.
- Use external power.
- Optional Guided Access: Settings > Accessibility > Guided Access, turn it
  on, set a passcode, and set Display Auto-Lock to Never on that same
  page. In Screenpunk, triple-click the side button (or Home button) and
  tap Start; the device is pinned to Screenpunk until you triple-click
  again and enter the passcode.
- After a reboot or iOS update, unlock the device and reopen Screenpunk.
  The dashboard loads from local storage immediately and reconnects to its
  services. The Mac does not need to be present.
- Hardware always-on display is neither used nor required.

## Operate without the Mac

Deployed dashboards call their services directly from the device. Shut the
Mac down: the device keeps refreshing and controls keep working. A ring
around the screen with an **Offline** tab means a required connection
failed or went stale, never that the Mac is away; see
[unlink-and-recovery.md](unlink-and-recovery.md#offline-ring).

## Where your data lives

| Data | Location |
| --- | --- |
| Dashboards, revisions, deployment records, device profiles | Mac, per-user files written atomically by the local controller |
| Connection credentials | Mac Keychain; device Keychain (this-device-only, not synced) for provisioned grants |
| Active dashboard, cache, and state | Device local storage, namespaced per dashboard, bounded to 5 MiB state/cache |
| Logs | Status codes, operation IDs, timestamps, redacted host labels; 5 MiB per host; never uploaded |

No iCloud sync, no analytics, no Screenpunk servers. Preview screenshots
returned to an agent can contain private data from your services; that is
intentional and happens only when a preview is requested.

## Remove Screenpunk

- Device: hold two fingers on the screen for ten seconds, tap **Unlink**,
  then delete the app. Deleting the app without unlinking leaves the Mac
  believing the device is paired until you Forget it there.
- Mac: Unlink or Forget each device, quit Screenpunk, remove it from
  `/Applications`, delete the `screenpunk` entry from each agent client
  ([mcp-install.md](mcp-install.md#uninstall)), and delete Keychain items
  labeled Screenpunk if you want the credentials gone.
- Upstream: revoke HA and API tokens in those services yourself. Screenpunk
  cannot do it for you.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Device not listed in Add Device | Screenpunk foreground on the device; Local Network allowed on both; same network or VLAN; Bonjour not blocked. Fall back to manual host and port |
| Codes differ | Another device or Mac is pairing, or the network is interfering. Cancel on both and retry. Never confirm mismatched codes |
| "Another Mac owns this device" | Unlink on the device first |
| Preview fails or times out | Mac awake and logged in, not at the login window. Read the diagnostics returned with the error: missing asset or JavaScript error in the package |
| `device_offline` on deploy | Device foreground on the same network; retry. The current dashboard is intact |
| Offline ring | A required connection is down or stale. Check the service, the token, and the network the device uses |
| Blank dashboard | The web content process crashed and reloaded. If it persists, roll back or redeploy from the Mac |
| Mac forgot the device but the dashboard is still on it | Expected. Perform the two-finger Unlink on the device |

See [unlink-and-recovery.md](unlink-and-recovery.md),
[mcp-install.md](mcp-install.md#troubleshooting), and `get_help` from your
agent ([help/](help/README.md)).

## License

Software is Apache 2.0 (`LICENSE`, `NOTICE`); copyright Screenpunk, Inc.
Brand names, logos, wordmarks, and lockups are not under Apache 2.0; see
[brand-policy.md](brand-policy.md).
