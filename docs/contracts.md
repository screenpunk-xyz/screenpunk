# Milestone 1 contracts

## Preserve user data across updates

Every screen that accepts user-entered data or preferences should persist them
with native `screenpunk.state.get/set/remove`. Keep dashboardId and versioned keys
stable, restore before defaults, save user edits, and preserve data on read or
migration failure. Check persistentState/persistentStateWritable; report unsupported
or read-only hosts. Verify values survive a screen update and app relaunch.
Device-local state is not remote agent access or cross-device sync; app deletion,
device reset and confirmed Disconnect can erase it. See [the authoring default](../docs/screen-authoring-persistence.md).


Pinned wire schema: `schemas/dashboard-manifest.schema.json`
(`https://screenpunk.xyz/schemas/dashboard-manifest/v1.json`).

Also pinned:

- `schemas/connection-grant.schema.json` — trusted Mac grants; no secrets
- `schemas/bridge-message.schema.json` — page-to-host messages

Directory packages are the authoring form. ZIP transfer uses the same
inventory limits: 25 MiB compressed, 50 MiB expanded, 2,000 files, no
symlinks, no traversal, no duplicate normalized paths.

Deployment digest is SHA-256 of the canonical JSON manifest (digest field
omitted) with files sorted by path.

Native chrome (Offline ring, two-finger Unlink) is host-owned. JavaScript
cannot draw or dismiss it.

Generic HTTP fixture: `tools/fixture-server/server.mjs`.

Browser dashboard client: `sdk/src/client.ts` → IIFE `screenpunk.js`.
Host replies via `globalThis.__screenpunkDispatch`. See `sdk/README.md`.

MCP authoring/preview/help: [docs/mcp.md](mcp.md). Preview returns PNG
image content from the hidden helper; it is live by default.

MCP pairing/deploy: same TLS 1.3 LAN messages as the workbench
(`LANProtocol.swift`); one owner per device; SAS code compared by the user
and confirmed on the device; deploy ships the previewed revision the user
approved in chat; a failed transfer keeps the device's current dashboard.

The SAS transcript binds to the certificate pins each side observed in the
TLS handshake, not to pins claimed in `hello` or `pair.begin`; a mismatch is
`identityChanged`. Deploy and `query.active` are owner-only. The device
persists owner, active revision, and package bytes (`DeviceStateStore`);
Unlink erases them.
