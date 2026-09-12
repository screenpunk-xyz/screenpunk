# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 0 — Bootstrap and feasibility |
| Task | Persist Screenpunk, Inc. + `xyz.screenpunk.*`; keep Apple CI / remaining M0 |
| Owner | Implementation worker on `asher/codex/milestone-0-bootstrap` |
| PR | https://github.com/screenpunk-xyz/screenpunk/pull/1 |
| Tested revision | Head `cebdc83` (copyright/IDs). First green GitHub `apple-*` was `d7bc61d` |
| Evidence | NOTICE/LICENSE/XcodeGen copyright; isolation + pairing fixtures; CI artifact `preview-wkwebview-snapshot` on `d7bc61d` (15.1 KB) |
| Blockers | Apple secrets / App Store Connect records (later). Copyright owner and bundle ID *choice* are settled |
| Next action | Wait for `apple-*` on `cebdc83`. Do not treat a later failure as wiping the `d7bc61d` evidence. No fake PNGs |

## Operator decisions (2026-09-12)

- Copyright owner: **Screenpunk, Inc.** — NOTICE, LICENSE appendix, XcodeGen `NSHumanReadableCopyright`.
- Bundle IDs: **`xyz.screenpunk.*`** — `xyz.screenpunk.ios`, `xyz.screenpunk.macos`, `xyz.screenpunk.preview-host`.
- Apple Developer portal registration remains a signing-time step, not a reason to pick different IDs.

Planning-Files `asher/codex/style-guide-source` @ `1ae11cc` records the same decisions.

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

`required-checks` and `apple-build-and-unit` are not weakened. The 2886a27
failure was a missing XcodeGen 2.46.0 install; `scripts/ci/install-xcodegen.sh`
downloads the pinned zip (`sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`).

First green GitHub run: https://github.com/screenpunk-xyz/screenpunk/actions/runs/34716346419
on `d7bc61d` — all five required jobs succeeded, including `apple-build-and-unit`
and `apple-ui-and-preview`. That run uploaded `preview-wkwebview-snapshot`
(15.1 KB). This Linux worker did not generate or substitute that PNG.

## Settled style contract

Codex guide tokens/palette/layout now; update the guide if impractical.
Default lockup stacked. Public URL
https://screenpunk-style-guide.gsuter.chatgpt.site. Danger tokens for
offline/error. iOS 27 controls with older-OS-safe fallbacks. Targets
iOS 16+ / macOS 26+. No under-review logos/wordmarks.

## Already done vs remaining M0

| Done | Remaining |
| --- | --- |
| Monorepo layout, license/DCO, brand copy + tokens + provenance | Confirm `apple-*` still green after copyright/ID commit |
| Linux-testable Core + TypeScript isolation + pairing SAS fixtures | Review the CI snapshot PNG contents/dimensions |
| XcodeGen pin installed; first green `apple-build-and-unit` on `d7bc61d` | macOS 26 product-app compile if that SDK is absent on `macos-15` |
| Hidden WKWebView probe produced a real CI PNG artifact on `d7bc61d` | Simulator UI tests / content-process death on device WKWebView |
| Copyright owner + bundle ID space applied | |

## Isolation and pairing

- Custom scheme `screenpunk`, CSP `connect-src 'none'`, native networking only.
- Attack fixtures: fetch/XHR/WS, remote script/style, navigation, iframe/form,
  traversal, file URL, subframe bridge spoof.
- Pairing SAS is HMAC-SHA256 over `device || 0x00 || controller || 0x00 || session`
  with info `screenpunk-pairing-sas-v1`. 6-digit code, 120s expiry, 5 failures.

## Hidden snapshot

This worker is Linux and did not fabricate a PNG. `d7bc61d`'s
`apple-ui-and-preview` uploaded a GitHub artifact named
`preview-wkwebview-snapshot`. Treat that run as the first real capture
evidence; inspect the artifact before claiming pixel content.
