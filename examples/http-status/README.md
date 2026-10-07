# HTTP status example

Schema-major-1 package that calls `connections.request("status", "getStatus")`
against the generic HTTP fixture (`/v1/status`). Polls every 15 seconds,
keeps the last reading in dashboard state, and paints widget-level stale
or fault copy with Style-Guide `danger` tokens.

Uses the approved stacked lockup (v8 bevel mark + v1 / Modular wordmark).
Does not draw the native Offline ring.

Trusted Mac grant (not part of the package inventory): `connection-grant.json`.

Validate:

```sh
./scripts/ci/linux.sh
```
