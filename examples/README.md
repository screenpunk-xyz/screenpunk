# Examples

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../docs/screen-authoring-persistence.md).


Pinned schema-major-1 dashboard packages. Devices use the TypeScript
dashboard SDK (`globalThis.screenpunk`) and approved HTTP/WS grants.

| Package | Connections | Notes |
| --- | --- | --- |
| `offline-fixture` | none | Deterministic host/load fixture. Do not change without the Apple resource copy. |
| `weather` | required HTTP `weather` | Open-Meteo-shaped forecast. Operator URL / credential. |
| `home-assistant` | required HTTP `home`, optional WS `homeEvents` | Theater lights, scenes, media. |

Grant JSON next to each package is Mac-side documentation. Secrets stay
in Keychain. Rebuild inventory hashes with:

```sh
node examples/write-manifests.mjs
```
