import Foundation

/// Codable values are unvalidated data containers; direct decoding does not validate evidence.
/// Only DeviceStructuralStateReader validates supplied evidence. Neither values nor reader results grant authority.
/// No reader assigns IDs or migrates state.
public struct DeviceStructuralSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generationID: UUID
    public var entries: [DeviceStructuralEntry]
    public var configuredEntryID: UUID?
    public var contentOwner: PairingIdentity?
    /// Existing local set grant reference, not a credential or structural generation.
    public var grantSet: String?
    public init(generationID: UUID, entries: [DeviceStructuralEntry], configuredEntryID: UUID?, contentOwner: PairingIdentity?, grantSet: String?) {
        schemaVersion = 1; self.generationID = generationID; self.entries = entries
        self.configuredEntryID = configuredEntryID; self.contentOwner = contentOwner; self.grantSet = grantSet
    }
}

public struct DeviceStructuralEntry: Codable, Equatable, Sendable {
    public enum Provenance: String, Codable, Sendable { case retainedLocal }
    /// Opaque installation-scoped identity supplied by an approved future writer; not dashboard identity.
    public var entryID: UUID
    public var provenance: Provenance
    public var revision: StoredRevision
    public var displayName: String
    public var packageDirectory: String
    public init(entryID: UUID, displayName: String, revision: StoredRevision, packageDirectory: String) {
        self.displayName = displayName; self.entryID = entryID; provenance = .retainedLocal; self.revision = revision; self.packageDirectory = packageDirectory
    }
}

public enum DeviceStructuralInput: Equatable, Sendable {
    case missing
    case readError
    case bytes(Data)
}
public enum DeviceStructuralBindingExpectation: Equatable, Sendable {
    case unbound
    case bound(generationID: UUID)
}
public struct DeviceStructuralPackageEvidence: Equatable, Sendable {
    public var directory: String
    public var revision: StoredRevision
    public init(directory: String, revision: StoredRevision) { self.directory = directory; self.revision = revision }
}
public struct LegacyContentEvidence: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case orderedSet, singlePackage, empty }
    public let kind: Kind
    public let originalBytes: Data
    public let originalSHA256: String
    public let state: DevicePersistedState
    /// Neither legacy deployed nor displayed selection is promoted to configured selection.
    public var configuredEntryID: UUID? { nil }
}
public enum DeviceStructuralReadFailure: Error, Equatable, Sendable {
    case digestUnavailable, readError, missingBinding, invalidJSON, oversized, unsupportedSchema, invalidState, packageMismatch
}
public enum DeviceStructuralRead: Equatable, Sendable {
    /// No supplied state evidence. Not proof of an empty filesystem or a clean installation.
    case absent
    case legacyUnbound(LegacyContentEvidence)
    case bound(DeviceStructuralSnapshot)
    case blocked(DeviceStructuralReadFailure)
}
