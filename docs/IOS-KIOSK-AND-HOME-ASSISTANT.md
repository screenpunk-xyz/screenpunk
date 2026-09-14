# iOS kiosk and direct Home Assistant runtime

The iOS app hides the system status bar at launch and throughout pairing, screens, and launch help. The web host disables pinch zoom and locks the viewport scale; content scrolling and the two-finger Unlink hold remain available. The idle timer is disabled while the app is active. iOS still controls background suspension and Guided Access display auto-lock.

Guided Access help appears once per process launch. `UIAccessibility.isGuidedAccessEnabled` detects an active session, not whether the user has enabled the Settings toggle. The setup guide therefore does not claim that toggle is off. Explicit “I’ve turned on Guided Access” confirmation is remembered locally; subsequent launches show activation instructions. Starting a session dismisses the guide. Public APIs do not silently start a session on ordinary unmanaged devices.

Instructions follow [Apple Guided Access support](https://support.apple.com/en-us/111795). Devices with a side, top, or Home button are covered. Actual session activation and exit require physical-device verification.

## Native connection protocol v1

`LANHello.capabilities` optionally advertises `home-assistant-http-v1`. An absent capability means the controller must request a phone app update, not silently treat a deployed screen as connected.

1. Pair using the existing mutually pinned TLS channel.
2. Deploy the screen and confirm its active revision.
3. Send `homeAssistant.provision` with a JSON-encoded `HomeAssistantProvisioning` in `LANEnvelope.payloadJSON`. The caller must be the paired owner from the actual TLS handshake. The target is the device reached through the controller’s pinned TLS channel.
4. Verify the receipt's device, screen, revision, connection and provisioning IDs before reporting installation.

Provisioning fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | `1` |
| `dashboardId` | Exact active screen ID |
| `revision` | Exact active revision ID; never a wildcard |
| `connectionId` | Opaque connection identity, separate from any Keychain account |
| `provisioningId` | Unique configuration generation/idempotency ID |
| `origin` | `http(s)://host[:port]`, no path, trailing slash, user info, query or fragment |
| `permissionMode` | `homeAssistantUser`; Home Assistant’s token/user permissions are authoritative |
| `allowInsecureHTTP` | Explicit approval for cleartext HTTP; HTTPS retains normal trust validation |
| `token` | Native-only credential; never include in packages, logs, MCP, or receipts |

The same provisioning ID with identical content is an idempotent retry. Reusing that ID with changed content is rejected. Configuration and credential are stored together in one atomic device-only Keychain record, bound to the paired owner. Failed validation or Keychain replacement preserves the previous record. A receipt reports `installed: true` and `reachability: "not_checked"`; it does not claim HA connectivity was tested.

`homeAssistant.revoke` is owner-only, requires no payload fields, and responds with `{ "revoked": true }`. Revocation and Unlink cancel pending work and erase the record. Results completing after ownership, revision, or provisioning generation changes are rejected. An action already accepted by HA cannot be undone by cancellation.

A successful deployment of a different revision retires the old record. Failed deployments preserve it. This first contract deploys before provisioning: if provisioning fails, the new screen can be active without its connection. Controllers must report that partial result and allow retry. It is not an atomic combined screen/connection deployment.

## Screen SDK

The native host injects the bundled SDK at document start. Only the main `screenpunk://package` frame can call the native bridge. Use:

```javascript
const { value: states, stale } = await screenpunk.connections.request('home', 'getStates', {});
await screenpunk.connections.request('home', 'lightOn', { entity_id: 'light.game', brightness: '128' });
```

`getStates` uses HA `GET /api/states`; the authenticated response controls visible entities. Discovery snapshots do not become permanent allowlists. Fixed action routes cover `lightOn`, `lightOff`, `sceneOn`, `mediaPlayPause`, `volumeSet`, and `selectSource`. They require one domain-matching `entity_id`; group/area/device targets, headers, destination overrides and arbitrary services are rejected. Brightness is an integer 0–255, volume is finite 0–1, and source is at most 256 UTF-8 bytes. SDK parameter values are strings, converted to appropriate JSON numbers by native code.

Screens poll `getStates` (the examples use 2 seconds). WebSocket subscriptions are not supported in this v1 bridge. Errors are redacted. Native requests use a 10-second request timeout and bound responses to 1 MiB while receiving. Redirects are refused and self-signed TLS is not bypassed. The iOS app declares local network access and a local networking ATS exception, without disabling ATS globally.

Cached reads can be returned with `stale: true`; controls must disable on stale/failure. Writes require a successful read in the last 45 seconds, are never retried or queued, and do not expose HA's service-response entity payload. HTTP 401/403 clear cached data and surface `permission_required`. The native Offline ring reflects failed/stale bridge requests. The Home Assistant example handles SDK envelopes and disables stale controls.

The bridge currently supports connection requests, runtime readiness/status, and empty default state reads. Persistent state mutation and WebSocket subscriptions remain outside this implementation.

## Validation

- iOS Simulator and iPhoneOS builds via the generated `apps/ios/ScreenpunkiOS.xcodeproj`.
- `swift test --package-path packages/ScreenpunkApple`: native contract, vault, auth, stale-write denial, existing TLS pairing/deployment and host tests.
- `node --test examples/home-assistant/test.mjs`: example parsing and native SDK envelopes.
- A real Home Assistant instance and signed device installation are needed to verify phone-only connectivity, hardware pinch/scroll behavior, and Guided Access.

## Mac setup, agents, and Apply

In Connections → Home Assistant, save the server origin and a long-lived token. The token is stored in the Mac Keychain. An empty token field retains the saved token only for the same server address. Keychain operations run off the main thread so macOS authorization prompts do not freeze the interface.

Agent `list_connections` / `describe_connection` expose the `home` alias and supported operations. `inspect_connection` accepts `alias: "home"` and an optional entity/name `query`, and returns at most 200 matching entities from the authenticated Home Assistant response. It cannot perform actions, change destinations, or return credentials. Agent-created manifests preserve their declared operations.

Apply prepares the screen for the phone's actual viewport, checks the saved connection and the phone's capability before replacing the screen, deploys, and then provisions that exact prepared revision over pinned TLS. A provisioning failure after deployment is explicitly reported as a partial result. Applying again retries installation. Older phones receive an update-required message before deployment.

The visible Mac preview uses an in-memory native runtime with the same fixed operation routes as the phone. The agent's hidden preview helper receives its native-only configuration through an anonymous process pipe, not through the screen package, command arguments, environment, or an MCP response. Non-live previews receive no credential. The phone does not use either preview as a runtime proxy.

The `examples/game-lights` test screen targets `light.game_lights`, polls live state, disables stale controls, and retains the current brightness when turning the light back on. Background reads keep usable controls enabled and preserve an active slider drag. Explicit actions wait for any in-flight read and are cancelled if that read fails. It performs no automatic light actions. Its regression tests cover stable controls during polling, slider interaction, serialized requests, and stale/failure handling.

Live validation on 2026-09-13: installed iOS 0.2.0 (2026091330) on an iPhone 13 mini, applied Game Lights at its 375×812 viewport, and received the matching provisioning receipt. The user confirmed that light control works with the Mac app closed. After feedback about polling lag, the screen was updated to poll every two seconds with a 650 ms post-action refresh and was successfully redeployed. The native Mac canvas and MCP PNG preview both showed live Home Assistant state. No credential was placed in screen assets or returned in an MCP response.
