import Foundation

/// Unmounted typed byte-profile inputs only. No raw wire decoder, durable Codable
/// schema, retained-resource proof, generation admission or installation authority.
enum DeviceDeliveryCandidateFailure: Error, Equatable {
    case invalidHash, invalidPackage, invalidEntries, invalidSelection, sizeLimit, digestUnavailable
}

struct DeviceDeliveryCandidateHash: Equatable, Sendable {
    let text: String
    private init(_ text: String) { self.text = text }
    static func validating(_ text: String) throws -> Self {
        let bytes = Array(text.utf8.prefix(65))
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DeviceDeliveryCandidateFailure.invalidHash
        }
        return .init(text)
    }
}

struct DeviceDeliveryPackageCandidate: Equatable, Sendable {
    static let profile = "screenpunk-native-manifest-v1"
    static let maximumCompressedBytes: UInt64 = 25 * 1024 * 1024
    static let maximumExpandedBytes: UInt64 = 50 * 1024 * 1024
    static let maximumArchiveEntries: UInt64 = 2000
    let publicationID: UUID, projectID: UUID, packageID: UUID, dashboardID: UUID, revision: UUID
    let manifestDigest: DeviceDeliveryCandidateHash
    let manifestSHA256: DeviceDeliveryCandidateHash
    let archiveSHA256: DeviceDeliveryCandidateHash
    let compressedBytes: UInt64, expandedBytes: UInt64, archiveEntries: UInt64
    private init(publicationID: UUID, projectID: UUID, packageID: UUID, dashboardID: UUID, revision: UUID,
        manifestDigest: DeviceDeliveryCandidateHash, manifestSHA256: DeviceDeliveryCandidateHash,
        archiveSHA256: DeviceDeliveryCandidateHash, compressedBytes: UInt64, expandedBytes: UInt64, archiveEntries: UInt64) {
        self.publicationID = publicationID; self.projectID = projectID; self.packageID = packageID
        self.dashboardID = dashboardID; self.revision = revision; self.manifestDigest = manifestDigest
        self.manifestSHA256 = manifestSHA256; self.archiveSHA256 = archiveSHA256
        self.compressedBytes = compressedBytes; self.expandedBytes = expandedBytes; self.archiveEntries = archiveEntries
    }
    static func validating(packageProfile: String, publicationID: UUID, projectID: UUID, packageID: UUID,
        dashboardID: UUID, revision: UUID, manifestDigest: DeviceDeliveryCandidateHash,
        manifestSHA256: DeviceDeliveryCandidateHash, archiveSHA256: DeviceDeliveryCandidateHash,
        compressedBytes: UInt64, expandedBytes: UInt64, archiveEntries: UInt64) throws -> Self {
        guard packageProfile.utf8.prefix(30).elementsEqual(profile.utf8),
            (1...maximumCompressedBytes).contains(compressedBytes),
            (1...maximumExpandedBytes).contains(expandedBytes),
            (1...maximumArchiveEntries).contains(archiveEntries) else { throw DeviceDeliveryCandidateFailure.invalidPackage }
        return .init(publicationID: publicationID, projectID: projectID, packageID: packageID,
            dashboardID: dashboardID, revision: revision, manifestDigest: manifestDigest,
            manifestSHA256: manifestSHA256, archiveSHA256: archiveSHA256,
            compressedBytes: compressedBytes, expandedBytes: expandedBytes, archiveEntries: archiveEntries)
    }
}

enum DeviceDeliveryEntryProvenanceCandidate: Equatable, Sendable {
    case cloud(DeviceDeliveryPackageCandidate)
    /// Opaque vocabulary only: never a token-to-entry mapping or resolver proof.
    case retainedLocal(retainedEntryID: UUID, manifestDigest: DeviceDeliveryCandidateHash)
}
struct DeviceDeliveryEntryCandidate: Equatable, Sendable {
    let entryID: UUID
    let provenance: DeviceDeliveryEntryProvenanceCandidate
    private init(entryID: UUID, provenance: DeviceDeliveryEntryProvenanceCandidate) {
        self.entryID = entryID; self.provenance = provenance
    }
    static func validating(entryID: UUID, provenance: DeviceDeliveryEntryProvenanceCandidate) -> Self {
        .init(entryID: entryID, provenance: provenance)
    }
}

struct DeviceResultingSetCandidate: Equatable, Sendable {
    static let maximumEntries = 12
    let entries: [DeviceDeliveryEntryCandidate]
    let configuredEntryID: UUID?
    private init(entries: [DeviceDeliveryEntryCandidate], configuredEntryID: UUID?) {
        self.entries = entries; self.configuredEntryID = configuredEntryID
    }
    static func validating(entries: [DeviceDeliveryEntryCandidate], configuredEntryID: UUID?) throws -> Self {
        guard entries.count <= maximumEntries else { throw DeviceDeliveryCandidateFailure.sizeLimit }
        var ids = Set<UUID>(), dashboards = Set<UUID>()
        for entry in entries {
            guard ids.insert(entry.entryID).inserted else { throw DeviceDeliveryCandidateFailure.invalidEntries }
            if case .cloud(let package) = entry.provenance {
                guard dashboards.insert(package.dashboardID).inserted else { throw DeviceDeliveryCandidateFailure.invalidEntries }
            }
        }
        guard entries.isEmpty ? configuredEntryID == nil : configuredEntryID.map({ ids.contains($0) }) == true else {
            throw DeviceDeliveryCandidateFailure.invalidSelection
        }
        // Retained dashboard identity/availability require a future fresh resolver.
        return .init(entries: entries, configuredEntryID: configuredEntryID)
    }
}

struct DeviceDeliveryObservationCandidate: Equatable, Sendable {
    let installationID: UUID, transitionID: UUID, generationID: UUID
    let resultingSet: DeviceResultingSetCandidate
    private init(installationID: UUID, transitionID: UUID, generationID: UUID, resultingSet: DeviceResultingSetCandidate) {
        self.installationID = installationID; self.transitionID = transitionID
        self.generationID = generationID; self.resultingSet = resultingSet
    }
    static func validating(installationID: UUID, transitionID: UUID, generationID: UUID,
        entries: [DeviceDeliveryEntryCandidate], configuredEntryID: UUID?) throws -> Self {
        .init(installationID: installationID, transitionID: transitionID, generationID: generationID,
            resultingSet: try .validating(entries: entries, configuredEntryID: configuredEntryID))
    }
}
