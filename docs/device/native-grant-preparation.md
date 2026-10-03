# Native grant preparation mechanics

This unmounted Core store prepares immutable grant revisions using an injected credential backend. It has no Keychain implementation, production caller, migration, reset integration or authority to serve credentials.

A supplied request is requalified against its complete grant input and qualified package expectations. The store reserves bounded capacity and writes an exact nonsecret operation intent before adding private data. The backend then receives an add-only private intent containing the complete input, followed by credential items. Captured persistent references are recorded before dependent additions. Shared credential revision IDs are reused only with previously retained identity and exact bytes.

Public filesystem records contain projected metadata, sizes and opaque nonsecret persistent references; they contain no secret-bearing input fields or secret hashes. The backend contract requires immutable bytes and stable replacement identities. Backend acknowledgment does not establish physical durability. A future Apple adapter must separately qualify this contract.

Terminal and head candidate inode identities are recorded before rename. The head records its exact predecessor bytes and inode; confirmation binds the installed head after synchronization. Every write attempt invalidates shared process qualification. Restart requires exact latest-operation recommit, including head/terminal synchronization, before a successor. Read-only diagnosis never acknowledges durability. Replaying an older retained operation cannot qualify a different current tip. Verification rechecks current metadata, backend identities and bytes.

Unknown additions are preserved and blocked. If a process dies after a private addition or head/terminal inode creation but before its identity is durably recorded, restart cannot adopt it from matching bytes. A surviving process may retry using its captured exact identity. This recovery limitation must be resolved or explicitly handled before production mounting; the slice makes no release-ready recovery claim.

Initialization requires an explicit preexisting owned root disjoint from caller-supplied protected roots. Descriptor-relative operations reject symlinks, hard-linked files, replaced installed identities and unknown residue. No ancestor directory is synchronized or created. There is no pruning: at most 128 retained terminal operations, one unresolved operation, 4096 credential IDs, 128 MiB retained private intents and 32 MiB credential bytes. Individual private intents are bounded to 4 MiB and credentials to 8 KiB; capacity is reserved before private effects.

## Qualification

Exact accepted `a4fb088f80464d8b637472a9c83466a85fdb03a5` plus the three new Core files passed 13 focused tests, 292 full Core tests and an unsigned iOS Simulator build. Fake-backend tests cover exact retry fault boundaries, restart orphan blocking, same-byte identity replacement, head deletion, two-instance uncertainty, historical replay, secret projection and sharing, capacity and protected sentinels. No live Keychain, personal credentials, physical-device durability or production reset was exercised.
