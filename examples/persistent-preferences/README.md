# Durable user preferences source example

Every editable screen should preserve user-entered data across ordinary updates
and app relaunches. This example uses injected native screenpunk.state.get/set/remove,
a stable dashboardId and example.preferences.v1 key. The active screen checks
persistentState and persistentStateWritable, restores before enabling edits, and
saves only on the explicit Save action. Read/migration failures never write defaults;
unsupported/read-only runtimes disable editing and report the reason.

These are source assets, not an installed or target-qualified package. Import them
into an existing web workspace project, preserving its dashboardId, and build using
the advertised broker source schemas. Keep index.html, styles.css and app.js linked
locally; no inline CSS, script or event handlers. Inspect/build/prepare/plan/review
and obtain exact human approval before deployment. A device's already-supported
state API needs no native upgrade solely for this screen behavior.

Acceptance: save distinctive text, close/reopen the app, then deploy another
approved appearance-only revision with the same dashboardId/key. Verify restored
text after both operations. Synthetic failure fixtures should verify no defaults
write after failed read/migration and visible errors for failed writes/read-only
hosts. Observe capabilities on the active screen, not the Mac device summary/preview.

This API does not expose private values to the Mac agent or sync between devices.
Confirmed Disconnect, device reset or app deletion can erase data. Call state.remove
only after an explicit user reset; this example has no automatic reset.
See [the complete default](../../docs/screen-authoring-persistence.md).
