# Milestone 1 contracts

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
