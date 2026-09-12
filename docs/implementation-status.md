# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 0 — Bootstrap and feasibility (bootstrap in this PR) |
| Task | Repo layout, Apache/DCO, portable CI, bundled Style-Guide identity + tokens |
| Owner | Implementation worker on `asher/codex/milestone-0-bootstrap` |
| PR | Not opened. GitHub MCP `create_pull_request` → **403 Resource not accessible by personal access token**. ManagePullRequest → **The head branch does not start with the required prefix `cursor/`**. Compare: https://github.com/screenpunk-xyz/screenpunk/compare/main...asher/codex/milestone-0-bootstrap |
| Tested revision | `164dc72`; local `./scripts/ci/linux.sh` (5/5 SDK+schema tests + brand provenance). Apple jobs untested here |
| Evidence | `assets/brand/PROVENANCE.md`, `docs/toolchain.md`, stable CI job ids |
| Blockers | Copyright-owner legal name; bundle ID registration; Apple secrets (later); `macos-15` / Xcode unconfirmed; GitHub MCP branch-create 403 |
| Next action | Milestone 0 feasibility spikes after this PR: hidden Mac preview, iOS isolation, pairing fixtures |

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

## Settled style contract

Codex guide tokens/palette/layout now; update the guide if impractical.
Default lockup stacked. Public URL
https://screenpunk-style-guide.gsuter.chatgpt.site. Danger tokens for
offline/error. iOS 27 controls with older-OS-safe fallbacks. Targets
iOS 16+ / macOS 26+. No under-review logos/wordmarks.

## Already done vs remaining M0

| Done | Remaining |
| --- | --- |
| Monorepo layout, license/DCO, brand copy + tokens + provenance | Hidden AppKit/WKWebView MCP screenshot spike |
| Linux-testable Core + TypeScript SDK + draft schema fixtures | iOS 16 host isolation + content-process failure spike |
| XcodeGen `project.yml` recipes | Pairing identity-pinning fixtures (no real credentials) |
| SHA-pinned CI with required job names | First green `apple-*` run on GitHub macOS |

Planning-Files branch `asher/codex/style-guide-source` holds the operator
corrections. Brand `Style-Guide/README.md` records the same contract.
