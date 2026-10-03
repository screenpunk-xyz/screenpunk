# Native enrollment preparation reconstruction

`NativeEnrollmentPreparationCodec` encodes and strictly decodes a versioned local reconstruction proposal. It preserves exact claim inputs, source histories, enrollment observations and phase metadata, then independently derives and compares the asserted targets and capacity reservation.

A decoded proposal is not a `NativeEnrollmentPreparation` handle. Phase metadata does not prove a Keychain operation, durable write, promotion, or management authority. Reconstruction requires the complete ordered retained proposal chain, including one completed proposal for each historical native credential binding. Later fences and appended observations must preserve that chain. Legacy credential records remain intact.

Each document is bounded to 2 MiB, depth 16 and 131,072 JSON nodes. Parsing rejects unknown or duplicate fields, invalid UTF-8 and surrogate escapes, unsupported schemas, role collisions, altered target assertions, and incomplete historical mappings. Source and target enrollment evidence use the strict enrollment evidence codec. Exact native encodings preserve input bytes and timestamp lexemes instead of treating Unicode normalization as identity.

This slice has no storage, secret generation, Keychain access, network request, production caller, or authority admission. A later persistence adapter must supply durable phase ordering and real inventory qualification; the codec does not manufacture inventory to reconstruct an operational handle.

Validation: six focused tests and 253 Core tests passed against accepted main `99ada1cda83552297fdca858641bf6bc8067d845` plus the two codec files. Tests cover all phase metadata, target derivation, exact Unicode inputs, malformed and bounded JSON, retained historical mappings, later fences and observations, and the 128-credential boundary.
