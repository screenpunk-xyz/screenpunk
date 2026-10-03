# Unmounted structural commit store

`DeviceStructuralStore` is internal persistence machinery for a future single authoritative structural envelope. It has no production caller and does not migrate Local state, verify package ownership or grants, or grant management authority. Resource assertions remain untrusted input until a future admission layer validates them.

The caller supplies an existing owned root, root UUID, structural generation and explicit selection. Explicit initialization binds the canonical path and directory, lock and operations-directory identities. A visible root binding after a failed write is insufficient: exact initialization recovery synchronizes the owned binding, lock and directories before the first prepare.

An operation retains exact old and candidate bytes. Durable initial intent precedes candidate staging; prepared intent binds the baseline and candidate inode before replacement. Recovery rejects same-byte replacement of an installed candidate, missing terminal history and changed root bindings. A diagnostic read never acknowledges durability. Exact recommit synchronizes the current envelope and retained proof; replay of an older operation cannot replace or qualify a newer tip. Shared process qualification is invalidated before an attempt, preventing another instance from preparing a successor after an uncertain terminal write.

Limits are 128 KiB per envelope, 32 KiB each for intent and outcome, 8 KiB for opaque resource assertions and 384 KiB per operation. There is at most one unresolved operation and 128 retained terminal operations; history is never pruned to regain capacity. The bounded directory scan admits at most 260 names, including staging twins. Corrupt or partial staging fails closed; an unrecorded candidate staging inode can only be repaired by its original live attempt.

Descriptor operations reject symlinks and special files and synchronize only owned storage, not unrelated ancestors. These checks assume exclusive cooperating writers. They do not guarantee exclusion of hostile same-UID mutation, portable backup restoration, rollback resistance or physical power-loss behavior.

Qualification: the exact reviewed PR95 tree plus only the three new implementation/test files passed 206 Core tests, including 12 store tests. No production mount, automatic migration, network operation or user-data cleanup was exercised.
