# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 1 — Contracts and standalone runtime (contract PR) |
| Task | Pin schema/SDK/Swift models, package validator, store/bridge bounds, offline example, HTTP fixture |
| Owner | Implementation worker on `asher/codex/milestone-1-contracts` |
| PR | Opening from this branch. M0 stays https://github.com/screenpunk-xyz/screenpunk/pull/1 |
| Tested revision | Local `./scripts/ci/linux.sh` 31/31 on this branch. Do not wait on M0 head rerun |
| Evidence | `docs/contracts.md`, `examples/offline-fixture/`, `tools/fixture-server/` |
| Blockers | None new. Apple secrets / App Store Connect still later |
| Next action | After this contract PR: parallel Apple host, connection adapters, richer SDK/fixtures |

## Operator decisions (settled)

- Copyright owner: **Screenpunk, Inc.**
- Bundle IDs: **`xyz.screenpunk.*`**
- Brand: Codex guide tokens/palette/layout; stacked lockup; danger tokens; iOS 27 controls with older-OS-safe fallbacks; https://screenpunk-style-guide.gsuter.chatgpt.site

## Based on

`asher/codex/milestone-0-bootstrap` @ `aca07e7`. First green `apple-*` was `d7bc61d`
(https://github.com/screenpunk-xyz/screenpunk/actions/runs/34716346419).

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

Not weakened.

## This contract PR

- Pinned manifest/grant/bridge JSON Schema Draft 2020-12
- Swift + TypeScript models and bounded package validator
- Directory package loader with SHA-256 + digest
- State/cache 5 MiB budget; writes are never cached as reads
- Bridge messages: correlation IDs, auth-header override deny, HTTP 15s / 2 MiB, WS 256 KiB
- Native Offline/Unlink scaffolding remains host-owned
- Deterministic offline example (no connections) and local HTTP fixture server

## Parallelizable after merge

1. Apple host — custom-scheme asset serving, gesture/overlay views, iOS 16 + Mac load of the offline example
2. Connection adapters — native HTTP/WS using the grant schema and fixture server
3. SDK browser bundle + additional examples that consume the same contracts
