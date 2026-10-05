# Offline fixture

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../../docs/screen-authoring-persistence.md).


Deterministic schema-major-1 package with no connections. Native Offline
overlay must not appear from connection health.

Uses Style-Guide porcelain/soot colors only as page paint, not as a
first-party product chrome study. Host-owned overlay/gesture remain native.

Validate:

```sh
# from repo root, via SDK tests
./scripts/ci/linux.sh
```
