import Foundation

/// Schema 3 inventory retains each resource's original owner and grant revision.
/// These values are supplied associations; only fresh resource verification under
/// the common writer gate can qualify them. No Local secret becomes Cloud-owned.
struct DeviceMixedStructuralState: Equatable, Sendable {
    struct Grant: Codable, Equatable, Sendable {
        let identity: DeviceGrantRevisionIdentity
        let preparationOperationID: UUID
    }
    struct Local: Equatable, Sendable {
        let entry: DeviceStructuralEntry
        let package: DevicePreparedPackageReference
        let grant: Grant
        let owner: PairingIdentity
    }
    enum Entry: Equatable, Sendable {
        case retainedLocal(Local)
        case cloud(DeviceNativeStructuralEntry, Grant)
        var entryID: UUID { switch self { case .retainedLocal(let local): local.entry.entryID; case .cloud(let entry, _): entry.entryID } }
        var dashboardID: String { switch self { case .retainedLocal(let local): local.entry.revision.dashboardId; case .cloud(let entry, _): entry.package.dashboardID.uuidString.lowercased() } }
    }
    let generationID: UUID
    let installationOwner: DeviceNativeInstallationContentOwner
    let entries: [Entry]
    let configuredEntryID: UUID?
    private init(generationID: UUID, installationOwner: DeviceNativeInstallationContentOwner, entries: [Entry], configuredEntryID: UUID?) {
        self.generationID = generationID; self.installationOwner = installationOwner
        self.entries = entries; self.configuredEntryID = configuredEntryID
    }
    static func validating(generationID: UUID, installationOwner: DeviceNativeInstallationContentOwner,
        entries: [Entry], configuredEntryID: UUID?) throws -> Self {
        guard entries.count <= 12, Set(entries.map(\.entryID)).count == entries.count,
              Set(entries.map { Data($0.dashboardID.utf8) }).count == entries.count,
              entries.isEmpty ? configuredEntryID == nil : configuredEntryID.map({ id in entries.contains { $0.entryID == id } }) == true else { throw DeviceNativeStructuralFailure.invalidSchema }
        for entry in entries {
            if case .retainedLocal(let local) = entry {
                guard local.owner.role == .controller, local.owner.isWellFormed,
                      local.entry.provenance == .retainedLocal,
                      local.entry.packageDirectory.utf8.elementsEqual(local.package.directory.utf8),
                      local.package.contentID.utf8.count == 64,
                      local.package.contentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      local.package.directory == "package.staging-cas-v1-" + local.package.contentID,
                      !local.entry.displayName.isEmpty, local.entry.displayName.utf8.count <= 1024 else { throw DeviceNativeStructuralFailure.invalidSchema }
                _ = try DeviceDeliveryCandidateHash.validating(local.entry.revision.digest)
            }
        }
        return .init(generationID: generationID, installationOwner: installationOwner, entries: entries, configuredEntryID: configuredEntryID)
    }
}

/// Exact canonical framing embeds existing independently validated schema-1 Local
/// and schema-2 Cloud resource descriptors. It never normalizes an old descriptor
/// into the other provenance or assigns replacement IDs during restart.
enum DeviceMixedStructuralStateCodec {
    private struct Package: Codable {
        let rootID: UUID, contentID: String, preparationOperationID: UUID, directory: String
        init(_ reference: DevicePreparedPackageReference) { rootID = reference.rootID; contentID = reference.contentID; preparationOperationID = reference.preparationOperationID; directory = reference.directory }
        var reference: DevicePreparedPackageReference { .init(rootID: rootID, contentID: contentID, preparationOperationID: preparationOperationID, directory: directory) }
    }
    private struct Local: Codable {
        let entry: DeviceStructuralEntry
        let package: Package
        let grant: DeviceMixedStructuralState.Grant
        let owner: PairingIdentity
    }
    private struct Entry: Codable {
        let kind: String
        let local: Local?
        let cloudState: Data?
        let cloudGrant: DeviceMixedStructuralState.Grant?
    }
    private struct Frame: Codable {
        let schemaVersion: Int
        let nativeOwnerState: Data
        let entries: [Entry]
        let configuredEntryID: UUID?
    }
    static let maximumBytes = 128 * 1024
    static func encode(_ state: DeviceMixedStructuralState) throws -> Data {
        let owner = try DeviceNativeStructuralState.validating(generationID: state.generationID,
            owner: .nativeInstallation(state.installationOwner), entries: [], configuredEntryID: nil)
        let entries = try state.entries.map { entry -> Entry in
            switch entry {
            case .retainedLocal(let local):
                return .init(kind: "retainedLocal", local: .init(entry: local.entry, package: .init(local.package), grant: local.grant, owner: local.owner), cloudState: nil, cloudGrant: nil)
            case .cloud(let cloud, let grant):
                let single = try DeviceNativeStructuralState.validating(generationID: state.generationID,
                    owner: .nativeInstallation(state.installationOwner), entries: [cloud], configuredEntryID: cloud.entryID)
                return .init(kind: "cloud", local: nil, cloudState: try DeviceNativeStructuralStateCodec.encode(single), cloudGrant: grant)
            }
        }
        return try DeviceLocalCompleteSetBounds.encode(Frame(schemaVersion: 3,
            nativeOwnerState: DeviceNativeStructuralStateCodec.encode(owner), entries: entries,
            configuredEntryID: state.configuredEntryID), maximum: maximumBytes)
    }
    static func decode(_ bytes: Data) throws -> DeviceMixedStructuralState {
        let object = try StructuralStoreCodec.object(bytes, limit: maximumBytes)
        guard let rawEntries = object["entries"] as? [Any], rawEntries.count <= 12 else { throw DeviceNativeStructuralFailure.capacity }
        let frame = try JSONDecoder().decode(Frame.self, from: bytes)
        guard frame.schemaVersion == 3, frame.nativeOwnerState.count <= DeviceNativeStructuralStateCodec.maximumBytes else { throw DeviceNativeStructuralFailure.invalidSchema }
        let owner = try DeviceNativeStructuralStateCodec.decode(frame.nativeOwnerState)
        guard owner.entries.isEmpty, owner.configuredEntryID == nil,
              try DeviceNativeStructuralStateCodec.encode(owner) == frame.nativeOwnerState else { throw DeviceNativeStructuralFailure.invalidSchema }
        let entries = try frame.entries.map { entry -> DeviceMixedStructuralState.Entry in
            switch entry.kind {
            case "retainedLocal":
                guard let local = entry.local, entry.cloudState == nil, entry.cloudGrant == nil else { throw DeviceNativeStructuralFailure.invalidSchema }
                return .retainedLocal(.init(entry: local.entry, package: local.package.reference, grant: local.grant, owner: local.owner))
            case "cloud":
                guard entry.local == nil, let bytes = entry.cloudState, let grant = entry.cloudGrant else { throw DeviceNativeStructuralFailure.invalidSchema }
                let state = try DeviceNativeStructuralStateCodec.decode(bytes)
                guard state.owner == owner.owner, state.generationID == owner.generationID,
                      state.entries.count == 1, state.configuredEntryID == state.entries.first?.entryID,
                      try DeviceNativeStructuralStateCodec.encode(state) == bytes else { throw DeviceNativeStructuralFailure.invalidSchema }
                return .cloud(state.entries[0], grant)
            default: throw DeviceNativeStructuralFailure.invalidSchema
            }
        }
        let state = try DeviceMixedStructuralState.validating(generationID: owner.generationID,
            installationOwner: owner.owner, entries: entries, configuredEntryID: frame.configuredEntryID)
        guard try encode(state) == bytes else { throw DeviceNativeStructuralFailure.invalidSchema }
        return state
    }
}
