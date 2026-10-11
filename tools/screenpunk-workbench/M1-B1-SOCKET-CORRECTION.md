# M1 foundation socket publication correction

2026-09-29, isolated checkout `/Users/gsuter/Repo/Screenpunk/screenpunk-worktrees/mac-cli-m1`, branch `codex/mac-cli-m1`, unchanged HEAD `fbcfd1166cc8551a75ae54e028e6e687a9e7f428`.

The independent review's B1 is corrected in the health broker. A deterministic private `/private/tmp` reproduction created `broker.lock` and bound `broker.sock` with umask 022, then simulated termination before chmod. The stale socket was 0755. The original service returned exit 5 / `insecureRuntime` while leaving it in place. A new broker test also failed with `insecureRuntime` before the change; logs are `/private/tmp/screenpunk-m1-b1-reproduction.json` and `/private/tmp/screenpunk-m1-b1-red.log`.

`WorkbenchRuntimeDirectory` now has a **fixed-name, startup-only** socket validator. It accepts the pre-publication mode left by `bind` and an inherited umask only under the exclusive retained kernel lock and verified owned 0700 runtime directory. It still requires socket type, matching owner, link count one and no special permission bits. Stale locator/token/socket entries are all validated before any is retired; an unsafe entry leaves valid records untouched. The normal socket `identity()` used by clients and published cleanup still requires 0600. Metadata/lock files remain regular, owner-matched, 0600 and single-linked.

`WorkbenchBrokerServer` records the new socket's inode immediately after bind, before chmod and further fallible startup steps. Failed startup removes that fixed-name socket only if it still has the recorded identity and passes the unpublished-socket validation. An internal test-only after-bind hook injects an exception at that boundary; it is absent from the public API and any RPC. Normal startup verifies the same captured inode has reached strict 0600 before listen/locator publication. Unrelated or replaced filesystem nodes are preserved.

New tests cover the interrupted bind state and subsequent authenticated health, fresh instance/token, retained lock inode and unrelated sentinel; after-bind failure cleanup and retry; failed cleanup with a replaced socket; stale symlink, regular file, directory, hardlinked socket and special-mode socket rejection without partial retirement; strict client rejection of a pre-publication socket. Different-owner socket metadata is tested by passing a synthetic changed `st_uid` through the production stat validator; actual other-account/OS-ownership qualification remains future work. The existing real child SIGKILL recovery test and other broker/wire cases still pass.

**Verification:** 25 broker tests + 4 wire tests passed (29 total, zero failures), log `/private/tmp/screenpunk-m1-b1-broker-test.log`. Nine CLI subprocess tests passed, zero failures, log `/private/tmp/screenpunk-m1-b1-cli-test.log`. Private Unix socket bind required the scoped elevated test run; no installed runtime, live stores, credentials, Keychain, LAN, GUI, devices, helper or installation were used. README now states accurately that `--timeout` on the foreground command also sets that server's handshake/frame deadline. Review O1's optional completed-frame parsing-pressure work was not included.

These are the exact changed file hashes for independent reviewer verification; the review report itself was not edited:

| File relative to the isolated checkout | Before SHA-256 | After SHA-256 |
| --- | --- | --- |
| `packages/ScreenpunkController/Sources/ScreenpunkController/Workbench/Broker/WorkbenchBrokerServer.swift` | `57aa2c7ea77c54f316f5d191a65628f8d88708925320d68e70d83ac3a39340be` | `95fb641080647f0fd77a0951888668ef013b72c8ce96c39c21abb853428c9fee` |
| `packages/ScreenpunkController/Sources/ScreenpunkController/Workbench/Runtime/WorkbenchRuntimeDirectory.swift` | `a49ae467a3a3c3855b1dbaddf938c9c49d3ffdebbde1ed77bff126083f4bfa55` | `b4e022c9eda5c8f16d70bab77bcdbe3a9f0441c09b5e26c5580ae91757f897e3` |
| `packages/ScreenpunkController/Tests/ScreenpunkControllerTests/WorkbenchHealthBrokerTests.swift` | `5b3fd728645dbc3a024a901889176b693bb0e0ac3858cffd97839fb8ec70317d` | `7c8deff41b8374dec00a416948c20a5b7b5c6199d3e39ae914e23e3faffd522d` |
| `tools/screenpunk-workbench/README.md` | `d90233fd758549dc90a92465f9e22743d60807ee4f214a0915a48812b18631f5` | `f17d89de5fdc8bdc82e83e481eff5509f1b4ebcb385847c03e7871f0ea10625d` |

Read-only checkout comparisons: `/private/tmp/screenpunk-m1-b1-baseline-start.json` and `/private/tmp/screenpunk-m1-b1-baseline-end.json`. The start already showed the core worker's concurrent `ControllerService.swift` edit relative to the inherited baseline; the end additionally shows their `ScreenpunkApple/Package.swift` and `TLSIdentity.swift` edits. I did not edit those files or any inherited baseline content. Only the three named foundation source/test files, the tool-local README and this report are attributable to this correction. Build outputs/caches stayed in `/private/tmp`; no commit, GitHub action, original checkout edit or publication occurred.

This closes the reviewed health-only B1 behavior subject to independent re-review. It does not complete M1, R1, the full CLI, production packaging or macOS 14/current clean-user qualification.
