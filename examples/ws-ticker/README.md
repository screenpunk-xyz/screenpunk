# WS ticker example

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
