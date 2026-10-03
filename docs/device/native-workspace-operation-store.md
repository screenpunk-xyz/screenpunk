# Unmounted workspace setup operation journal

`CloudWorkspaceSetupOperationRecord` and `CloudWorkspaceSetupOperationStore` retain the exact user, request and optional matching receipt for the accepted workspace setup contract. A receipt is operation evidence, never device-management authority. The existing application journal and coordinator are not switched to this store by this slice.

The fixed new directory `xyz.screenpunk.cloud-operations` is a sibling of `xyz.screenpunk.device`. Any object or ambiguous lookup at the legacy `native-workspace-setup.json` blocks access without decoding, copying or deleting it. No migration is automatic. An ordinary 0755 legacy directory is valid for read-only absence lookup; the new owned directory and regular files require private permissions.

The record is bounded to 16 KiB, with strict version, duplicate-key, nested-field and Unicode-escape checks. Initial save requires a pending request; only its matching receipt or exact retry may follow. `beginSuccessor` explicitly starts a different request after completion. The caller supplies request identifiers; recovery never invents one.

The store retains the exact method and encoded attempt before side effects across instances. A bounded 64 KiB persistent attempt records baseline bytes and inode, the exact predecessor acknowledgement, root/lock identities, and the prepared candidate inode. Intent is synchronized before candidate effects; prepared evidence is synchronized before replacement. Missing, corrupt or replaced predecessor acknowledgement blocks recovery, while an exact target acknowledgement may be recommitted after a lost acknowledgement or synchronization failure.

Files are opened relative to verified descriptors without following links. Cooperating processes serialize with `flock`; created-directory synchronization failures retain the exact child/parent binding for retry. Existing unrelated ancestors are not synchronized. In-process scratch is repairable only with captured inode and intended-byte evidence; restart never promotes unrecorded scratch. Diagnostic readback cannot acknowledge an uncertain attempt. Restarted reads of matching acknowledgement evidence conservatively synchronize and recheck the exact files.

On iOS, empty files receive complete-until-first-authentication protection before content is written. Devices require exact protection readback. Simulator builds permit unavailable readback only after successful assignment and empty-inode checks; an explicit mismatch still fails. This does not qualify physical-device protection or power-loss behavior.

No HTTP, Keychain, provider configuration, UI, reset scope, existing application adapter or production caller is changed. Arbitrary same-UID mutation and rollback are outside the cooperating-writer model. Production integration must retain requests before HTTP and recover the same operation after uncertainty.
