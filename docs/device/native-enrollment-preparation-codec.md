# Native enrollment preparation reconstruction

`NativeEnrollmentPreparationCodec` encodes and strictly decodes a versioned local reconstruction proposal. It preserves exact claim inputs, source histories, enrollment observations and phase metadata, then independently derives and compares the asserted targets and capacity reservation.

A decoded proposal is not a `NativeEnrollmentPreparation` handle. Phase metadata does not prove a Keychain operation, durable write, promotion, or management authority. Reconstruction requires the complete ordered retained proposal chain, including one completed proposal for each historical native credential binding. Later fences and appended observations must preserve that chain. Legacy credential records remain intact.

The streaming overload consumes a privately constructed `NativePreparationReconstructionContext` and returns a proposal plus an optional continuation. Only completed metadata produces a continuation. The context retains up to 64 compact declarations and the latest derived target history/enrollment pair. Each next source preserves that pair's exact ordered prefixes and every historical declaration's identities, claim and stage reference, making preservation transitive. Historical preparation IDs cannot be reused by later server observations. The existing array overload remains available and rejects the same aliasing case.

Retained canonical payload is bounded to 1,638,400 bytes: one history, one enrollment snapshot and bounded declarations. This is not an exact Swift heap-footprint claim. Callers processing records one at a time need not retain all source/target snapshot pairs. The context acknowledges no persistence or secret qualification and supplies no operational handle.

Each document is bounded to 2 MiB, depth 16 and 131,072 JSON nodes. Parsing rejects unknown or duplicate fields, invalid UTF-8 and surrogate escapes, unsupported schemas, role collisions, altered target assertions, and incomplete historical mappings. Source and target enrollment evidence use the strict enrollment evidence codec. Exact native encodings preserve input bytes and timestamp lexemes instead of treating Unicode normalization as identity.

This slice has no storage, secret generation, Keychain access, network request, production caller, or authority admission. A later persistence adapter must supply durable phase ordering and real inventory qualification; the codec does not manufacture inventory to reconstruct an operational handle.

Validation: six focused tests and 253 Core tests passed against accepted main `99ada1cda83552297fdca858641bf6bc8067d845` plus the two codec files. Tests cover all phase metadata, target derivation, exact Unicode inputs, malformed and bounded JSON, retained historical mappings, later fences and observations, and the 128-credential boundary.

The streaming extension passed ten focused and 257 full Core tests on exact merged `b9f5238af5c3ff3470e491e03b1010e3c17a2d83` plus only the two modified codec files. Coverage compares array/stream acceptance, rejects altered claims and event prefixes, exercises all historical ID roles, and processes a 63-record chain to the existing transition limit without retaining its aggregate snapshots.

`NativeEnrollmentPreparation.assessingReconstruction` combines a validated streaming step with caller-supplied current history, enrollment evidence and complete inventory. The step privately retains its preceding compact declarations so callers cannot replace the historical mapping. The assessment returns a recovery classification, never an operational preparation handle or a mutation method.

Intent and stage-attempt metadata require the exact source pair. Stage-qualified metadata accepts only the four exact source/target pair combinations; later phases require both targets. Every historical native binding needs its retained declaration, staging descriptor and final item. Unknown, inaccessible, malformed, missing or mismatched items block assessment. Absence after an attempted stage remains ambiguous and never authorizes regeneration.

All assessments require external inventory, paired-evidence durability and journal durability qualification. A matching staging descriptor still needs immutable-envelope and secret qualification; a declared native48 item still needs exact external key qualification. Completed metadata proves neither. Blocked results supply no item-adoption plan. This API does not access Keychain or disk and does not acknowledge prior IO.

Assessment validation passed 20 focused and 272 full Core tests on exact accepted `c682243843c2c4bf697b849dbf0c37af9e96c442` plus the three source/test files. New controls cover every phase and pair combination, inventory omissions and extra items, exact UTF-8 evidence and stage inputs, retained historical mapping, and count limits.
