# Unified integration release qualification

This release integrates existing device enrollment and Mac/CLI release work with the current main branch. Cloud enrollment, human account sessions, local controller pairing, source synchronization, and screen activation have separate ownership and lifecycles. A controller account connection does not consume a display-device slot.

## Release policy

Concurrent control remains disabled in shipping builds pending physical-device qualification. See [the device gate](device/unified-control-qualification.md). Disabling the gate must preserve newer inventories, command journals, provenance, and mounted-screen history. Never downgrade their persistent representation to the former exclusive Local/Cloud model.

Source synchronization never activates a screen. Explicit commands share a device coordinator, generation checks, immutable reviewed contents, and durable receipts. Actual WebKit mounting determines the displayed screen; successful transport or a structural commit alone does not. A failed candidate leaves the previously mounted screen and its approved runtime resources usable until another screen mounts.

Screens from an unlinked local controller are represented without uploading their source. Paid-service credentials remain server-side; the runtime workspace supplies the billing context, and copying requirements does not copy binding approval. This release includes a deterministic test adapter, not production provider activation, checkout, or pricing.

## Recorded verification

The following results were obtained on the integrated release sources during the 2026-10-10 session. Reset and project-creation changes received additional affected checks.

| Area | Evidence | Limit |
| --- | --- | --- |
| Cloud server | 1,246 passing tests, six external qualification skips, no failures; both local and Linux CI | External release qualifications remain separate |
| Cloud UI | 70 console and 11 workbench tests passed across full and focused runs | Earlier published CI browser failures were repaired locally; a new CI run remains required |
| Unassigned enrollment wire | Actual HTTP activation and receipt suite passed, 4/4; generated contracts passed, 7/7 | Physical restart qualification remains required |
| Mounted service continuity | Eight real HTTP/PostgreSQL tests passed, including failed replacement and binding/installation revocation | Production providers are outside this release |
| Integrated iOS app | Final reset-integrated simulator build passed; 132 of 133 broader tests passed | One existing bundled-audio playback failure on iOS 26.5 remains; assertions were preserved |
| Local controller runtime | Genuine paired-TLS temporary activation, explicit-intent fencing, restart/expiry/tombstone tests passed, 2/2 | Physical two-controller qualification remains required |
| Retained private resources | Genuine paired-TLS mounted-resource replacement/removal/failure test passed, 1/1 | No physical-device claim |
| Native mount failure | Genuine failure/restart regression passed | Transport receipt is not a mount receipt |
| Approved archives and relay | ZIP hash-bound name regression passed, 1/1; genuine cloud-to-LAN relay passed, 1/1 | Actual OAuth review/apply/export, paired TLS chunks, digest rejection, single CAS, structural report, mounted-screen report, and durable terminal acknowledgement verified |
| Controller | 44 focused broker/deployment tests passed; two additional optimized broker creation tests passed | MCP creation reached remote source upload and a synced binding exactly once; account-switch/restart/interruption cases retained |
| App reset retirement | All three final App retirement/fence tests passed; final integrated iOS build passed | Existing simulator reused; no physical-device claim |
| Device-local factory reset | All 10 focused cases passed: seven manifest/Security boundaries and three genuine lifecycle cases; Core physical-path regression passed | Reconstructed-authority recovery was tested in the same process; separate-process crash and physical-device qualification remain outstanding |
| Shipping artifacts | Final optimized MCP (198.21 s), three CLI executables (207.84 s), and Mac Release builds passed | 501 production/package input hashes unchanged; app, binaries, and matching dSYM retained |

## Outstanding release gates

- Qualify separate-process crash/power-loss recovery on a physical device. Automated reset checks cover exact credential/root ownership, replacement protection, reconstructed-authority recovery, and fresh enrollment plus a second reset.
- Qualify a physical device before enabling concurrent control broadly. No physical device was available in this session.
- Retain the existing signed compiler launcher/runtime attestation gate.
- Complete the cloud CI rerun. Its existing npm audit step sends dependency metadata to npm; automatic approval review blocked that egress locally and explicit authorization is pending. The follow-up branch update is held because it triggers the same step.

An unfinished enrollment must first use its original enrollment recovery flow before managed factory reset becomes available. Staged credentials are preserved rather than treated as an established installation. Human sign-out, device disconnect, local unpairing, and factory reset remain distinct actions.

No production deployment or paid-provider/billing launch is implied by these results. Source preservation decisions and concise local build/test receipts are retained in the integration task evidence directory; they are not replaced by disposable build caches.
