# Device settings and page events

Open a device's overflow menu or right-click the device, then choose **Settings**. Both use the same device-named modal. On the display, open the native device menu and choose Settings. These preferences belong to that device and continue without the Mac while Screenpunk is foreground.

Starting page means a page inside the current dashboard package. It is separate from switching installed dashboards. Starting-page edits take effect the next time that dashboard opens. Brightness supports System, Fixed and Schedule; see [brightness behavior and hardware checks](device-brightness.md).

## Settings authority

The device owns the revision. Mac drafts are saved locally, labeled as drafts, and are never silently sent on reconnect. Apply requires a reachable paired device and the exact revision originally edited. If another editor changed the device, refresh and review before applying again. Device-confirmed storage and foreground runtime acknowledgment are shown separately. A runtime acknowledgment is not a physical brightness measurement.

Removed pages or narrowed rule permissions fall back to the new author's defaults at runtime. The stored preferences remain visibly unapplied until reset or corrected; they never expand the new package's permissions. Brightness edits do not cancel an event's return timer. Editing event rules cancels its pending automatic return while preserving the visible page.

## Authoring

`update_dashboard` accepts optional `pages`, `defaultPageId`, and `eventRules`. Omitted fields preserve existing declarations. `pages: []` resets to the entrypoint and `eventRules: []` removes rules. Declare replacement defaults together when changing page IDs. These fields survive device-size preparation and normal revisions.

A two-page package includes both HTML files in its hashed inventory:

```json
{
  "pages": [
    { "id": "home", "name": "Home", "path": "index.html" },
    { "id": "front-door", "name": "Front door", "path": "door.html" }
  ],
  "defaultPageId": "home",
  "eventRules": [{
    "id": "doorbell",
    "name": "Doorbell",
    "source": { "mode": "live", "alias": "events", "operation": "doorbell", "parameters": {} },
    "defaults": { "enabled": true, "pageId": "front-door", "returnBehavior": "timeout", "timeoutSeconds": 30, "allowPayloadOverrides": true },
    "priority": 0,
    "userConfigurable": true,
    "allowedPageIds": ["front-door"],
    "allowedReturnBehaviors": ["timeout", "stay"],
    "allowTimeoutOverride": true,
    "payload": { "eventId": ["id"], "occurredAt": ["time"], "timeoutSeconds": ["duration"] }
  }]
}
```

Declare `events` / `doorbell` as a `ws` manifest operation and separately approve its native connection grant. An event `{ "id": "ring-42", "time": "<current ISO8601 timestamp>", "duration": 60 }` uses the permitted 60-second override. No payload duration means 30 seconds. Timeout bounds are 1–3600 seconds. Priorities are -100–100; equal-priority newer events replace older ones, lower priority cannot interrupt. Manual navigation cancels returns; replaced timers cannot navigate away from newer/manual pages. Payloads cannot introduce paths, scripts, permissions or credentials.

For state rules use `condition: { "field": ["active"], "equals": true }`; `conditionClear` returns when that tracked condition becomes false. Missing data is not false. `filter` selects a subject before evaluating it, and optional `payload.correlationId` must match the lifecycle being cleared. Recent event IDs are deduplicated including clear messages, with bounded storage. IDs over 256 bytes are rejected.

Polling uses `mode: "poll"`, an approved HTTP GET read operation, a condition and `pollIntervalSeconds` of 15–86400. It establishes a baseline first and acts on later transitions; brief events between polls can be missed. Live is preferred when supported. Native navigation groups identical sources into one subscription. Dashboard JavaScript subscriptions use a separate consumer so page reloads cannot cancel native rules; total concurrent generic subscription keys are capped at 64. A generic live source can declare `refreshAlias` and `refreshOperation` for a separately approved HTTP read that refreshes current conditions on reconnect. Without that refresh, the first received condition sample is the baseline. Transient live events require `payload.occurredAt` (Unix seconds or ISO8601); messages older than the subscription start or over five seconds in the future are ignored. Keep service/device clocks synchronized. Reconnect never intentionally replays historical transient navigation.

Home Assistant uses alias `home`, live operation `stateChanged` and optional HTTP `getStates`. It authenticates its outbound WebSocket natively, subscribes, then obtains a current-state baseline. Filter on `entity_id` and compare `new_state.state`. Existing native HA permissions still apply. No access token reaches dashboard JavaScript.

`screenpunk.navigation.open(pageId)` performs manual navigation; `screenpunk.navigation.get()` reads the current page. `runtime.onStatus` includes navigation state. Pages load only packaged HTML documents; there is no visual screen designer.

## Generic connection approval

Choose the device's **Connections** menu action. Paste proposed ConnectionGrant JSON, review each origin, path/method, read/write policy, and LAN/plaintext choice, then enter credentials in native secure fields. **Approve & Replace** explicitly sends the grant to the current authenticated device/dashboard revision. A package or event cannot approve itself. Credentials persist in the device Keychain, not the Mac draft or package. Reapprove grants for a new dashboard revision. The receipt confirms installation, not endpoint reachability. An empty approved list removes that dashboard's generic grants. Nothing is queued offline.

The native adapters reject redirects, bound HTTP streams and WebSocket messages, and check grant scope before and after awaited work. Existing DNS classification occurs before URLSession connects; URLSession may resolve a hostname again, so this is not a guarantee against DNS rebinding. Use trusted endpoints; further peer-bound DNS enforcement remains a separate adapter hardening item.

## Validation boundary

Sources and timers run only while the dashboard is active. They stop on suspension, replacement or unlink, and reestablish baselines on activation. This does not promise background execution, reboot launch, unlocking or waking a locked display.

Before release, test on a physical iPhone/iPad: edit settings from both ends and confirm conflicts; turn the Mac off and cross a brightness boundary; trigger live and polled events; manually navigate during a timeout; interrupt networking and confirm stale events do not replay; unlink and confirm settings/credentials disappear. Full Xcode/iOS simulator and physical tests are separate from local Swift package compilation and deterministic assertion tests.
