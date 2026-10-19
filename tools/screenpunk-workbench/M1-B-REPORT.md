# M1-B result

Historical health-only M1-B evidence. The later standalone read/bootstrap integration is documented in `/Users/gsuter/Repo/Screenpunk/Planning-Files/SCREENPUNK_MAC_CLI_STANDALONE_READ_INTEGRATION.md`; current commands are described in `README.md`.

Implemented in `/Users/gsuter/Repo/Screenpunk/screenpunk-worktrees/mac-cli-m1`, branch `codex/mac-cli-m1`, unchanged HEAD `fbcfd1166cc8551a75ae54e028e6e687a9e7f428`. Only the following new tool-local files are owned by M1-B:

| File under tools/screenpunk-workbench | Purpose |
| --- | --- |
| `Package.swift` | macOS 14+ products, local Controller dependency |
| `Sources/screenpunk/main.swift` | client/foreground entrypoint |
| `Sources/screenpunk-service/main.swift` | same foreground broker runner |
| `Sources/WorkbenchCommand/Options.swift` | explicit runtime injection, bounded IPC timeout, usage/unavailable errors |
| `Sources/WorkbenchCommand/Presentation.swift` | result/error envelope, stdout/stderr separation, terminal escaping |
| `Sources/WorkbenchCommand/WorkbenchCommand.swift` | version/help/doctor/status, shared broker lifecycle and signal handling |
| `Tests/WorkbenchCommandTests/CommandTests.swift` | nine meaningful subprocess/presentation tests |
| `Tests/WorkbenchCommandTests/AdversarialPeer.swift` | test-only invalid/silent authentication-response fixtures |
| `README.md` | help, injection, errors, test recipe and current capability limits |
| `PACKAGING.md` | executable/layout boundary and packaging follow-up |
| `M1-B-REPORT.md` | this result and evidence |

Both executables use A's actual public broker/environment/client and immutable snapshot declarations. There is no new transport, shadow DTO or competing service store. Runtime injection has no live fallback; doctor does not bootstrap ControllerService, resolve a helper, read Keychain, discover LAN or choose a workspace. Source audit confirms only the environment/client/server constructors and no Apple/bootstrap/helper imports or calls. Subprocess environments use private temporary HOME/controller/runtime paths and an absent helper; no controller directory is created.

`--json` emits one result/error envelope on stdout. Startup readiness goes to stderr, with no JSON stdout before completion. Human values escape controls/bidi and bound display-only labels to 4 KiB. Implemented results explicitly report workspace unconfigured, build/device/screenshot unavailable and identity/network authorization not checked. Unimplemented workflows return exit 8. Error mapping and cancellation follow spec §6; defaults are 10 seconds per IPC exchange with positive <=10-second client overrides. SIGINT drains the foreground service and returns 130, SIGTERM drains and returns stopped/0. Client cancellation is checked at bounded IPC boundaries and never stops the shared broker.

Verification on arm64 macOS 26 / Apple Swift 6.3.3: package builds both products; **9 tests passed, 0 failures**. Coverage includes offline version/help and unavailable commands, malformed options/explicit runtime requirements, spaces/non-ASCII runtime paths, flag precedence, unavailable/stale broker, foreground ready/status/doctor, singleton conflict, both entrypoints, SIGINT/SIGTERM cleanup, malformed/incompatible peer responses, shortened timeout, client cancellation, protocol stdout separation, peer-text suppression and bounded terminal escaping. The suite binds only private `/private/tmp/spb-*` sockets and never uses installed runtime or production credentials/devices. Socket bind required approved sandbox escalation; build caches/logs/outputs remain `/private/tmp/screenpunk-m1-b-*`. The independent three-test parsing/output subset also passed inside the sandbox. Inherited Core Swift Sendable/unmutated-variable warnings remain outside M1-B ownership.

The integration run exposed Foundation's alias standardization of existing `/private/tmp` paths. A corrected its environment to use lexical validation with existing descriptor/no-follow confinement; the complete suite then passed. M1-B made no edits in A's files. Initial failing logs were superseded by the successful run.

Exact command is documented in README. Test output: `/private/tmp/screenpunk-m1-b-test.log`; independent output: `/private/tmp/screenpunk-m1-b-independent-test.log`; standalone shutdown output: `/private/tmp/screenpunk-m1-b-shutdown-test.log`. Read-only captured-baseline comparison: `/private/tmp/screenpunk-m1-b-baseline-comparison.json`. It identifies these 11 tool-local additions plus A's separately owned new Workbench sources/tests, with **no changes to inherited baseline paths**, same HEAD/branch. No staging, commit, GitHub operation, installer, publication or original-checkout source edit was performed.

Remaining scope: independent broker/CLI code review, physical macOS 14/current clean-user qualification, production runtime-directory policy, signed packaging/install/launchd/idle exit, identity/LAN/domain bootstrap and GUI/MCP forwarding remain lead-owned later M1 work. Workspace/source/build/toolchain/pair/config/deploy and other proposed workflows remain unavailable. This delivers M1-B's health-only foundation; it does not complete M1 or R1. A's broker security tests and remaining review are separate evidence, not certified by these CLI tests.

Automatic approval review rejected a status message to the coordinating chat for lack of recognized explicit destination authorization. The finding/result is preserved here; no messaging workaround was used.
