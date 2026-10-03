import Foundation
#if os(macOS)

/// Host-only release registration. The caller must supply these values from its
/// independently installed, authenticated distribution; no workspace, RPC,
/// environment variable, or downloaded catalog may set them.
public final class WorkbenchInstalledReleaseTrust {
    public struct Signer {
        public let keyId: String
        public let publicKey: Data
        public let validFrom: Date
        public let validUntil: Date
        public init(keyId: String, publicKey: Data, validFrom: Date, validUntil: Date) {
            self.keyId = keyId; self.publicKey = publicKey
            self.validFrom = validFrom; self.validUntil = validUntil
        }
    }
    public struct Publisher {
        public let teamIdentifier: String
        public let signingIdentifier: String
        public init(teamIdentifier: String, signingIdentifier: String) {
            self.teamIdentifier = teamIdentifier; self.signingIdentifier = signingIdentifier
        }
    }

    let catalog: DurableToolchainCatalogStore
    let installer: ToolchainKitInstaller

    /// A closed diagnostic vocabulary for the host's pre-activation failures.
    /// Never expose arbitrary error descriptions containing paths or secrets.
    public static func preparationFailureReason(_ error: any Error) -> String {
        guard let error = error as? ToolchainTrustError else { return "unavailable" }
        return String(describing: error)
    }

    /// Registration is inert with respect to network access and catalog refresh.
    /// The Keychain checkpoint is consulted only when an explicit catalog read,
    /// acceptance, or install is requested by the host.
    public init(signers: [Signer], channel: String, acceptedSequence: Int,
                knownHistoricalEnvelopeHashes: Set<String>, allowedOrigins: Set<String>,
                approvedPublishers: [Publisher], catalogRoot: String,
                installedKitRoot: String, keychainService: String,
                keychainAccount: String,
                installedReleaseRoot: URL? = nil) throws {
        guard !signers.isEmpty, Set(signers.map(\.keyId)).count == signers.count,
              !keychainService.isEmpty, !keychainAccount.isEmpty,
              keychainService.utf8.count <= 200, keychainAccount.utf8.count <= 200,
              WorkspaceValidation.absolute(catalogRoot),
              WorkspaceValidation.absolute(installedKitRoot),
              catalogRoot != installedKitRoot else {
            throw ToolchainTrustError.trustUnavailable
        }
        let keys = Dictionary(uniqueKeysWithValues: signers.map { signer in
            (signer.keyId, ToolchainTrustedSigner(publicKey: signer.publicKey,
                validFrom: signer.validFrom, validUntil: signer.validUntil,
                revoked: false))
        })
        let publishers = Set(approvedPublishers.map {
            ToolchainPublisher(teamIdentifier: $0.teamIdentifier,
                signingIdentifier: $0.signingIdentifier)
        })
        let policy = try ToolchainTrustPolicy(signers: keys, channel: channel,
            acceptedSequence: acceptedSequence,
            knownHistoricalEnvelopeHashes: knownHistoricalEnvelopeHashes,
            allowedOrigins: allowedOrigins, approvedPublishers: publishers,
            installedKitRoot: installedKitRoot)
        let catalog = try DurableToolchainCatalogStore(root: catalogRoot,
            basePolicy: policy,
            anchor: KeychainToolchainTrustAnchor(service: keychainService,
                account: keychainAccount), now: Date.init,
            nativeSignature: MacOSToolchainSignatureVerifier())
        self.catalog = catalog
        installer = ToolchainKitInstaller(catalog: catalog,
            installedRoot: installedKitRoot,
            fetcher: ToolchainHTTPSArtifactFetcher(),
            bundleSignature: MacOSToolchainHostBundleSignatureVerifier(),
            installedReleaseRoot: installedReleaseRoot)
    }

    /// The envelope is validated against the independently registered release
    /// keys and monotonic local checkpoint before it can authorize an install.
    public func acceptSignedCatalogEnvelope(_ envelope: Data) throws {
        try catalog.accept(envelope)
    }

    /// Bootstrap package-carried kits without a network request. The caller must first
    /// authenticate the complete distribution root; the catalog independently signs
    /// each pin, embedded path, archive hash, inventory, and publisher identity.
    @discardableResult public func importVerifiedOfflineRelease(
        root: URL, signedCatalogEnvelope: Data) throws -> Int {
        let (envelope, _) = try ToolchainCatalogJSON.decode(signedCatalogEnvelope)
        let entries = envelope.payload.entries.filter { $0.kind == "authoringKit" }
        guard !entries.isEmpty, entries.allSatisfy({ $0.embeddedArtifactPath != nil }) else {
            throw ToolchainTrustError.invalidCatalog
        }
        try catalog.restoreMissingExactJournal(from: signedCatalogEnvelope)
        try catalog.accept(signedCatalogEnvelope)
        for entry in entries {
            let pin = WorkspaceToolchainRequirements.Requirement(
                catalogEntryId: entry.catalogEntryId, kitVersion: entry.version,
                platform: entry.platform, inventoryHash: entry.inventoryHash)
            _ = try installer.installOffline(pin, verifiedReleaseRoot: root)
            _ = try installer.installed(pin)
        }
        return entries.count
    }
}
#endif
