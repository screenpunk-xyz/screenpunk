# Unmounted native package qualification

`DevicePackageQualifier` validates supplied manifest and asset bytes against an explicit stored revision, target viewport and native profile ID. Its privately constructed result is not an installation receipt, filesystem durability proof, grant, approval or management capability. Legacy deployment and restoration behavior is unchanged.

Qualification bounds manifest bytes to 2 MiB, JSON depth to 32 and values to 65,536. At most 2,000 assets and 50 MiB of manifest plus asset content are admitted. Paths are limited to 1,024 UTF-8 bytes in the native ASCII path domain. Bounds precede parsing and copies; inputs are rejected rather than truncated.

The manifest preflight rejects malformed UTF-8, duplicate decoded keys, unpaired surrogates, unsupported nested fields and invalid schema shapes. Existing semantic validators then check provisioning, device behavior and event navigation. Asset paths remain exact: absolute paths, traversal, aliases, backslashes, empty segments and the reserved manifest name are rejected. Declared and supplied asset sets, lengths and SHA-256 hashes must match, including entrypoint membership.

Native dashboard/revision identity, exact UTF-8 name and explicit profile identity must match the expectation. The requested orientation is applied to the target viewport before dimension checks. The target profile has no scale/safe-area identity, so finite/value constraints are validated without inventing equality evidence.

The deployment digest uses the existing native Codable projection: omit `digest`, sort the inventory and encode with sorted keys without escaping slashes. The original manifest bytes and their separate SHA-256 remain available. Only real CryptoKit hashing is accepted; unsupported platforms fail closed. There is no alternative-digest fallback or rewriting of historical identities.

Qualification passed 217 Core tests on accepted main `ff538ecc` plus only the three new files, including eight package tests and 29 accepted native numeric/Unicode codec fixtures. That host-specific parity is not proof for every supported iOS version, physical device or rendered package. Filesystem preparation, immutable grants, foreground admission and all-writer coordination remain separate prerequisites before mounting this code.
