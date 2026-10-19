# Preserve screen user data by default

Every screen that accepts user-entered data or preferences should durably save them
on its device so ordinary screen updates and app relaunches preserve the user's
work. This is the default authoring requirement for HTML/JavaScript, React,
templates, examples and agent-created screens. A read-only screen has nothing to
save until an author adds editable data. Temporary gestures and animation frames
are not user preferences.

Use the native host's injected `globalThis.screenpunk.state.get/set/remove`.
Keep the manifest's **dashboardId** across updates and use a stable screen-defined
key such as `my-screen.preferences.v1`. Never key storage by package revision,
digest, title or deployment ID. A new dashboardId creates another namespace.
Use one small versioned JSON object for related fields, preserving the native
atomic write semantics.

## Restore, edit and migrate

1. Subscribe to `screenpunk.runtime.onStatus`. While the screen is active,
   require `persistentState === 1`, `persistentStateWritable === 1` and the
   state methods before offering durable editing. Missing support and read-only
   hosts must show an explicit unsupported/read-only message. Do not silently
   substitute volatile localStorage, cookies or memory and call it saved.
2. Read the stable key before enabling preference controls. Validate the value
   and its schemaVersion. Restore saved fields before considering defaults.
   Default absent values or missing fields in memory; never write defaults just
   because the screen loaded or a revision changed.
3. A failed read must remain visible and must not trigger a defaults write.
   Preserve unrecognized schemas and report a migration requirement. Explicitly
   migrate supported older schemas without discarding saved fields. Commit a
   migration with a reviewed schema policy or the user's next confirmed edit.
4. Save explicit user edits, either with a clearly labeled Save control or
   serialized/debounced autosave. Await each `state.set`; show Saved only after
   it resolves. Keep unsaved/error status visible. Do not let delayed older
   writes overwrite a newer edit, queue writes indefinitely or busy-loop retries.
5. Call `state.remove` only for an explicit user-selected reset. Do not clear
   state during package activation, builds, updates, orientation changes or
   app startup. Preserve keys/schema across revisions; migrate intentionally.

Store user-entered settings and authored records within the native quotas.
For a countdown, store the absolute target instant, timezone and display choices,
not a decreasing value saved every tick. Do not persist fetched private service
responses, credentials, tokens, event caches, image bytes or device location here;
native integrations own those. Screen authors must respect these semantics.

The native API accepts JSON-compatible values, finite numbers and at most depth 16,
with a 16 KiB serialized value limit. A dashboard has at most 128 keys and 128 KiB;
the device-wide archive has at most 128 dashboard namespaces and 4 MiB.
A missing key and stored null both read as null. No cross-key transaction or
compare-and-swap is provided. See [the native contract](https://github.com/screenpunk-xyz/screenpunk/blob/main/docs/connections/local-screen-state.md)
for errors and retention rules.

## Device support and privacy

The documented native implementation starts at build 2026092806. Confirm the
running screen's flags and successful read/write rather than guessing from a
Mac package version or cached device summary. CLI `device status` and MCP cached
device summaries do not expose these state capabilities or private preference
values. The screen can show capability/save status to its user; agents can author
that behavior without reading the iPhone filesystem or requiring a new remote API.

Preferences are local to each device. Mac preview preferences are separate from
the iPhone's values; hidden live preview is read-only and offline previews have
no native durable-state service. There is no automatic cross-device sync, cloud
backup or agent-readable export. Do not imply that Mac preview proves phone saves.

Ordinary screen updates with the same dashboardId and app relaunches preserve
successfully saved values. Removing/re-adding the same screen retains them under
the native contract. App deletion, device/storage reset and confirmed native
Disconnect can erase them. Do not promise survival of those operations or
retroactive recovery of earlier volatile values.

## Acceptance checks for every editable screen

- Enter distinctive data, await successful save, and close/reopen the app.
  Verify the restored fields and domain behavior, such as the same absolute
  countdown deadline, instead of merely checking that the package loaded.
- Deploy a separately reviewed/approved appearance-only revision with the same
  dashboardId/key/schema. Verify the same values survive that update.
- Test unsupported/read-only status and failed reads/writes with synthetic
  fixtures: show the failure and preserve prior data, with no defaults overwrite.
- Exercise any supported schema migration with existing saved values. Preserve
  unknown versions. Confirm reset requires explicit user action.

Run real-device acceptance through the supported authoring/deployment workflow:
inspect source, patch included local CSS/JS, build/inspect the exact revision,
prepare/plan/review, obtain human approval and then apply. Capability-aware code
can be prepared before on-device support is known; do not invent a management
capability command or bypass package approval to test it.

See [the plain web source example](https://github.com/screenpunk-xyz/screenpunk/blob/main/examples/persistent-preferences/README.md).
The maintained React adapter/templates also show capability-aware restore/save
handling. A future signed kit must include those source changes under a new kit
version; never mutate an already published kit or signed CLI release.

## State API result shapes

`await screenpunk.state.get(key)` returns the saved JSON value **directly**, or
null for a missing key/stored null; it does not return a {value, stale} envelope.
`await screenpunk.state.set(key, value)` and `await screenpunk.state.remove(key)`
resolve to undefined on success (`Promise<void>`). Do not use a truthiness check
on their return value to decide whether saving worked. All three reject on errors;
catch the SDK error/code, show a failure, and do not overwrite with defaults.
A timeout or disk failure can leave write outcome uncertain: do not claim Saved
or blindly replay; restore/inspect through the supported screen API later.

`screenpunk.runtime.onStatus(listener)` subscribes and returns an unsubscribe
function. The listener receives the status object directly. active is a boolean;
persistentState and persistentStateWritable are numeric flags, with support/write
permission represented by 1 (not the boolean true). Method existence is not a
substitute for those runtime flags. Dispose the listener when the screen unmounts.

