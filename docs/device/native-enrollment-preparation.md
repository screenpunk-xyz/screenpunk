# Pure enrollment preparation proposals

`NativeEnrollmentPreparation` models nonsecret preparation intent and recovery classifications. It has no serializer, filesystem or Keychain adapter, secret generation, network transport, production caller or management authority. Caller-supplied stage descriptors are metadata, not proof of possession or qualification of a secret.

A proposal binds caller-chosen preparation, enrollment, transition, credential and claim-request identities, exact claim inputs, staging and final references, and exact source/target history and enrollment snapshots. Existing bindings, order and fences are preserved. Every historical native48 binding requires exactly one retained completed preparation and its declared staging item; legacy32 bindings require no staging item. Unknown, inaccessible, malformed or missing acknowledged items block classification.

The phases are intent, stage attempted, stage qualified, paired evidence qualified, promotion attempted, promotion qualified and complete. Before staging qualification, both history and enrollment must match their source snapshots. During paired-write uncertainty, each may match only its exact source or target. Paired qualification and subsequent phases require both targets. Enrollment snapshots use exact encoded bytes, preserving UTF-8 distinctions. Observations are monotonic proposals and do not acknowledge I/O.

Confirmed absence before staging is distinct from absence after an attempted insert. The latter remains ambiguous and does not permit regeneration, adoption of an arbitrary key, a remote attempt or Local authority. Future platform integration must qualify an immutable staging envelope and exact final secret before converting these metadata observations into durable state.

There may be at most 64 retained preparations and one unfinished preparation. Existing history and enrollment limits apply. Structural reservations are bounded to 2 MiB per preparation and 128 MiB in aggregate; these are conservative completion reservations, not an implemented durable record format. History and staging obligations are not pruned.

Validation: the exact repaired PR97 tree plus the two new files passed 209 Core tests, including five preparation tests for phase ordering, paired uncertainty, exact inputs, historical inventory, identity and capacity. No live credentials or remote services were used.
