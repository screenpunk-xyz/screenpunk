import Foundation

/// Additive schema 2, currently Cloud-only. Not a delivery command, approval,
/// resource receipt, durability proof or migration of schema 1 Local state.
struct DeviceNativeStructuralState: Equatable, Sendable {
    static let schemaVersion = 2
    static let maximumEntries = 12
    let generationID: UUID
    let owner: DeviceNativeInstallationContentOwner
    let entries: [DeviceNativeStructuralEntry]
    let configuredEntryID: UUID?
    private init(generationID: UUID, owner: DeviceNativeInstallationContentOwner,
                 entries: [DeviceNativeStructuralEntry], configuredEntryID: UUID?) {
        self.generationID = generationID; self.owner = owner
        self.entries = entries; self.configuredEntryID = configuredEntryID
    }
    static func validating(generationID: UUID, owner: DeviceNativeContentOwner,
                           entries: [DeviceNativeStructuralEntry], configuredEntryID: UUID?) throws -> Self {
        guard entries.count <= maximumEntries else { throw DeviceNativeStructuralFailure.capacity }
        guard case .nativeInstallation(let installation) = owner else { throw DeviceNativeStructuralFailure.invalidSchema }
        var ids = Set<UUID>(), dashboards = Set<UUID>()
        for entry in entries {
            guard ids.insert(entry.entryID).inserted,
                  dashboards.insert(entry.package.dashboardID).inserted else { throw DeviceNativeStructuralFailure.invalidSchema }
        }
        guard entries.isEmpty ? configuredEntryID == nil : configuredEntryID.map({ ids.contains($0) }) == true else {
            throw DeviceNativeStructuralFailure.invalidSchema
        }
        let result = Self(generationID: generationID, owner: installation, entries: entries, configuredEntryID: configuredEntryID)
        // Typed inputs are bounded individually before the aggregate encoding.
        _ = try DeviceNativeStructuralStateCodec.encode(result)
        return result
    }
}

/// Original Cloud descriptor identities and prepared identity remain independent.
/// Supplied prepared metadata is not proof that a package exists or is durable.
struct DeviceNativeStructuralEntry: Equatable, Sendable {
    let entryID: UUID
    let displayName: String
    let package: DeviceDeliveryPackageCandidate
    let preparedPackage: DevicePreparedPackageReference
    private init(entryID: UUID, displayName: String, package: DeviceDeliveryPackageCandidate,
                 preparedPackage: DevicePreparedPackageReference) {
        self.entryID = entryID; self.displayName = displayName
        self.package = package; self.preparedPackage = preparedPackage
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entryID == rhs.entryID && lhs.displayName.utf8.elementsEqual(rhs.displayName.utf8)
            && lhs.package == rhs.package && lhs.preparedPackage == rhs.preparedPackage
    }
    static func validating(entryID: UUID, displayName: String, package: DeviceDeliveryPackageCandidate,
                           preparedPackage: DevicePreparedPackageReference) throws -> Self {
        guard !displayName.isEmpty, displayName.utf8.prefix(1025).count <= 1024 else { throw DeviceNativeStructuralFailure.capacity }
        let content = Array(preparedPackage.contentID.utf8.prefix(65))
        guard content.count == 64, content.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              preparedPackage.directory.utf8.elementsEqual(("package.staging-cas-v1-" + preparedPackage.contentID).utf8) else {
            throw DeviceNativeStructuralFailure.invalidSchema
        }
        return Self(entryID: entryID, displayName: displayName, package: package, preparedPackage: preparedPackage)
    }
}
enum DeviceNativeStructuralFailure: Error, Equatable { case capacity, invalidJSON, duplicateKey, invalidSchema }
