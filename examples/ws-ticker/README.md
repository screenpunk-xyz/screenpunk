# WS ticker example

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../../docs/screen-authoring-persistence.md).


Schema-major-1 package that calls `connections.subscribe("ticker", "ticks")`.
The native host owns the WebSocket; this page only consumes bridge events.
Last tick is kept in dashboard state. Widget-level stale copy uses
Style-Guide `danger` tokens.

Uses the approved stacked lockup (v8 bevel mark + v1 / Modular wordmark).
Does not draw the native Offline ring.

Trusted Mac grant (not part of the package inventory): `connection-grant.json`.
Adapters should bind `GET /v1/ticks` on the generic fixture origin.

Validate:

```sh
./scripts/ci/linux.sh
```
