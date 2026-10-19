# Local enrollment evidence codec

`NativeEnrollmentEvidenceCodec` encodes and decodes a versioned local representation of enrollment evidence. It is not an HTTP decoder, journal or authority decision. The existing evidence types remain Encodable-only; decoding reconstructs them through validated inputs and the enrollment reducer.

The local schema uses explicit event kind tags. Parsing rejects duplicate decoded keys, unknown fields and versions, incorrect types, malformed UTF-8, invalid surrogate pairs, invalid UUID syntax, trailing input and illegal event order. Repeated persisted events are rejected even when the runtime reducer would treat the observation as an idempotent retry. Decoded names, profiles and timestamp strings preserve their exact UTF-8 content.

Admission is bounded to 1 MiB, 64 records, 8 KiB per record, four events per record, depth 16 and 65,536 parser nodes. A private chronological history view permits structural replay of retained, fenced records without modifying the caller's history. Complete-history UUID role checks reject collisions with later transitions and credentials. This temporary replay view never grants permission to resume an operation; recovery still evaluates the actual history and separately qualified credentials.

Six codec tests and the full 215-test Core suite passed on accepted main `ff538ecc` plus only the two codec source/test files. Tests cover fenced proposals, terminal and historical activation evidence, cross-role collisions, exact round trips, unknown fields, malformed input, duplicate events and capacity bounds. Persistence, immutable credential staging, HTTP and production callers remain separate work.
