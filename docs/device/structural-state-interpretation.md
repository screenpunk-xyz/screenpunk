# Structural state interpretation

This unmounted Core reader classifies caller-supplied bytes, read errors, missing-state evidence and package references. It does not read directories, generate identifiers, migrate state, commit content or grant authority. Public Codable snapshot values are unvalidated containers; the reader validates supplied evidence before returning a classification.

Missing structural evidence is not proof of a clean installation. A caller that already expects a bound generation receives a blocked result when it is missing or mismatched. An explicit valid bound snapshot with no entries represents empty content. Legacy ordered, single-package and empty states remain unbound and retain their exact bytes, SHA-256, owner, package references, names and grant references. CryptoKit is required for the legacy evidence digest; unsupported platforms return `digestUnavailable` instead of using a noncryptographic substitute.

Opaque entry IDs and structural generation are supplied by a future qualified writer. They are not inferred from deployment IDs or content hashes. A local display name remains separate from the package revision's name. Configured selection is explicit in the bound snapshot; neither the original deployed selection nor the mutable displayed selection is silently promoted from legacy state. Only retained-Local provenance is defined here.

Structural input is limited to 64 KiB and 4,096 values; legacy input to 4 MiB and 65,536 values. Both are limited to depth 32. A private lexical preflight rejects duplicate keys, malformed UTF-8 and surrogate escapes before Foundation decoding. Schema checks reject unknown nested fields, unsupported versions, invalid references, inconsistent selection and mismatched supplied packages. Oversized legacy evidence blocks without truncation.

The next persistence layer must qualify actual filesystem reads, package/grant integrity, explicit migration and a durable complete-set transaction with exact operation outcomes. Parsed snapshots, legacy LAN receipts and these pure classifications do not establish Cloud activation or remote permission.
