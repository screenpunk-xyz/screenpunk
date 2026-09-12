# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 2/3 — Apple workbench (discover, pair, preview, deploy) |
| Task | LAN discovery, one-owner pairing, orientation, live preview, deploy, history/rollback |
| Owner | Implementation worker on `asher/codex/milestone-2-workbench` |
| PR | https://github.com/screenpunk-xyz/screenpunk/compare/main...asher/codex/milestone-2-workbench (ManagePullRequest rejected `asher/codex/`; GitHub MCP 403) |
| Tested revision | `70390bd` local `./scripts/ci/linux.sh` 31+3 |
| Evidence | Core workbench/transfer tests + Controller atomic snapshot + Apple chrome tests |
| Blockers | Authenticated TLS 1.3 LAN transfer between two processes is not in this slice; Mac uses an in-process loopback device. Physical pairing still pending. |
| Next action | Required CI; merge when green. MCP helper / extra examples / release workflows stay with other workers. |

## Operator / brand (settled)

Copyright **Screenpunk, Inc.** Bundle IDs `xyz.screenpunk.*`. Codex guide
tokens/palette/layout; stacked lockup; danger tokens for Offline/Unlink;
https://screenpunk-style-guide.gsuter.chatgpt.site

Merge after required CI is green; do not wait for a second review; do not
weaken checks.

## Based on

`origin/main` @ `2a84fdb` (Apple host #3 + adapters #8 + grant syntax #9).

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

Not weakened. `apple-build-and-unit` now runs `swift test` for
ScreenpunkController as well as Core and Apple.

## This branch

- `_screenpunk._tcp` discovery records (advertised / manual / loopback). TXT
  carries protocol major + opaque device id only.
- One-owner pairing via existing SAS transcript; second Mac rejected.
- Mac workbench sidebar: devices, Add Device, orientation, live preview banner,
  Deploy, history/rollback, Forget unreachable.
- iOS starts unpaired, shows pairing code when a session exists, then the
  deployed dashboard. Unlink clears pairing and packages.
- Deploy is idempotent on `deploymentId`. Failed/interrupted transfer keeps
  the current revision. Rollback is a new deployment of an older revision.
- Orientation is stored on the device profile; mismatched revisions are
  rejected (no silent stretch).
- Controller snapshot writes atomically under Application Support.

## Out of scope here

MCP helper, extra dashboard examples, and release-workflow files.
