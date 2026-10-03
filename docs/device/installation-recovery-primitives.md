# Native installation recovery primitives

These local primitives support the agreed recovery requirements without defining an enrollment wire contract. Production iOS startup now uses them to check Local eligibility before constructing a management host. Local listener and management operations also carry captured admission. Cloud onboarding and Cloud network requests remain unconnected. A workspace receipt and a human sign-in generation still confer no installation authority.

## Durable local evidence

`DeviceManagementTransitionStore` holds a version 2 nonsecret history with separate transition entries and credential-generation bindings. Each transition has an immutable UUID and either unresolved intent or a local fence. Each credential generation has its own distinct UUID, transition binding, and immutable Keychain reference. Multiple generations may belong to one unresolved transition, without selecting an active credential or claiming that remote rotation occurred.

Only the final transition may remain unresolved. A new transition may append after prior transitions are fenced; all previous bindings and fences remain. Updates cannot drop, reorder, reuse, or unfence history. Capacity is bounded at 64 transitions, 128 credentials, and 64 KiB; exhaustion blocks instead of pruning recovery evidence. Fences record local revocation evidence only, not remote activation, revocation, or completed slot cleanup. Version 1 records migrate deterministically in memory while preserving their phase and reference; the next successful save commits version 2. Inspection alone does not rewrite the file.

Reads distinguish confirmed absence from invalid, unsupported, oversized, or inaccessible state. Writes serialize through a disk lock, sync the temporary file, replace the record, and sync its directory. Darwin requests a full file flush where supported. A failed write blocks eligibility within the process, including reconstructed store instances, until the exact attempted record is durably recommitted. Diagnostic readback alone is not authorization. Restart reads the surviving committed record. These checks do not qualify hardware power-loss behavior.

The default management directory is a sibling of the legacy device directory, so legacy device erasure does not erase this record. Custom callers must preserve the same separation. Reset evidence is now part of authority checks; destructive cleanup orchestration remains unimplemented.

## Credential staging and classification

The dedicated Cloud Keychain service stores device-only, nonsynchronizing, 32-byte random secrets through create-only insertion. Existing material is loaded, never overwritten. A duplicate insertion loads the existing winner; other write uncertainty requires exact same-reference readback. Metadata enumeration returns references, not secrets. Missing, malformed, inaccessible, and orphaned material remain distinct blocked conditions.

A new operation must durably save and verify its intent before generating a secret. An existing intent with a missing key cannot safely regenerate: the primitive cannot distinguish a crash before staging from loss after a future remote attempt. Resolving that case requires a later recovery contract.

Legacy Local eligibility requires a confirmed absent journal and confirmed empty dedicated service. An unresolved intent blocks Local. Fenced history is eligible only when every transition is fenced and every recorded generation matches the exact dedicated Keychain inventory with readable valid keys. Staging an additional generation accounts for all earlier keys, persists one exact history append first, and rechecks the full history after insertion. Classification does not erase credentials or remote cleanup obligations. Future startup integration must run this classification before constructing or advertising a Local host and must reject stale Cloud work independently of retained-content grants.

## Remaining integration

Accepted backend schemas and recovery fixtures must define candidate claim, activation/status proof, promotion, terminal recovery, remote cleanup, and subsequent transitions. Durable reset recovery, Cloud command integration, live Keychain qualification, physical-device testing, and hardware power-loss qualification remain separate work. Tests here inject credential backends and filesystem commit failures; they do not access personal Keychain items or enroll a real device.

The classifier returns a snapshot, not a lock or an activation capability. The future bootstrap/management owner must serialize classification with transition writes and keep its generation guard across subsequent startup and asynchronous work. Journal and Keychain operations are not one transaction; passing classification must never be cached across a later transition or used to bypass a fresh authority check.

The history now supports storage for repeated Local → Cloud → Local → Cloud transitions and multiple credential generations while retaining earlier fences and possible remote cleanup obligations. The actual enrollment and rotation protocols remain unimplemented. Account-owned active installation authority must not depend solely on the original human claimant. Future remote request UUIDs must be persisted separately from authority transition UUIDs; their wire representations are not defined here.

Successor validation protects updates made through this store against history loss. Plain filesystem storage does not provide trusted antirollback protection against external replacement with an older valid history. Tests cover repeated cycles, multiple generations, migration, capacity, stale updates, and uncertain commits; they do not qualify live enrollment or physical power loss.

## Serialized Local authority checks

`DeviceManagementAuthority` provides an in-process owner for Local eligibility checks. It starts blocked and issues an opaque, revocable lease only after checking the journal and dedicated credential inventory. Every synchronous gated operation rechecks the full evidence. Refresh and revocation invalidate older leases; reentrant owner calls are rejected. A history change observed after a lease was issued quarantines that owner instance, so removing or rolling back known evidence cannot restore legacy Local permission within its lifetime.

The owner exposes classification, revocation, short synchronous gated operations, and internal Local reset bookkeeping with exact-write recovery. It does not stage Cloud credentials or write Cloud fences. Cloud mutation APIs require their own exact-write recovery design before transitions can use this owner. All production Cloud transition writers remain disabled. The existing standalone recovery primitives are unchanged.

Future callers must share one owner, acquire authority before the server lock, and keep network waits outside the gated operation. Listener readiness, peer handshakes, and pairing approval must recheck their captured lease before committing a side effect. A lease must not authorize queued work without another check. External processes and direct filesystem or Keychain writers are not excluded by this lock; it is not a persistent antirollback mechanism.

Production iOS bootstrap now classifies through one lifetime owner before creating TLS or a management host. Blocked startup uses a separate read-only retained-content loader and a Retry action. It preserves package bytes and grants, validates manifest metadata when present, and permits in-memory screen switching. Connector-backed data is unavailable in this fallback because it constructs no connector runtimes. A host whose TLS setup failed returns to the blocked state.

The admitted host now carries a mandatory captured context into the server. Listener restarts, accepted requests, local mutations, temporary-selection checkpoint writes and erase admission validate that context. Revocation cancels pending/current listeners and accepted connections while preserving retained content authority. Network readiness and pairing approval waits occur outside authority/server locks, then recheck before commit. Invalidation observers and transaction callbacks run after releasing locks. Cloud transition writers remain disabled.

Erase admission is enforced, but reset durability is not yet repaired: legacy unlink still suppresses some vault/disk failures and can have partial effects. Legacy silent persistence paths also remain. Those paths require separate work before claiming recoverable reset. The journal and dedicated Cloud credential service must remain outside destructive Local cleanup. Focused tests verify blocked factory exclusion and eligible factory admission using a throwing factory; they do not verify successful host construction or physical-device Keychain behavior.


## Local reset record

`DeviceLocalResetStore` is a separate, bounded version 1 record for the existing Local unlink operation. It stores only a reset UUID, an opaque configured-scope digest, and pending/completed phase. Pending identity and scope cannot change. Completion remains on disk; replacing it requires an explicit `beginNewReset` with a different UUID. UUID uniqueness is relative to the current record, not a retained history.

The store distinguishes confirmed absence from corruption and IO failures. Atomic replacement synchronizes the file and directory. An uncertain write blocks reads across store reconstruction in the same process until the exact record is recommitted through the same save/begin method. Diagnostic readback is not permission to clean up or resume management. Tests inject failures before and after replacement; they do not qualify physical power loss or external rollback.

There is no reset coordinator or cleanup caller yet. Production authority now reads reset evidence on admission and every gated operation. Absent or matching completed evidence permits independent Cloud/Local classification; pending, corrupt, inaccessible, or mismatched evidence blocks management. Bootstrap also suppresses retained rendering for reset-blocked state. Ordinary Cloud-blocked startup may still render retained content.

`DeviceLocalResetScope` binds fixed roots and the actual Local vault service/account constants. It rejects cleanup/protected-directory overlap and arbitrary symlinks, normalizes trusted system path aliases, and revalidates paths. The evidence adapter also binds the actual reset store directory to the protected directory in that scope; mismatched configuration fails closed. TLS identity and GoogleTV/ADB credentials are excluded from this Local cleanup scope.

Internal owner methods persist pending before invalidating admission, retain the exact record and save/begin method after uncertainty, and permit only exact recommit. Completion requires the matching pending record and never revives a captured context. The future cleanup caller must verify cleanup before asserting completion, suspend retained bridges and asynchronous writers, and resume only matching valid pending work. Completion must assert only verified Local cleanup and must not erase Cloud history, installation keys, or remote cleanup obligations. Existing iOS disconnect/removal flows remain unchanged, and no new iOS reset control is introduced.

## Reset session engine

An internal `DeviceLocalResetCoordinator` now sequences injected suspension and cleanup actions. It has no production adapters or presentation callers. A process-wide registry retains the exact owner, record and callbacks across coordinator reconstruction, rejects conflicting or overlapping cleanup/protected roots, and permits only one active driver. Cancellation does not release that driver until an awaited callback actually returns.

Recovery inspects only validated reset evidence and grants no management lease. It never generates a reset UUID. Cleanup requires confirmed durable pending intent and successful suspension, followed by another pending-evidence check. Failed work remains recoverable; uncertain completion retries the exact persistence operation without repeating cleanup. Confirmed completed state on fresh recovery performs no actions. Completed sessions retire after driver exit so a fresh root can use a new owner and callbacks; old handles remain terminal.

Tests cover reattachment, cancellation-ignoring callbacks, failed suspension/cleanup, uncertain intent/completion, conflicting scopes, protected-root overlap and a second reset with a fresh owner. Production bridge suspension, durable filesystem cleanup and root replacement remain unimplemented.

## Terminal writer suspension

Calendar, screen preferences, temporary activation and WebView bridges now expose suspension primitives, with no production reset caller yet. Calendar's default domain covers existing and newly constructed services and rejects late responses before storage writes. Preferences serialize suspension with complete synchronous access, including reads that create archives, across all instances using the same canonical root. Temporary activation and bridges reject reactivation and stale queued callbacks; temporary checkpoint callbacks carry their original lifetime.

Suspension is terminal in this slice. Cleanup adapters and any qualified fresh-root reopening remain separate work. Bridge suspension does not itself suspend shared Calendar/preferences domains; future orchestration must suspend every writer before deletion. These in-process gates do not exclude external filesystem writers. The polling regression verifies a discarded runtime can deinitialize while a transport ignores cancellation.

## Filesystem cleanup primitive

`DeviceLocalFilesystemCleanup` executes a fixed plan beneath an approved anchor, retaining root directories. Plans distinguish complete directory contents from exact named files, reject protected-root overlap, and expose deterministic versioned metadata binding paths, modes, names and traversal limits. Production reset scopes must incorporate those semantics before using this primitive.

Traversal and deletion use held directory descriptors with no-follow checks. Descendant symlinks are unlinked without following them; root symlinks, special nodes, mount crossings and capacity overflow fail closed. Each modified parent is synchronized. Missing paths require synchronization of the nearest existing parent, so interrupted cleanup can replay the whole plan. Protected directory identities are excluded as well as their configured paths.

There are no production callers, credential deletion, reset-record writes or completion assertions in this primitive. Application writers must already be suspended and cleanup exclusively owned. Identity checks detect tested replacements, but cannot provide atomic inode-conditional unlink against arbitrary concurrent same-UID mutation. Fault-injection tests do not qualify physical power loss. The future Apple adapter must preserve the preference lock, unrelated files, TLS/GoogleTV/ADB storage and all Cloud recovery evidence.

## Explicit Apple cleanup configuration

An opt-in version-2 scope now binds the complete filesystem plan and exact five Local credential items into its digest. Existing production configuration remains version 1; neither pending nor completed version-1 records are reinterpreted or rewritten. Preferences cleanup names only `preferences-v1.json`; unknown legacy temporary files remain untouched, so complete legacy preference erasure is not claimed.

The internal Apple adapter requires a coordinator-issued synchronous permit. The permit checks the current driver, successful suspension, exact pending record and matching scope for each destructive step, with the operation executed under authority serialization. It expires when the callback returns. An existing asynchronous test session cannot upgrade into a qualified cleanup session. Core authorization wrappers must invoke each operation exactly once and cannot hide operation failures.

Each exact Keychain deletion is followed by a throwing absence check; unrelated accounts and Cloud credentials are preserved. No production bootstrap/UI caller or suspension-domain reopening is connected. Scope migration, unknown temporary-file policy and qualified fresh-root reopening remain separate release work.

## Qualified writer reopening

An internal writer bundle now retires Calendar and the canonical preferences domain together. Its opaque retirement evidence covers only those two domains: callers must separately suspend hosts, temporary activation, bridges and WebViews before cleanup. Existing instances retain their original generation permanently; bridges capture their Calendar service at construction so queued work cannot acquire a replacement service.

The Apple adapter returns a receipt only after all cleanup and a final matching pending-evidence check. A qualified coordinator retains that receipt and retirement across exact completion retries, then issues a one-use reopening capability after verified durable completion and driver exit. Cancellation during completion retains the session for explicit recovery without repeating cleanup. Arbitrary completed records and generic cleanup callbacks cannot mint a capability.

Opening validates the exact bundle, scope, roots, retired generations and current completion before atomically replacing both domains. Mixed default/custom bindings are rejected. Failed preparation leaves both domains retired; old objects and replayed capabilities remain unusable. Preferences normalize trusted system aliases consistently before consulting the process-wide gate.

Sixty focused tests and an iOS Simulator build passed for this slice. Production reset/root/UI callers, deterministic preference temporary files, full writer detachment and physical-device qualification remain separate work. Unknown historical preference temporary files remain preserved.

## Durable preference replacement

Preferences now write through the exact reserved `preferences-v1.pending` file under the existing process gate and file lock. Descriptor-relative no-follow access validates roots, lock, archive and temporary file bindings; complete writes are followed by file sync, replacement and directory sync. Existing ancestors are only opened and verified. Newly created directories retain exact setup bindings across in-process failure and synchronize only those children and their parents.

A failed attempt retains its exact encoded bytes and original/installed file identities across store instances. Ordinary access remains blocked until exact recommit; conflicting external changes and retired generations cannot replay it. After restart the archive alone is authoritative, and the reserved scratch file is never promoted. Unknown historical temporary files remain untouched. An explicitly selected v3 cleanup scope includes the reserved scratch name; v2 and the production default remain unchanged.

On iOS, protection is assigned before writing content and verified against the required policy. Simulator builds alone tolerate missing protection readback after successful assignment and unchanged empty-file verification; explicit mismatches still fail. Physical-device builds require an exact readback. This accommodates observed Simulator metadata behavior and does not qualify device encryption.

Validation: 80 focused tests, production iOS Simulator build, and an isolated iOS 26.5 Simulator create/set/get runtime smoke passed. Physical-device protection and actual crash/power-loss qualification remain outstanding. No production reset orchestration or UI caller is added.

## Terminal runtime retirement

Each running host/root now owns a terminal lifetime. Retirement stops host recovery/listening and temporary activation, fences existing Home Assistant, generic and public-read capabilities at operation time, and retires registered WebView coordinators. Navigation, deferred settings acknowledgments, foreground re-entry and late asynchronous runtime construction cannot revive that generation. Root brightness stops and current generic runtime credentials are cleared only from its in-memory store; persistent credential vaults and installed content remain unchanged.

A fresh root must use a new lifetime. Ordinary backgrounding, coordinator stop and management revocation retain their previous behavior. Requests admitted before retirement cannot be undone; late results and local publication are rejected. These primitives do not initiate a reset, change scope defaults or replace the root after cleanup. Production lifecycle orchestration remains the next step.

Validation: full Apple suite executed 320 tests with four existing opt-in skips and zero failures, including nine new lifetime/retirement tests. The iOS Simulator app build passed.

## Production reset lifecycle

Production bootstrap now deliberately selects the v3 cleanup scope. It inspects reset evidence before loading retained content or constructing a management host. A matching pending operation resumes with its original identity; corrupt, inaccessible or mismatched evidence shows an empty blocked state. Earlier v1/v2 scope records are not reinterpreted or migrated. A fresh process observing matching completion performs no cleanup.

The lifecycle retains its exact authority, coordinator and writer bundle through uncertain intent or completion. It retires the host, WebViews and writer domains before qualified cleanup, then requires the cleanup receipt, durable completion and one-use reopening capability before creating a fresh authority, host and view identity. Failure to construct the replacement host retries construction only. Shared bootstrap instances reuse an admitted host; a second reset uses a new coordinator and writer generation. If uncertain evidence already fenced writers but later appears absent or merely completed without the retained capability, this process remains blocked; it cannot reopen those writers on that evidence alone.

The existing non-iOS disconnect action accepts an explicit lifecycle callback and is hidden when none is supplied. The current production entry point is the iOS kiosk: it gains pending-reset recovery, with no new iOS reset-initiation control. The iOS screen disconnect/remove actions retain their separate behavior. Cleanup preserves Cloud authority/history/credentials, TLS, Google TV and ADB records, and unknown historical preference temporary files; it is not a claim of complete device erasure.

Validation uses isolated roots, credential backends and test TLS identities. No reset of personal app data is part of implementation validation. Physical-device protection, power-loss recovery, live providers and accessibility qualification remain release gates.
