# Durable local screen preferences

Build **2026092806+** implements the existing bundled SDK state API:

```js
const KEY = 'calendar.preferences.v1';
const saved = await screenpunk.state.get(KEY); // JSON value, or null if absent
await screenpunk.state.set(KEY, {
  schemaVersion: 1,
  names: {}, colors: {}, grouping: 'calendar', order: [], timezone: 'America/Detroit'
}); // resolves only after an atomic local-file write
await screenpunk.state.remove(KEY); // idempotent reset of this key
```

Runtime status advertises `persistentState: 1` and
`persistentStateWritable: 1`. The hidden live Mac preview advertises writable 0:
it reads the Mac's saved preferences but rejects set/remove with
`permission_required`, so screenshot rendering cannot overwrite user choices.
Visible Mac screens and iPad screens can read/write their own local state.
Offline previews have no native persistent-state service.

The native host derives scope from the loaded manifest's **dashboardId**.
JavaScript cannot supply another dashboard, path, owner, or revision. Keep the
same dashboardId across revisions, renames, orientation variants, and updates.
All pages/revisions of one dashboard share state; different dashboard IDs are
isolated. Mac and each iPad keep independent preferences. Existing app updates
and screen redeployments preserve state. Forking to a new dashboardId starts
with empty preferences. This API does not use WebView localStorage/cookies.

Use a screen-defined schemaVersion in the value and migrate explicitly. Load
before enabling preference controls; validate the stored shape and default
missing fields. Do not overwrite a failed read with defaults. Serialize/debounce
writes and await them, displaying a save failure if one occurs. The last
successful set for a key wins; no multi-key transaction or compare-and-swap is
provided. Prefer one preference object to keep related settings atomic.

Calendar integration should persist only names, colors, grouping, order, and
timezone. Do not store events, OAuth tokens, credentials, private service
responses, image bytes, or current location. This generic JSON service does
not inspect semantics; screen authors must keep those items out.

## Bounds and failures

- Key: nonempty, at most 256 UTF-8 bytes, no control characters.
- Value: JSON-compatible scalar/object/array/null; finite numbers only; maximum
  depth 16 and serialized size 16 KiB. Avoid undefined, functions, or circular
  references. Stored null and a missing key both read as null.
- Per dashboard: at most 128 keys and 128 KiB encoded storage.
- Per device/Mac: at most 128 dashboard namespaces and 4 MiB encoded storage.
  Encoding overhead counts toward aggregate limits.
- Errors: `validation_failed` for malformed input; `size_limit` for quota/depth;
  `permission_required` for inactive, unscoped, read-only or invalidated bridges;
  `device_offline` for disk/protection/corruption or unsupported disk format.
- Failed validation/quota writes leave the previous data intact. Corrupt files
  are not silently replaced with defaults. Do not busy-loop retries.

## Retention and reset

Removing a screen from a device's screen set retains its preferences. Re-adding
the same dashboard restores them. Removing a key is the screen's explicit reset
mechanism. Confirmed native **Disconnect** erases all local screen preferences
alongside pairing/screens/credentials and invalidates old WebView state leases,
so late writes cannot recreate deleted preferences. Disconnecting an iPad does
not erase the Mac's independent preferences. The confirmation text includes
saved screen preferences. App deletion or erasing device storage can lose data.

Storage is `Application Support/xyz.screenpunk.preferences/preferences-v1.json`
inside the app's local container on iOS and user Application Support on Mac.
It uses an atomic replacement, an interprocess lock, restrictive file permissions,
and iOS file protection until first unlock. The directory is excluded from OS
backup. No cloud entitlements, cloud APIs, export, or sync are enabled. Stable
dashboard/key identities and a versioned native archive leave room for a later
explicitly opted-in migration; this build remains device-local.

## Validation and rollout

Build 2026092806 installed on Mac and Desk. Mac signature verification passed
and the app opened; Desk's on-device bundle inventory confirmed the version.
After manual opening, an authenticated Desk probe succeeded at
2026-09-28T18:51:24Z. Pairing, screen set, and selected screen matched the
pre-install baseline. The prior Mac bundle is retained at
`/tmp/Screenpunk-before-local-state-2026092806.app`.

The targeted suite passed 26 tests; two opt-in live map-service tests were
skipped (previously exercised for build 2026092805). Four new preference tests
cover restart/revision persistence through the actual bundled WKWebView SDK,
read-only preview behavior, cross-dashboard isolation, key removal, stale-lease
rejection after unlink/reset, scalar values, invalid values, quotas, and
corruption handling. Signed iOS/Mac/helper builds and `git diff --check` passed.
This validates the native contract; private Calendar preference migration and
screen deployment are separate integration work.
