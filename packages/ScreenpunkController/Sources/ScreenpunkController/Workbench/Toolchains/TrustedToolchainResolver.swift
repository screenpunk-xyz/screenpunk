import Foundation
import CryptoKit

struct ToolchainTrustedSigner {
    let publicKey: Data
    let validFrom: Date
    let validUntil: Date
    let revoked: Bool
}

/// Constructed only from independently installed release metadata. There is deliberately no
/// public initializer, file loader, environment fallback or bundled production test key.
struct ToolchainTrustPolicy {
    let signers: [String: ToolchainTrustedSigner]
    let channel: String
    let acceptedSequence: Int
    let knownHistoricalEnvelopeHashes: Set<String>
    let allowedOrigins: Set<String>
    let approvedPublishers: Set<ToolchainPublisher>
    let installedKitRoot: String
    init(signers: [String: ToolchainTrustedSigner], channel: String, acceptedSequence: Int,
         knownHistoricalEnvelopeHashes: Set<String>, allowedOrigins: Set<String>,
         approvedPublishers: Set<ToolchainPublisher>, installedKitRoot: String) throws {
        guard !signers.isEmpty, ["stable", "beta"].contains(channel), acceptedSequence >= 0,
              acceptedSequence <= WorkspaceValidation.maxUInt,
              !approvedPublishers.isEmpty,
              WorkspaceValidation.absolute(installedKitRoot),
              signers.keys.allSatisfy(WorkspaceValidation.id),
              signers.values.allSatisfy({ $0.publicKey.count == 32 && $0.validFrom < $0.validUntil }),
              knownHistoricalEnvelopeHashes.allSatisfy(WorkspaceValidation.sha256),
              allowedOrigins.allSatisfy({ origin in
                  guard let url = URLComponents(string: origin) else { return false }
                  return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil &&
                         url.path.isEmpty && url.query == nil && url.fragment == nil
              }) else { throw ToolchainTrustError.trustUnavailable }
        for publisher in approvedPublishers { try publisher.validate() }
        self.signers = signers; self.channel = channel; self.acceptedSequence = acceptedSequence
        self.knownHistoricalEnvelopeHashes = knownHistoricalEnvelopeHashes
        self.allowedOrigins = allowedOrigins; self.approvedPublishers = approvedPublishers
        self.installedKitRoot = installedKitRoot
    }
}

protocol ToolchainExecutableSignatureVerifying {
    /// Check the actual open file's native publisher against both exact identifiers.
    /// A path-only or merely-valid-signature implementation does not satisfy this seam.
    func verify(fd: Int32, path: String, expected: ToolchainPublisher) throws
}

struct UnavailableToolchainSignatureVerifier: ToolchainExecutableSignatureVerifying {
    func verify(fd: Int32, path: String, expected: ToolchainPublisher) throws { throw ToolchainTrustError.publisherUnverified }
}

struct AuthenticatedToolchainCatalog {
    let payload: ToolchainCatalogPayload
    let envelopeHash: String
    let historical: Bool
    fileprivate let payloadHash: String
    fileprivate let authorityID: UUID
    fileprivate init(payload: ToolchainCatalogPayload, envelopeHash: String, historical: Bool,
                     payloadHash: String, authorityID: UUID) {
        self.payload = payload; self.envelopeHash = envelopeHash; self.historical = historical
        self.payloadHash = payloadHash; self.authorityID = authorityID
    }
}

struct ApprovedToolchainKit {
    let entry: ToolchainCatalogEntry
    let catalogId: String
    let catalogSequence: Int
    let catalogEnvelopeHash: String
    fileprivate let catalogPayloadHash: String
    fileprivate let authorityID: UUID
    var directoryName: String { entry.catalogEntryId + "-" + String(entry.inventoryHash.prefix(16)) }
    fileprivate init(entry: ToolchainCatalogEntry, catalog: AuthenticatedToolchainCatalog) {
        self.entry = entry; catalogId = catalog.payload.catalogId
        catalogSequence = catalog.payload.sequence; catalogEnvelopeHash = catalog.envelopeHash
        catalogPayloadHash = catalog.payloadHash; authorityID = catalog.authorityID
    }
}

struct VerifiedToolchainKit {
    let approved: ApprovedToolchainKit
    let includedFiles: Int
    let includedBytes: Int64
    /// Private installation path; a future runner must call verifyForUse and retain its lease
    /// through launch. This result alone is not permission to execute arbitrary URL input.
    let installedPath: String
    let rootIdentity: ToolchainFileIdentity
}

final class TrustedToolchainResolver {
    private struct GenerationKey: Hashable {
        let catalogId: String
        let channel: String
        let sequence: Int
    }
    private struct PinKey: Hashable {
        let catalogEntryId: String
        let version: String
        let platform: String
        let inventoryHash: String
        init(_ entry: ToolchainCatalogEntry) {
            catalogEntryId = entry.catalogEntryId; version = entry.version
            platform = entry.platform; inventoryHash = entry.inventoryHash
        }
    }
    private enum Binding<Value> {
        case accepted(Value)
        case conflicted
    }
    private let authorityID = UUID()
    private let policy: ToolchainTrustPolicy
    private let now: () -> Date
    private let nativeSignature: any ToolchainExecutableSignatureVerifying
    var installationSignatureVerifier: any ToolchainExecutableSignatureVerifying { nativeSignature }
    private let bindingsLock = NSLock()
    private var generations: [GenerationKey: Binding<String>] = [:]
    private var pins: [PinKey: Binding<ToolchainCatalogEntry>] = [:]

    init(policy: ToolchainTrustPolicy, now: @escaping () -> Date,
         nativeSignature: any ToolchainExecutableSignatureVerifying) {
        self.policy = policy; self.now = now; self.nativeSignature = nativeSignature
    }

    /// No production release keys, Team ID or catalog origin have been provisioned yet.
    static func production() throws -> TrustedToolchainResolver { throw ToolchainTrustError.trustUnavailable }

    func authenticateCatalog(_ envelopeBytes: Data) throws -> AuthenticatedToolchainCatalog {
        let (envelope, payloadObject) = try ToolchainCatalogJSON.decode(envelopeBytes)
        guard let signer = policy.signers[envelope.signerKeyId] else { throw ToolchainTrustError.unknownSigner }
        guard !signer.revoked else { throw ToolchainTrustError.revokedSigner }
        let instant = now()
        guard instant >= signer.validFrom, instant < signer.validUntil else { throw ToolchainTrustError.expiredSigner }
        let canonicalPayload = try ToolchainCanonical.encode(payloadObject)
        var message = Data("screenpunk/release-catalog/v1".utf8)
        message.append(0)
        message.append(canonicalPayload)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKey),
              let signature = Data(base64Encoded: envelope.signatureBase64),
              key.isValidSignature(signature, for: message) else { throw ToolchainTrustError.signatureInvalid }
        let digest = SHA256.hash(data: envelopeBytes).map { String(format: "%02x", $0) }.joined()
        guard envelope.payload.channel == policy.channel else { throw ToolchainTrustError.staleCatalog }
        let historical = envelope.payload.sequence < policy.acceptedSequence
        guard !historical || policy.knownHistoricalEnvelopeHashes.contains(digest) else {
            throw ToolchainTrustError.staleCatalog
        }
        for entry in envelope.payload.entries {
            guard policy.approvedPublishers.contains(entry.publisher),
                  entry.inventory.allSatisfy({ $0.publisher.map(policy.approvedPublishers.contains) ?? true }) else {
                throw ToolchainTrustError.unknownPublisher
            }
            if entry.embeddedArtifactPath != nil { continue }
            guard let url = URLComponents(string: entry.downloadURL), url.scheme == "https",
                  let host = url.host, url.user == nil, url.password == nil, url.fragment == nil else {
                throw ToolchainTrustError.invalidCatalog
            }
            let origin = "https://" + host.lowercased() + (url.port.map { ":\($0)" } ?? "")
            guard policy.allowedOrigins.contains(origin) else { throw ToolchainTrustError.invalidCatalog }
        }
        let payloadHash = SHA256.hash(data: canonicalPayload).map { String(format: "%02x", $0) }.joined()
        let generation = GenerationKey(catalogId: envelope.payload.catalogId,
                                       channel: envelope.payload.channel, sequence: envelope.payload.sequence)
        bindingsLock.lock()
        defer { bindingsLock.unlock() }
        if let binding = generations[generation] {
            switch binding {
            case .conflicted: throw ToolchainTrustError.conflictingCatalog
            case .accepted(let earlier) where earlier != payloadHash:
                generations[generation] = .conflicted
                for entry in envelope.payload.entries {
                    let pin = PinKey(entry)
                    if case .accepted(let known)? = pins[pin], known != entry { pins[pin] = .conflicted }
                }
                throw ToolchainTrustError.conflictingCatalog
            case .accepted: break
            }
        }
        var conflictingPins = [PinKey]()
        for entry in envelope.payload.entries {
            let pin = PinKey(entry)
            if let binding = pins[pin] {
                switch binding {
                case .conflicted: conflictingPins.append(pin)
                case .accepted(let earlier) where earlier != entry: conflictingPins.append(pin)
                case .accepted: break
                }
            }
        }
        if !conflictingPins.isEmpty {
            generations[generation] = .conflicted
            for pin in conflictingPins { pins[pin] = .conflicted }
            throw ToolchainTrustError.conflictingCatalog
        }
        generations[generation] = .accepted(payloadHash)
        for entry in envelope.payload.entries { pins[PinKey(entry)] = .accepted(entry) }
        return AuthenticatedToolchainCatalog(payload: envelope.payload, envelopeHash: digest,
                                             historical: historical, payloadHash: payloadHash,
                                             authorityID: authorityID)
    }

    func resolve(_ requirement: WorkspaceToolchainRequirements.Requirement,
                 catalogs: [AuthenticatedToolchainCatalog]) throws -> ApprovedToolchainKit {
        guard WorkspaceValidation.id(requirement.catalogEntryId), WorkspaceValidation.id(requirement.kitVersion),
              requirement.platform == "darwin-arm64", WorkspaceValidation.sha256(requirement.inventoryHash) else {
            throw ToolchainTrustError.requirementMismatch
        }
        bindingsLock.lock()
        defer { bindingsLock.unlock() }
        var sawIdentifier = false
        var matches = [(AuthenticatedToolchainCatalog, ToolchainCatalogEntry)]()
        for catalog in catalogs {
            guard catalog.authorityID == authorityID else { throw ToolchainTrustError.trustUnavailable }
            try assertTrusted(catalog)
            for entry in catalog.payload.entries where entry.catalogEntryId == requirement.catalogEntryId {
                sawIdentifier = true
                guard entry.kind == "authoringKit", entry.version == requirement.kitVersion,
                      entry.platform == requirement.platform, entry.inventoryHash == requirement.inventoryHash else { continue }
                matches.append((catalog, entry))
            }
        }
        guard let first = matches.first else {
            throw sawIdentifier ? ToolchainTrustError.requirementMismatch : ToolchainTrustError.unknownKit
        }
        guard matches.allSatisfy({ $0.1 == first.1 }) else { throw ToolchainTrustError.conflictingCatalog }
        let selected = matches.min {
            let left = ($0.0.payload.catalogId, $0.0.payload.sequence, $0.0.envelopeHash)
            let right = ($1.0.payload.catalogId, $1.0.payload.sequence, $1.0.envelopeHash)
            return left < right
        }!
        return ApprovedToolchainKit(entry: selected.1, catalog: selected.0)
    }

    /// Call only while bindingsLock is held.
    private func assertTrusted(_ catalog: AuthenticatedToolchainCatalog) throws {
        let key = GenerationKey(catalogId: catalog.payload.catalogId,
                                channel: catalog.payload.channel, sequence: catalog.payload.sequence)
        guard case .accepted(let digest)? = generations[key], digest == catalog.payloadHash else {
            throw ToolchainTrustError.conflictingCatalog
        }
        for entry in catalog.payload.entries {
            guard case .accepted(let known)? = pins[PinKey(entry)], known == entry else {
                throw ToolchainTrustError.conflictingCatalog
            }
        }
    }

    private func assertTrusted(_ approved: ApprovedToolchainKit) throws {
        bindingsLock.lock(); defer { bindingsLock.unlock() }
        let key = GenerationKey(catalogId: approved.catalogId,
                                channel: policy.channel, sequence: approved.catalogSequence)
        guard case .accepted(let digest)? = generations[key], digest == approved.catalogPayloadHash,
              case .accepted(let entry)? = pins[PinKey(approved.entry)], entry == approved.entry else {
            throw ToolchainTrustError.conflictingCatalog
        }
    }

    /// Validates only a catalog-derived name under the independently configured local kit root.
    func verifyInstalled(_ approved: ApprovedToolchainKit) throws -> VerifiedToolchainKit {
        guard approved.authorityID == authorityID else { throw ToolchainTrustError.trustUnavailable }
        try assertTrusted(approved)
        let installation = try WorkspaceFiles(path: policy.installedKitRoot)
        let path = policy.installedKitRoot + "/" + approved.directoryName
        let verified = try ToolchainKitVerifier(signature: nativeSignature).verify(root: path, approved: approved)
        try installation.verifyRoot()
        try assertTrusted(approved)
        return verified
    }

    /// Recheck all bytes and native signatures immediately before a future launch adapter uses
    /// the owned stage. That adapter must preserve the validated stage through process startup.
    func verifyForUse(_ kit: VerifiedToolchainKit) throws -> VerifiedToolchainKit {
        guard kit.installedPath == policy.installedKitRoot + "/" + kit.approved.directoryName else {
            throw ToolchainTrustError.unsafePath
        }
        let fresh = try verifyInstalled(kit.approved)
        guard fresh.rootIdentity == kit.rootIdentity else { throw ToolchainTrustError.inventoryMismatch }
        return fresh
    }

    func verifyArtifact(at path: String, for approved: ApprovedToolchainKit) throws {
        guard approved.authorityID == authorityID else { throw ToolchainTrustError.trustUnavailable }
        try assertTrusted(approved)
        try ToolchainKitVerifier(signature: nativeSignature).verifyArtifact(path: path, approved: approved)
        try assertTrusted(approved)
    }
}
