# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 1 — Apple host (custom scheme, overlay/gesture, offline fixture) |
| Task | Load `examples/offline-fixture` on iOS 16 + Mac via `screenpunk://` |
| Owner | Implementation worker on `asher/codex/milestone-1-apple-host` |
| PR | https://github.com/screenpunk-xyz/screenpunk/pull/3 (base `main`) |
| Tested revision | local `./scripts/ci/linux.sh` after rebase onto `origin/main` |
| Evidence | `packages/ScreenpunkApple` host + bundled fixture copy (hash-locked to examples/) |
| Blockers | Mac Unlink still 10s press + VoiceOver pending operator choice. Not editing `PackageValidator.swift` |
| Next action | Required CI on this rebase; coordinator merges #3 when green |

## Operator / brand (settled)

Copyright **Screenpunk, Inc.** Bundle IDs `xyz.screenpunk.*`. Codex guide
tokens/palette/layout; stacked lockup; danger tokens for Offline/Unlink;
iOS 27 controls with older-OS-safe fallbacks (this host uses iOS 16 SwiftUI);
https://screenpunk-style-guide.gsuter.chatgpt.site

Merge after required CI is green; do not wait for a second review; do not
weaken checks.

## Based on

`origin/main` @ `a832355` (adapters #8 on top of contracts #2). Includes the
PackagePath string-check fix so Apple `swift test` no longer hits the
old `NSRegularExpression` crash.

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

Not weakened. `apple-build-and-unit` still runs `swift test` for
ScreenpunkCore and ScreenpunkApple.

## This branch

- `PackageAssetStore` serves only `screenpunk://package/…` files from the bundled
  offline fixture (copy of `examples/offline-fixture`). Path checks stay in the
  host; they do not call `PackagePath.normalize`.
- `PackageSchemeHandler` returns CSP + local bytes; navigation/new-window egress denied
- Content-process death reloads the last package
- Native `OfflineRingOverlay` (guide danger / onAction; no tap intercept). Hidden
  when the fixture has zero connections
- Native `UnlinkPanelView` (one Unlink button). iOS two-finger 10s hold;
  VoiceOver custom action on both platforms
- Unlink clears the in-memory package and returns to `UnpairedHostView`
- iOS and Mac apps host `AppleHostRootView.offlineFixture()`

## Out of scope here

Connection adapters and browser SDK bundle — other workers.
