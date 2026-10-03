import Foundation
import CryptoKit
#if os(macOS)
import Darwin
import Security

/// The checkpoint is held outside the restorable catalogue files. A missing or mismatched
/// checkpoint fails closed; copying an older catalogue directory cannot lower the trust floor.
struct ToolchainTrustCheckpoint: Codable, Equatable {
    let slot: Int
    let sha256: String
    static let bootstrapping = ToolchainTrustCheckpoint(slot: -1, sha256: String(repeating: "0", count: 64))
}

protocol ToolchainTrustAnchoring {
    func read() throws -> ToolchainTrustCheckpoint?
    func commit(_ checkpoint: ToolchainTrustCheckpoint) throws
}

/// The service/account names must come from independently installed release configuration.
struct KeychainToolchainTrustAnchor: ToolchainTrustAnchoring {
    let service: String
    let account: String

    func read() throws -> ToolchainTrustCheckpoint? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let result = try? JSONDecoder().decode(ToolchainTrustCheckpoint.self, from: data),
              (result.slot == -1 || result.slot == 0 || result.slot == 1),
              WorkspaceValidation.sha256(result.sha256),
              (result.slot != -1 || result == .bootstrapping) else {
            throw ToolchainTrustError.trustUnavailable
        }
        return result
    }

    func commit(_ checkpoint: ToolchainTrustCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ToolchainTrustError.trustUnavailable }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else {
            throw ToolchainTrustError.trustUnavailable
        }
    }
}

/// A signed-envelope journal. Every acceptance and conflict is replayed through the existing
/// resolver, so its independently reviewed equivocation semantics survive process restarts.
final class DurableToolchainCatalogStore {
    private struct State: Codable {
        let version: Int
        var highWater: Int
        var envelopes: [Data]
        var evidenceKeys: [String: Data]
        var revokedSignerIDs: Set<String>
    }

    private let root: String
    private let basePolicy: ToolchainTrustPolicy
    private let anchor: any ToolchainTrustAnchoring
    private let now: () -> Date
    private let nativeSignature: any ToolchainExecutableSignatureVerifying
    var installedKitRoot: String { basePolicy.installedKitRoot }

    init(root: String, basePolicy: ToolchainTrustPolicy, anchor: any ToolchainTrustAnchoring,
         now: @escaping () -> Date, nativeSignature: any ToolchainExecutableSignatureVerifying) throws {
        guard WorkspaceValidation.absolute(root), root != basePolicy.installedKitRoot else {
            throw ToolchainTrustError.unsafePath
        }
        self.root = root; self.basePolicy = basePolicy; self.anchor = anchor
        self.now = now; self.nativeSignature = nativeSignature
        let descriptor = try ownedDirectory(root)
        close(descriptor)
    }

    /// Explicit offline preparation may restore lost journal bytes only when
    /// they reproduce the existing device-local checkpoint exactly. It cannot
    /// replace a journal, advance/reset the anchor, or omit unknown history.
    func restoreMissingExactJournal(from envelope: Data) throws {
        try locked { directory in
            do { _ = try load(directory); return }
            catch ToolchainTrustError.catalogStateMissing { }
            guard let checkpoint = try anchor.read(), checkpoint.slot == 0 || checkpoint.slot == 1 else {
                throw ToolchainTrustError.trustUnavailable
            }
            guard envelope.count <= 8 * 1024 * 1024 else { throw ToolchainTrustError.limitExceeded }
            let (decoded, _) = try ToolchainCatalogJSON.decode(envelope)
            guard let signer = basePolicy.signers[decoded.signerKeyId] else {
                throw ToolchainTrustError.invalidCatalog
            }
            let candidates = [
                State(version: 2, highWater: basePolicy.acceptedSequence,
                      envelopes: [], evidenceKeys: [:], revokedSignerIDs: []),
                State(version: 2, highWater: max(basePolicy.acceptedSequence, decoded.payload.sequence),
                      envelopes: [envelope], evidenceKeys: [decoded.signerKeyId: signer.publicKey],
                      revokedSignerIDs: [])
            ]
            var recovered: Data?
            for candidate in candidates {
                if let bytes = try matchingEncoding(candidate, sha256: checkpoint.sha256) {
                    recovered = bytes; break
                }
            }
            guard let bytes = recovered, try anchor.read() == checkpoint else {
                throw ToolchainTrustError.catalogStateMissing
            }
            let temporary = "catalog.tmp-" + UUID().uuidString
            let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw ToolchainTrustError.unsafePath }
            defer { close(file); _ = unlinkat(directory, temporary, 0) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ToolchainTrustError.unsafePath }
                    offset += count
                }
            }
            guard fsync(file) == 0,
                  linkat(directory, temporary, directory, "catalog.\(checkpoint.slot)", 0) == 0,
                  unlinkat(directory, temporary, 0) == 0, fsync(directory) == 0 else {
                throw ToolchainTrustError.unsafePath
            }
            // Reuse the ordinary checkpoint/schema checks; the anchor is never written.
            _ = try load(directory)
        }
    }

    private func matchingEncoding(_ state: State, sha256: String) throws -> Data? {
        let encoder = JSONEncoder()
        let fields: [(String, Data)] = [
            ("version", try encoder.encode(state.version)),
            ("highWater", try encoder.encode(state.highWater)),
            ("envelopes", try encoder.encode(state.envelopes)),
            ("evidenceKeys", try encoder.encode(state.evidenceKeys)),
            ("revokedSignerIDs", try encoder.encode(state.revokedSignerIDs))
        ]
        let fragments = try fields.map { name, value -> Data in
            var result = try encoder.encode(name)
            result.append(0x3a); result.append(value)
            return result
        }
        // JSONEncoder's original top-level key order is not stable across
        // processes. Enumerate only the 5! orders of these known state fields.
        func search(_ order: [Int], _ remaining: [Int]) -> Data? {
            if remaining.isEmpty {
                var bytes = Data([0x7b])
                for (offset, index) in order.enumerated() {
                    if offset != 0 { bytes.append(0x2c) }
                    bytes.append(fragments[index])
                }
                bytes.append(0x7d)
                return sha(bytes) == sha256 ? bytes : nil
            }
            for index in remaining {
                if let bytes = search(order + [index], remaining.filter { $0 != index }) { return bytes }
            }
            return nil
        }
        return search([], Array(fragments.indices))
    }

    /// Explicit catalogue refresh only. A workspace open must never invoke this method.
    func accept(_ envelope: Data) throws {
        try locked { directory in
            let (state, checkpoint) = try initializedState(directory)
            if state.envelopes.contains(envelope) {
                let evidence = try replayEvidence(state)
                let live = try liveResolver(state, acceptedHashes: Set(evidence.accepted.map { sha($0.0) }))
                _ = try live.authenticateCatalog(envelope)
                _ = try evidence.resolver.authenticateCatalog(envelope)
                return
            }
            let (decoded, _) = try ToolchainCatalogJSON.decode(envelope)
            guard let signer = basePolicy.signers[decoded.signerKeyId] else {
                throw ToolchainTrustError.unknownSigner
            }
            if let prior = state.evidenceKeys[decoded.signerKeyId], prior != signer.publicKey {
                throw ToolchainTrustError.conflictingCatalog
            }
            var next = state
            next.evidenceKeys[decoded.signerKeyId] = signer.publicKey
            let evidence = try replayEvidence(next, extra: envelope)
            let live = try liveResolver(state, acceptedHashes: Set(evidence.accepted.map { sha($0.0) }))
            let current = try live.authenticateCatalog(envelope)
            do {
                _ = try evidence.resolver.authenticateCatalog(envelope)
                next.envelopes.append(envelope)
                next.highWater = max(next.highWater, current.payload.sequence)
                try commit(next, from: checkpoint, directory: directory)
            } catch ToolchainTrustError.conflictingCatalog {
                // A valid, contradictory signed payload must poison future sessions too.
                next.envelopes.append(envelope)
                try commit(next, from: checkpoint, directory: directory)
                throw ToolchainTrustError.conflictingCatalog
            }
        }
    }

    /// Persist an independently authenticated release-policy revocation. Revocations are
    /// monotonic; no workspace metadata or catalog entry may call this authority path.
    func recordReleaseRevocations(_ signerIDs: Set<String>) throws {
        guard signerIDs.allSatisfy(WorkspaceValidation.id) else { throw ToolchainTrustError.unknownSigner }
        try locked { directory in
            let (state, checkpoint) = try initializedState(directory)
            guard signerIDs.isSubset(of: Set(basePolicy.signers.keys).union(state.evidenceKeys.keys)) else {
                throw ToolchainTrustError.unknownSigner
            }
            var next = state
            // A revoked signer may never have signed an accepted envelope. Retain its
            // independently installed public key now so the anchored revocation can
            // survive later policy retirement without trusting an unknown ID.
            for id in signerIDs {
                if let trusted = basePolicy.signers[id] {
                    if let previous = next.evidenceKeys[id], previous != trusted.publicKey {
                        throw ToolchainTrustError.conflictingCatalog
                    }
                    next.evidenceKeys[id] = trusted.publicKey
                }
            }
            next.revokedSignerIDs.formUnion(signerIDs)
            if next.revokedSignerIDs != state.revokedSignerIDs ||
               next.evidenceKeys != state.evidenceKeys {
                try commit(next, from: checkpoint, directory: directory)
            }
        }
    }

    /// Holds the cross-process lock while the caller uses the approval and resolver. The caller
    /// must not retain them; each subsequent operation should resolve and verify anew.
    func withResolved<T>(_ requirement: WorkspaceToolchainRequirements.Requirement,
                         _ body: (TrustedToolchainResolver, ApprovedToolchainKit) throws -> T) throws -> T {
        try locked { directory in
            let (state, _) = try load(directory)
            let evidence = try replayEvidence(state)
            let live = try liveResolver(state, acceptedHashes: Set(evidence.accepted.map { sha($0.0) }))
            var eligible = [AuthenticatedToolchainCatalog]()
            var rejection: ToolchainTrustError?
            for (bytes, archived) in evidence.accepted {
                do {
                    _ = try live.authenticateCatalog(bytes)
                    eligible.append(archived)
                } catch let error as ToolchainTrustError {
                    if archived.payload.entries.contains(where: { matches(requirement, $0) }) {
                        rejection = error
                    }
                }
            }
            do {
                let approved = try evidence.resolver.resolve(requirement, catalogs: eligible)
                return try body(evidence.resolver, approved)
            } catch ToolchainTrustError.unknownKit {
                if let rejection { throw rejection }
                throw ToolchainTrustError.unknownKit
            }
        }
    }

    private struct EvidenceReplay {
        let resolver: TrustedToolchainResolver
        let accepted: [(Data, AuthenticatedToolchainCatalog)]
    }

    /// Archive verification reconstructs only equivocation evidence. Its permissive clock and
    /// historical keys never authorize a kit: liveResolver filters eligible catalogues first.
    private func replayEvidence(_ state: State, extra: Data? = nil) throws -> EvidenceReplay {
        var origins = basePolicy.allowedOrigins
        var publishers = basePolicy.approvedPublishers
        for bytes in state.envelopes + (extra.map { [$0] } ?? []) {
            let (envelope, _) = try ToolchainCatalogJSON.decode(bytes)
            guard state.evidenceKeys[envelope.signerKeyId] != nil else {
                throw ToolchainTrustError.trustUnavailable
            }
            for entry in envelope.payload.entries {
                if entry.embeddedArtifactPath != nil {
                    publishers.insert(entry.publisher)
                    for item in entry.inventory { if let publisher = item.publisher { publishers.insert(publisher) } }
                    continue
                }
                guard let url = URLComponents(string: entry.downloadURL), url.scheme == "https",
                      let host = url.host else { throw ToolchainTrustError.invalidCatalog }
                origins.insert("https://" + host.lowercased() + (url.port.map { ":\($0)" } ?? ""))
                publishers.insert(entry.publisher)
                for item in entry.inventory { if let publisher = item.publisher { publishers.insert(publisher) } }
            }
        }
        let keys = state.evidenceKeys.isEmpty ? basePolicy.signers.mapValues(\.publicKey) : state.evidenceKeys
        let signers = keys.mapValues { key in
            ToolchainTrustedSigner(publicKey: key, validFrom: .distantPast,
                                   validUntil: .distantFuture, revoked: false)
        }
        let policy = try ToolchainTrustPolicy(signers: signers, channel: basePolicy.channel,
            acceptedSequence: 0, knownHistoricalEnvelopeHashes: [], allowedOrigins: origins,
            approvedPublishers: publishers, installedKitRoot: basePolicy.installedKitRoot)
        let resolver = TrustedToolchainResolver(policy: policy, now: { Date() },
                                                 nativeSignature: nativeSignature)
        var accepted = [(Data, AuthenticatedToolchainCatalog)]()
        for bytes in state.envelopes {
            do { accepted.append((bytes, try resolver.authenticateCatalog(bytes))) }
            catch ToolchainTrustError.conflictingCatalog { continue }
        }
        return EvidenceReplay(resolver: resolver, accepted: accepted)
    }

    private func liveResolver(_ state: State, acceptedHashes: Set<String>) throws -> TrustedToolchainResolver {
        let effectiveSigners = basePolicy.signers.map { key, signer in
            (key, ToolchainTrustedSigner(publicKey: signer.publicKey, validFrom: signer.validFrom,
                validUntil: signer.validUntil,
                revoked: signer.revoked || state.revokedSignerIDs.contains(key)))
        }
        let policy = try ToolchainTrustPolicy(signers: Dictionary(uniqueKeysWithValues: effectiveSigners),
            channel: basePolicy.channel,
            acceptedSequence: max(basePolicy.acceptedSequence, state.highWater),
            knownHistoricalEnvelopeHashes: acceptedHashes.union(basePolicy.knownHistoricalEnvelopeHashes),
            allowedOrigins: basePolicy.allowedOrigins,
            approvedPublishers: basePolicy.approvedPublishers, installedKitRoot: basePolicy.installedKitRoot)
        return TrustedToolchainResolver(policy: policy, now: now, nativeSignature: nativeSignature)
    }

    private func matches(_ requirement: WorkspaceToolchainRequirements.Requirement,
                         _ entry: ToolchainCatalogEntry) -> Bool {
        entry.catalogEntryId == requirement.catalogEntryId && entry.version == requirement.kitVersion &&
        entry.platform == requirement.platform && entry.inventoryHash == requirement.inventoryHash
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        let directory = try ownedDirectory(root)
        defer { close(directory) }
        let lock = openat(directory, "catalog.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o7777 == 0o600,
              flock(lock, LOCK_EX) == 0 else { throw ToolchainTrustError.unsafePath }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(directory)
    }

    private func load(_ directory: Int32) throws -> (State, ToolchainTrustCheckpoint?) {
        let checkpoint = try anchor.read()
        guard let checkpoint else {
            // No slot is ever written before a device-local bootstrap marker exists.
            // A restored file without that marker cannot grant or reset authority.
            for slot in 0...1 {
                var found = stat()
                guard fstatat(directory, "catalog.\(slot)", &found, AT_SYMLINK_NOFOLLOW) != 0,
                      errno == ENOENT else { throw ToolchainTrustError.trustUnavailable }
            }
            return (State(version: 2, highWater: basePolicy.acceptedSequence,
                          envelopes: [], evidenceKeys: [:], revokedSignerIDs: []), nil)
        }
        if checkpoint == .bootstrapping {
            var found = stat()
            guard fstatat(directory, "catalog.1", &found, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw ToolchainTrustError.trustUnavailable }
            if fstatat(directory, "catalog.0", &found, AT_SYMLINK_NOFOLLOW) == 0 {
                let bytes = try readFile(directory, name: "catalog.0", limit: 4096)
                guard let empty = try? JSONDecoder().decode(State.self, from: bytes),
                      empty.version == 2, empty.highWater >= 0,
                      empty.envelopes.isEmpty, empty.evidenceKeys.isEmpty,
                      empty.revokedSignerIDs.isEmpty else { throw ToolchainTrustError.trustUnavailable }
            } else if errno != ENOENT { throw ToolchainTrustError.trustUnavailable }
            return (State(version: 2, highWater: basePolicy.acceptedSequence,
                          envelopes: [], evidenceKeys: [:], revokedSignerIDs: []), checkpoint)
        }
        guard checkpoint.slot == 0 || checkpoint.slot == 1,
              WorkspaceValidation.sha256(checkpoint.sha256) else { throw ToolchainTrustError.trustUnavailable }
        let data = try readFile(directory, name: "catalog.\(checkpoint.slot)", limit: 80 * 1024 * 1024,
                                missingError: .catalogStateMissing)
        guard sha(data) == checkpoint.sha256,
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 2,
              state.highWater >= 0, state.envelopes.count <= 64,
              state.evidenceKeys.count <= 64,
              state.evidenceKeys.allSatisfy({ WorkspaceValidation.id($0.key) && $0.value.count == 32 }),
              state.revokedSignerIDs.isSubset(of: Set(basePolicy.signers.keys).union(state.evidenceKeys.keys)),
              state.envelopes.reduce(0, { $0 + $1.count }) <= 48 * 1024 * 1024 else {
            throw ToolchainTrustError.trustUnavailable
        }
        return (state, checkpoint)
    }

    private func initializedState(_ directory: Int32) throws -> (State, ToolchainTrustCheckpoint) {
        var (state, checkpoint) = try load(directory)
        if checkpoint == nil {
            try anchor.commit(.bootstrapping)
            (state, checkpoint) = try load(directory)
        }
        if let checkpoint, checkpoint != .bootstrapping { return (state, checkpoint) }
        try commit(state, from: .bootstrapping, directory: directory)
        let (anchored, created) = try load(directory)
        guard let created else { throw ToolchainTrustError.trustUnavailable }
        return (anchored, created)
    }

    private func commit(_ state: State, from old: ToolchainTrustCheckpoint?, directory: Int32) throws {
        guard state.envelopes.count <= 64,
              state.envelopes.reduce(0, { $0 + $1.count }) <= 48 * 1024 * 1024 else {
            throw ToolchainTrustError.limitExceeded
        }
        let slot = old == nil || old == .bootstrapping ? 0 : 1 - old!.slot
        let encoded = try JSONEncoder().encode(state)
        let temporary = "catalog.tmp-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { _ = unlinkat(directory, temporary, 0) }
        do {
            try encoded.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw ToolchainTrustError.unsafePath }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw ToolchainTrustError.unsafePath }
        } catch { close(fd); throw error }
        close(fd)
        guard renameat(directory, temporary, directory, "catalog.\(slot)") == 0,
              fsync(directory) == 0 else { throw ToolchainTrustError.unsafePath }
        try anchor.commit(ToolchainTrustCheckpoint(slot: slot, sha256: sha(encoded)))
    }

    private func readFile(_ directory: Int32, name: String, limit: Int,
                          missingError: ToolchainTrustError = .trustUnavailable) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { throw missingError }
        guard fd >= 0 else { throw ToolchainTrustError.trustUnavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o7777 == 0o600,
              info.st_size >= 0, info.st_size <= limit else { throw ToolchainTrustError.trustUnavailable }
        var result = Data(count: Int(info.st_size))
        let count = result.withUnsafeMutableBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard count == result.count else { throw ToolchainTrustError.trustUnavailable }
        return result
    }

    private func ownedDirectory(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ToolchainTrustError.unsafePath }
        for part in path.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw ToolchainTrustError.unsafePath }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o7777 == 0o700 else { close(fd); throw ToolchainTrustError.unsafePath }
        return fd
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
