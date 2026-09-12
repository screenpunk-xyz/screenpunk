# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 1 — Apple host (custom scheme, overlay/gesture, offline fixture) |
| Task | Load `examples/offline-fixture` on iOS 16 + Mac via `screenpunk://` |
| Owner | Implementation worker on `asher/codex/milestone-1-apple-host` |
| PR | Opening from this branch. Contracts stay on `asher/codex/milestone-1-contracts`. M0 stays https://github.com/screenpunk-xyz/screenpunk/pull/1 |
| Tested revision | Local `./scripts/ci/linux.sh` after this change. Apple compile/tests on GitHub |
| Evidence | `packages/ScreenpunkApple` host + bundled fixture copy (hash-locked to examples/) |
| Blockers | None new. Two-finger hold is iOS; Mac uses 10s press + VoiceOver Unlink action |
| Next action | GitHub `apple-*` on this branch. Connection adapters / browser SDK are other workers |

## Operator / brand (settled)

Copyright **Screenpunk, Inc.** Bundle IDs `xyz.screenpunk.*`. Codex guide
tokens/palette/layout; stacked lockup; danger tokens for Offline/Unlink;
iOS 27 controls with older-OS-safe fallbacks (this host uses iOS 16 SwiftUI);
https://screenpunk-style-guide.gsuter.chatgpt.site

## Based on

`asher/codex/milestone-1-contracts` @ `d514903`.

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

Not weakened. `apple-build-and-unit` now runs `swift test` for ScreenpunkApple.

## This branch

- `PackageAssetStore` serves only `screenpunk://package/…` files from the bundled
  offline fixture (copy of `examples/offline-fixture`)
- `PackageSchemeHandler` returns CSP + local bytes; navigation/new-window egress denied
- Content-process death reloads the last package
- Native `OfflineRingOverlay` (guide danger / onAction; no tap intercept). Hidden
  when the fixture has zero connections
- Native `UnlinkPanelView` (one Unlink button). iOS two-finger 10s hold;
  VoiceOver custom action on both platforms
- iOS and Mac apps host `DashboardRuntimeView.offlineFixture()`

## Out of scope here

Connection adapters and browser SDK bundle — other workers.
