# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 0 — Bootstrap and feasibility |
| Task | Fix `apple-build-and-unit` XcodeGen install; isolation; pairing fixtures; honest preview probe |
| Owner | Implementation worker on `asher/codex/milestone-0-bootstrap` |
| PR | https://github.com/screenpunk-xyz/screenpunk/pull/1 |
| Tested revision | Local `./scripts/ci/linux.sh` — 22/22 SDK+schema+isolation+pairing tests. Apple jobs not claimed green until GitHub reruns |
| Evidence | Isolation + pairing fixtures under `tests/feasibility/`. No WKWebView PNG from this Linux host |
| Blockers | Copyright-owner legal name; bundle ID registration (proposed, not claimed). Not blocking this work |
| Next action | Wait for GitHub `apple-*` on this push. Record `MACOS_26_SDK_UNAVAILABLE` / `SNAPSHOT_UNAVAILABLE` if the runner cannot produce them. Do not fake PNG evidence |

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

`required-checks` and `apple-build-and-unit` were not weakened. The 2886a27
failure was `./scripts/ci/apple.sh` exiting because XcodeGen 2.46.0 was
required but never installed. `scripts/ci/install-xcodegen.sh` now downloads
the pinned GitHub release zip and verifies
`sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`.

## Settled style contract

Codex guide tokens/palette/layout now; update the guide if impractical.
Default lockup stacked. Public URL
https://screenpunk-style-guide.gsuter.chatgpt.site. Danger tokens for
offline/error. iOS 27 controls with older-OS-safe fallbacks. Targets
iOS 16+ / macOS 26+. No under-review logos/wordmarks.

## Already done vs remaining M0

| Done | Remaining |
| --- | --- |
| Monorepo layout, license/DCO, brand copy + tokens + provenance | First green GitHub `apple-*` run (in flight after this push) |
| Linux-testable Core + TypeScript isolation + pairing SAS fixtures | Real hidden WKWebView PNG (only if macOS runner produces one) |
| XcodeGen pin installed on the macOS runner; iOS 16 compile recipe | macOS 26 product-app compile if that SDK is absent on `macos-15` |
| Preview helper (macOS 14 deploy) that records `SNAPSHOT_UNAVAILABLE` instead of a fake image | Simulator UI tests / content-process death on a real WKWebView |

Planning-Files branch `asher/codex/style-guide-source` holds the operator
corrections. Brand `Style-Guide/README.md` records the same contract.

## Isolation and pairing (this change)

- Custom scheme `screenpunk`, CSP `connect-src 'none'`, native networking only.
- Attack fixtures: fetch/XHR/WS, remote script/style, navigation, iframe/form,
  traversal, file URL, subframe bridge spoof. Content-process failure is
  simulated as `content-process-terminated`; unlink remains available.
- Pairing SAS is HMAC-SHA256 over `device || 0x00 || controller || 0x00 || session`
  with info `screenpunk-pairing-sas-v1`. 6-digit code, 120s expiry, 5 failures.
  MITM / key-change codes differ; second owner and mid-session key change reject.
  Fixtures contain no credentials.

## Hidden snapshot

This worker is Linux. No PNG was generated here. `apple-ui-and-preview` runs
`./scripts/ci/preview.sh`. Success of that *job* means the probe ran; a PNG
artifact is uploaded only when the file is a real PNG. `SNAPSHOT_UNAVAILABLE`
is a gap, not screenshot evidence.
