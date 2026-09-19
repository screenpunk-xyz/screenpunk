# General Home Assistant services: integration report

## Delivered

Implemented and integrated into `/Users/gsuter/Repo/Screenpunk/Planning-Files/Native-Workbench` on September 14, 2026. The shared checkout retains its existing uncommitted user changes. No `lcars-basement` files were edited.

The isolated implementation is on branch `guy/codex/general-ha-services` in `/Users/gsuter/.codex/worktrees/a87f/Planning-Files/Native-Workbench`, based on `474ff48abcb3635185bc5903653449ac7d6a67ba`.

- Native structured service calls across the Mac canvas, hidden native preview, and iOS/iPadOS runtime.
- Exact service/entity declarations in `connections[].serviceCalls`, bound to the native owner/dashboard/revision credential record.
- General nested JSON data with size/depth/value bounds, unchanged credential isolation and destination/TLS enforcement, and no write queue/retry/replay.
- Native freshness enforcement and HA permission-denial handling; service response bodies remain private.
- SDK convenience API, backward-compatible string-parameter wire envelope, manifest schema/types/validation, connector metadata/help, and live service catalog discovery.
- Legacy mediaOn/mediaOff, lightOn RGB, and color attributes retained. A screen declaring serviceCalls must include the services behind any legacy aliases it still uses.
- Apple TV discovery includes media title/artist/album, app/source, duration, position and update timestamp, shuffle/repeat, content IDs/types, and mute. `getStates` already passes through HA's full authenticated state attributes.
- Device capability preflight prevents new-contract screens from being transferred to older runtimes. Minimum iOS/iPadOS remains 16.0.

See [the API and migration guide](home-assistant-services.md) and [the executable example](../examples/home-assistant-services/).

## Screen author contract

```js
await screenpunk.homeAssistant.callService({
  domain: 'media_player',
  service: 'media_play_pause',
  target: {entity_id: 'media_player.example'},
  serviceData: {}
});
```

On the manifest's `home` connection:

```json
"serviceCalls": [
  {"domain":"media_player","service":"media_play_pause","entityIds":["media_player.example"]}
]
```

For a screen that bundles an older SDK:

```js
await screenpunk.connections.request('home', 'callService', {
  call: JSON.stringify({domain, service, target, serviceData})
});
```

Poll `getStates` before enabling writes. Use one declaration for each service, merging its explicit target IDs into `entityIds`. General services are not selected from a native hardcoded action list. Services intentionally called without an entity require explicit `allowUntargeted: true`; granting a service authorizes its full semantics, including downstream script effects. Area/device/label/floor and wildcard targets, and response-data service calls, are outside this contract.

## Validation

| Check | Result |
| --- | --- |
| SDK suite, including structured data, non-JSON rejection, sample screen state gating and no replay | 100 passed |
| ScreenpunkCore suite | 82 passed |
| ScreenpunkApple full isolated suite, including real WKWebView/native bridge | 43 passed |
| ScreenpunkController isolated suite | 46 passed |
| Integrated shared HomeAssistantDeviceTests, including pre-existing media/RGB tests | 8 passed |
| Integrated shared controller suite, including pre-existing carousel/device-selection changes | 47 passed |
| Unsigned Mac, native preview, iOS Simulator and device-architecture builds | Passed |
| Signed integrated iPad release, team A9VL2953H5 | Passed; signature verified |
| Integrated Mac release with bundled MCP and preview helper | Passed; ad-hoc signature and DMG verified |
| Packaged MCP smoke test, isolated temporary controller store | Passed: initialize, 22 tools, save screen, native preview PNG |
| Integrated file preservation check | All 38 implementation files match the reviewed three-way merges |

The pinned MCP dependency requires the repository release script's existing Swift 5 compatibility flags on this Xcode version. Its plain debug build hit upstream Swift 6 concurrency errors; the prescribed release build succeeded. One repeated full native test run stalled in an existing fixture-server teardown; a stack sample identified that unrelated teardown, and the standalone rerun passed all 43 tests.

No real Home Assistant write was issued for testing. No physical-device runtime or live Apple TV service behavior is claimed as tested by this task.

## Staged applications — version 0.2.0, build 2026091413

**Mac app, including updated MCP and preview helper:**

`/tmp/screenpunk-ha-release-2026091413/derived/Build/Products/Release/Screenpunk.app`

**Mac DMG:**

`/tmp/screenpunk-ha-release-2026091413/Screenpunk-unsigned.dmg`

**Signed iPad app:**

`/tmp/screenpunk-ha-signed-2026091413/Build/Products/Release-iphoneos/Screenpunk.app`

The signed app's bundle ID is `xyz.screenpunk.ios`, team is `A9VL2953H5`, and verified `MinimumOSVersion` is `16.0`. Intended paired iPad: `3B493A2F-25FD-5B2C-89A8-1B5287A4FA2B`.

**Installation completed by the originating task:** “Create Star Trek iPad screen” reported successful installation of both version 0.2.0 build 2026091413 apps, including the Mac MCP executable and native preview helper. It launched both apps and validated a live native preview of the new Apple TV screen through the generic API. It reported that no physical Home Assistant writes fired; screen deployment was still in progress. These are originating-task-reported results, not independently repeated checks from this task. This task has not installed either app, replaced `/Applications/Screenpunk.app`, or restarted existing app/MCP sessions. Automatic approval review blocked the attempted iPad installation because approval had arrived through agent coordination rather than a direct trusted user message. The originating task subsequently explicitly took over installation to avoid concurrent updates. Cross-task send-message calls were also rejected; this report and this task's final response supply the handoff.

Current running MCP sessions were observed using the old shared `dist/macos-unsigned/.../Screenpunk.app/Contents/MacOS/screenpunk-mcp` executable. Ensure the originating task restarts or reconnects those sessions to the updated bundled executable after installation; replacing the Mac GUI alone does not update an already-running MCP process. No Codex connection configuration was changed here.

## Integration preservation and evidence

Reviewed three-way merges preserved the shared Mac carousel/thumbnail changes, native preview changes, and existing compatibility tests. Before-file copies and SHA-256 merge records are in:

`/tmp/screenpunk-ha-integration/before`

`/tmp/screenpunk-ha-integration/manifest.json`

No shared changes were staged or committed. The isolated feature commit should not be blindly applied over the shared checkout again; the feature has already been integrated there.

Logs:

- `/tmp/ha-sdk-tests.log`, `/tmp/ha-core-tests.log`, `/tmp/ha-apple-final.log`
- `/tmp/ha-shared-apple-tests.log`, `/tmp/ha-shared-controller-tests.log`
- `/tmp/ha-shared-mac-release.log`, `/tmp/ha-shared-ipad-release.log`
- `/tmp/ha-packaged-smoke.log`

The release folders also contain the Mac checksum and BUILD-INFO metadata. App installation and live native preview validation were subsequently reported successful by the originating task. Final screen deployment and any physical service-control verification remain with that task.
