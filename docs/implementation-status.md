# Implementation status

Last updated: 2026-09-12 by worker `bc-a383ee27-f334-585d-9587-caa067438d3e`.

| Field | Value |
| --- | --- |
| Milestone | 3 — TLS 1.3 two-process LAN transfer |
| Task | Authenticated TLS 1.3 pairing and deploy between Mac and iOS processes |
| Owner | Implementation worker on `asher/codex/milestone-3-lan-tls` |
| PR | https://github.com/screenpunk-xyz/screenpunk/compare/main...asher/codex/milestone-3-lan-tls (ManagePullRequest rejected `asher/codex/`; GitHub MCP 403) |
| Tested revision | local `./scripts/ci/linux.sh` 31+3 (no Xcode on this runner) |
| Evidence | Core LAN framing/pin tests + Apple `LANTransferTests` (TLS pair, deploy, idempotent replay, hash reject, second-owner pin, no plaintext handshake) |
| Blockers | Physical two-device pairing still pending operator hardware. This environment cannot run `swift test` / Xcode. |
| Next action | Required CI; merge when green. MCP helper / extra examples / release workflows stay with other workers. |

## Operator / brand (settled)

Copyright **Screenpunk, Inc.** Bundle IDs `xyz.screenpunk.*`. Codex guide
tokens/palette/layout; stacked lockup; danger tokens for Offline/Unlink;
https://screenpunk-style-guide.gsuter.chatgpt.site

Merge after required CI is green; do not wait for a second review; do not
weaken checks.

## Based on

`origin/main` @ `48b0fc5` (Workbench #10).

## Job names (stable)

`contracts-and-sdk` · `apple-build-and-unit` · `apple-ui-and-preview` ·
`security-and-hygiene` · `required-checks`

Not weakened.

## This branch

- Control messages are `protocolVersion` + `requestId` + method + typed payload,
  length-prefixed, capped at 2 MiB.
- Device listens with Network.framework TLS 1.3 only (no plaintext fallback).
  Persistent P-256 identities live in the keychain; the peer pin is SHA-256 of
  the uncompressed public point and is bound after SAS confirmation.
- One-owner pairing stays on the existing HMAC-SHA256 SAS. A second controller
  is rejected at TLS pin after the owner is set.
- Mac workbench still has an in-process loopback device. Advertised/manual
  devices use `ControllerLANClient` over TLS. `_screenpunk._tcp` browse feeds
  the same discovery hub; TXT is still `v` + opaque `id` only.
- Deploy is idempotent on `deploymentId`. File blobs are hash-checked before
  activation. Failed/corrupt transfer keeps `activeRevision`. Rollback is a new
  deploy. `query.active` reads the device revision.
- iOS unpaired surface shows the listening TLS port for manual Mac entry.

## Out of scope here

MCP helper, extra dashboard examples, and release-workflow files.
