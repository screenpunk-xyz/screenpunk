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
