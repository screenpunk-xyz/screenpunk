# Implementation status

Last updated: 2026-09-12 by worker `bc-8cefc708-ec93-5316-aaa7-e09f4bd9ba49`.

| Field | Value |
| --- | --- |
| Milestone | 3 — device persistence and TLS-bound SAS (follow-up to #21) |
| Task | Phone keeps owner, active revision, and package bytes across relaunch (`DeviceStateStore`); SAS transcript and owner checks bind to the certificate pin observed in each TLS handshake on both sides, never to a claimed pin |
| Owner | Implementation worker on `asher/codex/pairing-persist-sas-pin` |
| PR | https://github.com/screenpunk-xyz/screenpunk/compare/main...asher/codex/pairing-persist-sas-pin |
| Tested revision | local `./scripts/ci/core-linux.sh` 66/66 (5 new `DeviceStateStoreTests`); Controller 23/23 through the scratch Linux shim; Apple `LANTransferTests` (relaunch, rogue hello, claimed controller pin) verified by CI |
| Evidence | `DeviceStateStoreTests`: atomic state replace, staged→swapped package, rejected staging keeps current package, restore keeps one owner and deployment idempotency, erase. `LANTransferTests`: handshake pin read from TLS metadata equals the identity pin; SAS code equals the transcript of both TLS pins; owner persists after confirm, revision and package after deploy; relaunched server is paired and rendering, owner reconnects, stranger fails, Unlink erases and a cold start is unpaired; a rogue device claiming another pin in `hello` is `identityChanged`; a controller claiming another pin in `pair.begin` is `identityChanged` and `query.active` is owner-only. |
| Blockers | Physical two-device pairing still pending operator hardware. This environment cannot run Xcode; Apple compile is CI-verified. |
| Next action | Required CI; merge when green. |

## Milestone 3 — MCP pairing and deploy (merged as #21)

| Field | Value |
| --- | --- |
| Owner | Implementation worker on `asher/codex/milestone-mcp-pairing-deploy` |
| Evidence | `PairingDeployTests` drive the MCP router against an in-memory device mirroring `DeviceLANServer`: SAS code shown equals device code, confirm before device tap → `permission_required`, one owner, persisted `devices.json`, deploy needs previewed + `approved`, idempotent `deploymentId`, target mismatch and corrupt hash keep the active revision, rollback, offline/unknown errors, forget is Mac-only. `LANTransferTests` asserts the device keeps the delivered package and Unlink erases it. |

## Milestone 3 — TLS 1.3 two-process LAN transfer (merged as #17)

| Field | Value |
| --- | --- |
| Owner | Implementation worker on `asher/codex/milestone-3-lan-tls` |
| Evidence | Core LAN framing/pin tests + Apple `LANTransferTests` (TLS pair, deploy, idempotent replay, hash reject, second-owner pin, no plaintext handshake) |

## Operator / brand (settled)

Copyright **Screenpunk, Inc.** Bundle IDs `xyz.screenpunk.*`. Codex guide
tokens/palette/layout; stacked lockup; danger tokens for Offline/Unlink;
https://screenpunk-style-guide.gsuter.chatgpt.site

Merge after required CI is green; do not wait for a second review; do not
weaken checks.

## Based on

`origin/main` @ `aef8898` (MCP pairing and deploy #21).

## Job names (stable)

`contracts-and-sdk` · `core-linux` · `apple-build-and-unit` ·
`apple-ui-and-preview` · `security-and-hygiene` · `required-checks`

Not weakened.

## This branch (device persistence and TLS-bound SAS)

- `ScreenpunkCore/DeviceStateStore`: `DevicePersistedState` (owner pin,
  active revision, `StoredRevision`, last deployment) replaced with
  `rename(2)`; package bytes staged to `package.staging-*` and swapped in as
  `package/` only after activation, previous package restored if the swap
  fails; `erase()` removes everything. `DeviceRuntime.restore` rebuilds the
  runtime; sessions never persist.
- `DeviceLANServer` restores from the store at init, persists on confirm and
  after every deploy outcome, stages to disk before `receiveDeployment`, and
  erases on Unlink. `DeviceLANHost` defaults to the per-user device home
  (`SCREENPUNK_DEVICE_HOME` override).
- `LANChannel.observedPeerPin` reads the leaf certificate from the
  connection's TLS metadata. `ControllerLANClient` fails closed when `hello`
  claims a pin other than the handshake pin and pins the observed value.
  `DeviceLANServer` computes the SAS transcript from the handshake pin, rejects
  `pair.begin`/`pair.confirm` payloads that claim another pin, and gates
  `deploy` and `query.active` on the owner pin. `DeviceCoordinator` uses the
  link's observed pin for its own SAS check.

## Milestone 3 MCP branch (merged)

- `ScreenpunkController` gains `DeviceLink`/`DeviceLinkFactory` (the LAN
  transport contract), `DeviceDirectory` (`devices.json`, one owner per
  device), and `DeviceCoordinator` (pair.begin with controller-side SAS check,
  pair.confirm that only succeeds after the device owner tapped Confirm,
  deploy idempotent on `deploymentId`, reachability probe, Mac-only forget).
- `ControllerService` tracks revisions previewed in this process;
  `deploy_dashboard` requires that exact `revision` plus `approved=true`
  (agent-mediated chat approval). `rollback_dashboard` redeploys from device
  history through the same path.
- `screenpunk-mcp` links `ScreenpunkApple`, wraps `ControllerLANClient` as the
  `DeviceLink`, starts the `_screenpunk._tcp` browser into the controller's
  discovery hub, and loads the shared `xyz.screenpunk.tls.controller`
  keychain identity so the workbench and MCP present one owner.
- `DeviceLANServer` keeps the hash-checked package after activation and the
  iOS root view renders it; failed transfers and Unlink never touch or always
  clear it respectively.
- Catalog adds `confirm_pairing` and `forget_device`; input schemas are shared
  by both transports (`MCPToolSchemas`). Help topics `pairing` and `deploy`.

## Milestone 3 LAN branch (merged)

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

Release-workflow files, operator docs owned by other work (`docs/help/*`,
`docs/setup.md`, `docs/unlink-and-recovery.md`), Brand, and Mac workbench UI
changes.
