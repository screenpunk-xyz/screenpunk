# Native installation recovery primitives

These local primitives support the agreed recovery requirements without defining an enrollment wire contract. They are not connected to production startup, Local management, Cloud onboarding, or network requests. A workspace receipt and a human sign-in generation still confer no installation authority.

## Durable local evidence

`DeviceManagementTransitionStore` holds one versioned nonsecret record: an immutable local transition UUID, opaque Keychain reference, and either unresolved intent or a local fence. The fence records local revocation evidence only; it says nothing about remote activation, revocation, or slot cleanup. There is no rotation, deletion, unfencing, or remote status promotion in this first slice.

Reads distinguish confirmed absence from invalid, unsupported, oversized, or inaccessible state. Writes serialize through a disk lock, sync the temporary file, replace the record, and sync its directory. Darwin requests a full file flush where supported. A failed write blocks eligibility within the process, including reconstructed store instances, until the exact attempted record is durably recommitted. Diagnostic readback alone is not authorization. Restart reads the surviving committed record. These checks do not qualify hardware power-loss behavior.

The default management directory is a sibling of the legacy device directory, so legacy device erasure does not erase this record. Custom callers must preserve the same separation. Production reset still needs an explicit recovery/authority gate before integration.

## Credential staging and classification

The dedicated Cloud Keychain service stores device-only, nonsynchronizing, 32-byte random secrets through create-only insertion. Existing material is loaded, never overwritten. A duplicate insertion loads the existing winner; other write uncertainty requires exact same-reference readback. Metadata enumeration returns references, not secrets. Missing, malformed, inaccessible, and orphaned material remain distinct blocked conditions.

A new operation must durably save and verify its intent before generating a secret. An existing intent with a missing key cannot safely regenerate: the primitive cannot distinguish a crash before staging from loss after a future remote attempt. Resolving that case requires a later recovery contract.

Legacy Local eligibility requires a confirmed absent journal and confirmed empty dedicated service. An unresolved intent blocks Local. A local fence is eligible only when the stored key and all enumerated references match its binding. Classification does not erase credentials or remote cleanup obligations. Future startup integration must run this classification before constructing or advertising a Local host and must reject stale Cloud work independently of retained-content grants.

## Remaining integration

Accepted backend schemas and recovery fixtures must define candidate claim, activation/status proof, promotion, terminal recovery, remote cleanup, and subsequent transitions. Startup/reset integration, queued-command rejection, live Keychain behavior, physical-device testing, and hardware power-loss qualification remain separate work. Tests here inject credential backends and filesystem commit failures; they do not access personal Keychain items or enroll a real device.

The classifier returns a snapshot, not a lock or an activation capability. The future bootstrap/management owner must serialize classification with transition writes and keep its generation guard across subsequent startup and asynchronous work. Journal and Keychain operations are not one transaction; passing classification must never be cached across a later transition or used to bypass a fresh authority check.

The one-record limitation must be removed before Cloud startup or erase paths are enabled. Production must support repeated Local → Cloud → Local → Cloud transitions and credential rotation while preserving earlier authority fences and outstanding remote cleanup obligations. Credential generations and management-authority transitions are separate concepts; account-owned active installation authority must not depend solely on the original human claimant. Their backend representations are not defined by this primitive format.
