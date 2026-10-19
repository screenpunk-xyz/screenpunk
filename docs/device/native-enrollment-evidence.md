# Native enrollment evidence

The Core enrollment model is an unmounted, Encodable-only representation of claim and activation inputs and observed receipts. It follows the accepted native installation contract at Cloud commit `e7029fecc86a48934f48ca55604ce92c22dd2604`. It does not decode raw responses, persist requests, generate credentials, send HTTP, or authorize management.

A claim proposal references an existing `nativeInstallationV1` binding in the current intent transition. Legacy 32-byte bindings cannot be used. Request, transition, local enrollment, credential generation, installation, challenge and server generation identities retain separate roles. Inputs preserve the exact UTF-8 name and profile. A later observation cannot silently change the account, location, request or transition. Server identities cannot be reused across enrollment records.

The reducer retains claim proposal, pending observation, activation proposal and historical activation observation in order. A terminal claim observation is retained as evidence. Exact duplicate observations do not append; conflicting or illegal successors fail. Historical activation and terminal claim evidence never prove current remote authority or permit Local mode. Recovery plans explicitly require external durable or recovery qualification before any request.

The model permits at most 64 enrollment records, four events per record, an 8 KiB per-record completion reservation and 1 MiB total encoded evidence. It never prunes history to make room. Timestamp validation rejects invalid calendar components and offsets; historical receipt validation does not infer current validity from the wall clock. Claim and generation intervals match the frozen server contract.

The public constructors and reducer accept caller-supplied typed evidence. Constructor success is not protocol trust. A strict raw-response decoder, durable exact-input operation journal, complete credential inventory, authenticated transport, current status and rotation/revocation reconciliation remain separate prerequisites. This slice does not implement cancel, revoke, rotation, current status or production enrollment.

Validation: 203 Core tests passed on an isolated copy of the reviewed format-migration tree plus these three source/test files, including nine enrollment tests. This does not qualify a live provider, Keychain persistence, network recovery, or installation authority.
