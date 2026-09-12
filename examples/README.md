# Examples

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
