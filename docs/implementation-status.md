# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 0 — Bootstrap and feasibility |
| Task | Persist Screenpunk, Inc. + `xyz.screenpunk.*`; keep Apple CI / remaining M0 |
| Owner | Implementation worker on `asher/codex/milestone-0-bootstrap` |
| PR | https://github.com/screenpunk-xyz/screenpunk/pull/1 |
| Tested revision | `5460ff3` local `./scripts/ci/linux.sh` 22/22. GitHub `apple-*` on this SHA not claimed green yet |
| Evidence | NOTICE/LICENSE/XcodeGen copyright; isolation + pairing fixtures. No WKWebView PNG from this Linux host |
| Blockers | Apple secrets / App Store Connect records (later). Copyright owner and bundle ID *choice* are settled |
| Next action | Push this decision, keep required checks intact, record real `apple-*` outcomes. Do not fake PNG evidence |

## Operator decisions (2026-09-12)

- Copyright owner: **Screenpunk, Inc.** — NOTICE, LICENSE appendix, XcodeGen `NSHumanReadableCopyright`.
- Bundle IDs: **`xyz.screenpunk.*`** — `xyz.screenpunk.ios`, `xyz.screenpunk.macos`, `xyz.screenpunk.preview-host`.
- Apple Developer portal registration remains a signing-time step, not a reason to pick different IDs.

Planning-Files `asher/codex/style-guide-source` records the same decisions.

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

`required-checks` and `apple-build-and-unit` are not weakened. The 2886a27
failure was a missing XcodeGen 2.46.0 install; `scripts/ci/install-xcodegen.sh`
downloads the pinned zip (`sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`).

## Settled style contract

Codex guide tokens/palette/layout now; update the guide if impractical.
Default lockup stacked. Public URL
https://screenpunk-style-guide.gsuter.chatgpt.site. Danger tokens for
offline/error. iOS 27 controls with older-OS-safe fallbacks. Targets
iOS 16+ / macOS 26+. No under-review logos/wordmarks.

## Already done vs remaining M0

| Done | Remaining |
| --- | --- |
| Monorepo layout, license/DCO, brand copy + tokens + provenance | First green GitHub `apple-*` run |
| Linux-testable Core + TypeScript isolation + pairing SAS fixtures | Real hidden WKWebView PNG (only if macOS runner produces one) |
| XcodeGen pin installed on the macOS runner; iOS 16 compile recipe | macOS 26 product-app compile if that SDK is absent on `macos-15` |
| Preview helper (macOS 14 deploy) that records `SNAPSHOT_UNAVAILABLE` instead of a fake image | Simulator UI tests / content-process death on a real WKWebView |
| Copyright owner + bundle ID space applied | |

## Isolation and pairing

- Custom scheme `screenpunk`, CSP `connect-src 'none'`, native networking only.
- Attack fixtures: fetch/XHR/WS, remote script/style, navigation, iframe/form,
  traversal, file URL, subframe bridge spoof.
- Pairing SAS is HMAC-SHA256 over `device || 0x00 || controller || 0x00 || session`
  with info `screenpunk-pairing-sas-v1`. 6-digit code, 120s expiry, 5 failures.

## Hidden snapshot

This worker is Linux. No PNG was generated here. `apple-ui-and-preview` runs
`./scripts/ci/preview.sh`. A PNG artifact is uploaded only when the file is a
real PNG. `SNAPSHOT_UNAVAILABLE` is a gap, not screenshot evidence.
