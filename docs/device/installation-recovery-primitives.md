# Native installation recovery primitives

These local primitives support the agreed recovery requirements without defining an enrollment wire contract. Production iOS startup now uses them to check Local eligibility before constructing a management host. Local listener and management operations also carry captured admission. Cloud onboarding and Cloud network requests remain unconnected. A workspace receipt and a human sign-in generation still confer no installation authority.

## Durable local evidence

`DeviceManagementTransitionStore` holds a version 2 nonsecret history with separate transition entries and credential-generation bindings. Each transition has an immutable UUID and either unresolved intent or a local fence. Each credential generation has its own distinct UUID, transition binding, and immutable Keychain reference. Multiple generations may belong to one unresolved transition, without selecting an active credential or claiming that remote rotation occurred.

Only the final transition may remain unresolved. A new transition may append after prior transitions are fenced; all previous bindings and fences remain. Updates cannot drop, reorder, reuse, or unfence history. Capacity is bounded at 64 transitions, 128 credentials, and 64 KiB; exhaustion blocks instead of pruning recovery evidence. Fences record local revocation evidence only, not remote activation, revocation, or completed slot cleanup. Version 1 records migrate deterministically in memory while preserving their phase and reference; the next successful save commits version 2. Inspection alone does not rewrite the file.

Reads distinguish confirmed absence from invalid, unsupported, oversized, or inaccessible state. Writes serialize through a disk lock, sync the temporary file, replace the record, and sync its directory. Darwin requests a full file flush where supported. A failed write blocks eligibility within the process, including reconstructed store instances, until the exact attempted record is durably recommitted. Diagnostic readback alone is not authorization. Restart reads the surviving committed record. These checks do not qualify hardware power-loss behavior.

The default management directory is a sibling of the legacy device directory, so legacy device erasure does not erase this record. Custom callers must preserve the same separation. Production reset still needs an explicit recovery/authority gate before integration.

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

The owner currently exposes only classification, revocation, and short synchronous gated operations. It does not stage credentials, write fences, or recover uncertain writes. Those mutation APIs require a separate exact-write recovery design before Cloud transitions can use this owner. All production Cloud transition writers remain disabled. The existing standalone recovery primitives are unchanged.

Future callers must share one owner, acquire authority before the server lock, and keep network waits outside the gated operation. Listener readiness, peer handshakes, and pairing approval must recheck their captured lease before committing a side effect. A lease must not authorize queued work without another check. External processes and direct filesystem or Keychain writers are not excluded by this lock; it is not a persistent antirollback mechanism.

Production iOS bootstrap now classifies through one lifetime owner before creating TLS or a management host. Blocked startup uses a separate read-only retained-content loader and a Retry action. It preserves package bytes and grants, validates manifest metadata when present, and permits in-memory screen switching. Connector-backed data is unavailable in this fallback because it constructs no connector runtimes. A host whose TLS setup failed returns to the blocked state.

The admitted host now carries a mandatory captured context into the server. Listener restarts, accepted requests, local mutations, temporary-selection checkpoint writes and erase admission validate that context. Revocation cancels pending/current listeners and accepted connections while preserving retained content authority. Network readiness and pairing approval waits occur outside authority/server locks, then recheck before commit. Invalidation observers and transaction callbacks run after releasing locks. Cloud transition writers remain disabled.

Erase admission is enforced, but reset durability is not yet repaired: legacy unlink still suppresses some vault/disk failures and can have partial effects. Legacy silent persistence paths also remain. Those paths require separate work before claiming recoverable reset. The journal and dedicated Cloud credential service must remain outside destructive Local cleanup. Focused tests verify blocked factory exclusion and eligible factory admission using a throwing factory; they do not verify successful host construction or physical-device Keychain behavior.
