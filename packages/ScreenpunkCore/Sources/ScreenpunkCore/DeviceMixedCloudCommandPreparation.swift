import Foundation

/// Original immutable preparation proof. It is neither execution admission nor a
/// durable grant receipt. The common resolver must freshly verify retained stores
/// and stage the incoming grants under its fixed writer gate before committing.
final class DeviceMixedPreparedCloudCommand: GrantSecretRedacted {
    let capture: DeviceMixedInventoryStore.Capture
    let delivery: DeviceNativeDeliveryCommandBinding
    let candidate: DeviceMixedStructuralState
    let packageInputs: [DeviceProvisioningPackageInput]
    let grantInput: DeviceNativeGrantRevisionInput
    let qualifiedGrant: QualifiedDeviceNativeGrantRevision
    let grantOperationID: UUID
    private init(capture: DeviceMixedInventoryStore.Capture, delivery: DeviceNativeDeliveryCommandBinding,
        candidate: DeviceMixedStructuralState, packageInputs: [DeviceProvisioningPackageInput],
        grantInput: DeviceNativeGrantRevisionInput, qualifiedGrant: QualifiedDeviceNativeGrantRevision, grantOperationID: UUID) {
        self.capture = capture; self.delivery = delivery; self.candidate = candidate
        self.packageInputs = packageInputs; self.grantInput = grantInput
        self.qualifiedGrant = qualifiedGrant; self.grantOperationID = grantOperationID
    }
    static func restore(capture: DeviceMixedInventoryStore.Capture, delivery: DeviceNativeDeliveryCommandBinding,
        candidate: DeviceMixedStructuralState, grantIdentity: DeviceGrantRevisionIdentity, grantOperationID: UUID,
        packages: [DeviceVerifiedPreparedPackage]) throws -> DeviceMixedPreparedCloudCommand {
        var inputs: [DeviceProvisioningPackageInput] = [], grantEntries: [DeviceGrantEntryInput] = [], expectations: [DeviceGrantEntryExpectation] = []
        var consumed = Set<UUID>()
        guard candidate.generationID == delivery.desiredGenerationID,
            candidate.installationOwner == capture.snapshot.installationOwner,
            candidate.configuredEntryID == delivery.resultingSet.configuredEntryID,
            candidate.entries.map(\.entryID) == delivery.resultingSet.entries.map(\.entryID) else { throw NativeDeliveryExecutionError.association }
        for entry in candidate.entries {
            guard let desired = delivery.resultingSet.entries.first(where: { $0.entryID == entry.entryID }) else { throw NativeDeliveryExecutionError.association }
            switch (entry, desired.provenance) {
            case (.cloud(let cloud, _), .cloud(let descriptor)):
                guard cloud.package == descriptor else { throw NativeDeliveryExecutionError.association }
            case (.retainedLocal, .retainedLocal):
                guard capture.snapshot.entries.contains(entry) else { throw NativeDeliveryExecutionError.association }
            default: throw NativeDeliveryExecutionError.association
            }
            if capture.snapshot.entries.contains(entry) { continue }
            guard case .cloud(let cloud, let grant) = entry, grant.identity == grantIdentity,
                grant.preparationOperationID == grantOperationID,
                let package = packages.first(where: { $0.reference == cloud.preparedPackage }),
                package.package.manifest.connections.isEmpty, consumed.insert(entry.entryID).inserted,
                cloud.package.manifestDigest.text == package.package.revision.digest else { throw NativeDeliveryExecutionError.association }
            inputs.append(.supplied(entryID: entry.entryID, operationID: package.reference.preparationOperationID, package: package.package))
            grantEntries.append(.init(entryID: entry.entryID, revision: package.package.revision, generic: nil, homeAssistant: nil, publicReads: nil, credentialReferences: []))
            expectations.append(.init(entryID: entry.entryID, package: package.package))
        }
        guard consumed.count == packages.count else { throw NativeDeliveryExecutionError.association }
        let input = DeviceNativeGrantRevisionInput(schemaVersion: 2, identity: grantIdentity,
            owner: candidate.installationOwner, entries: grantEntries, credentials: [], retainedRevisions: [])
        let qualified = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: expectations)
        return .init(capture: capture, delivery: delivery, candidate: candidate, packageInputs: inputs,
            grantInput: input, qualifiedGrant: qualified, grantOperationID: grantOperationID)
    }
    static func prepare(capture: DeviceMixedInventoryStore.Capture, command: Data,
        associationHeader: String, rawPlan: Data, nativeOperationID: UUID, journalRootID: UUID,
        packageRootID: UUID, grantRootID: UUID, grantOperationID: UUID, grantRevisionID: UUID,
        archives: [NativeDeliveryArchiveInput]) throws -> DeviceMixedPreparedCloudCommand {
        guard archives.count <= 12, archives.allSatisfy({ $0.archiveBytes.count <= 25 * 1024 * 1024
            && !$0.revisionName.isEmpty && $0.revisionName.utf8.count <= 1024 && $0.profileID.utf8.count <= 1024 }),
            Set(archives.map(\.entryID)).count == archives.count else { throw NativeDeliveryExecutionError.bounds }
        let delivery = try DeviceNativeDeliveryCommandBinding.bindMixed(command: command,
            associationHeader: associationHeader, rawPlan: rawPlan, nativeOperationID: nativeOperationID,
            journalRootID: journalRootID, capture: capture)
        var entries: [DeviceMixedStructuralState.Entry] = [], inputs: [DeviceProvisioningPackageInput] = []
        var grantEntries: [DeviceGrantEntryInput] = [], expectations: [DeviceGrantEntryExpectation] = [], consumed = Set<UUID>()
        let grantIdentity = DeviceGrantRevisionIdentity(rootID: grantRootID, revisionID: grantRevisionID)
        let grant = DeviceMixedStructuralState.Grant(identity: grantIdentity, preparationOperationID: grantOperationID)
        for desired in delivery.resultingSet.entries {
            let existing = capture.snapshot.entries.first { $0.entryID == desired.entryID }
            switch desired.provenance {
            case .retainedLocal:
                // bindMixed already checked exact local identity and semantic digest.
                guard let existing, case .retainedLocal = existing,
                      !archives.contains(where: { $0.entryID == desired.entryID }) else { throw NativeDeliveryExecutionError.association }
                entries.append(existing)
            case .cloud(let descriptor):
                if let existing, case .cloud(let entry, _) = existing, entry.package == descriptor {
                    guard !archives.contains(where: { $0.entryID == desired.entryID }) else { throw NativeDeliveryExecutionError.association }
                    entries.append(existing); continue
                }
                // Reusing a Local entry ID as Cloud would destroy its origin identity.
                if let existing, case .retainedLocal = existing { throw NativeDeliveryExecutionError.association }
                guard let supplied = archives.first(where: { $0.entryID == desired.entryID }),
                      consumed.insert(desired.entryID).inserted else { throw NativeDeliveryExecutionError.association }
                let expected = DevicePackageExpectation(revision: .init(revision: descriptor.revision.uuidString.lowercased(),
                    dashboardId: descriptor.dashboardID.uuidString.lowercased(), name: supplied.revisionName,
                    digest: descriptor.manifestDigest.text, orientation: supplied.target.orientation,
                    width: supplied.target.width, height: supplied.target.height), target: supplied.target, profileID: supplied.profileID)
                let package = try DeviceNativeArchiveQualifier.qualifyApprovedManifestName(supplied.archiveBytes, descriptor: descriptor, expected: expected).package
                guard package.manifest.connections.isEmpty else { throw NativeDeliveryExecutionError.unsupportedCapabilities }
                let reference = try PackagePreparationCodec.expectedReference(.init(operationID: supplied.preparationOperationID,
                    package: package), rootID: packageRootID)
                inputs.append(.supplied(entryID: desired.entryID, operationID: supplied.preparationOperationID, package: package))
                entries.append(.cloud(try .validating(entryID: desired.entryID, displayName: package.manifest.name,
                    package: descriptor, preparedPackage: reference), grant))
                grantEntries.append(.init(entryID: desired.entryID, revision: package.revision, generic: nil,
                    homeAssistant: nil, publicReads: nil, credentialReferences: []))
                expectations.append(.init(entryID: desired.entryID, package: package))
            }
        }
        guard consumed.count == archives.count else { throw NativeDeliveryExecutionError.association }
        let input = DeviceNativeGrantRevisionInput(schemaVersion: 2, identity: grantIdentity,
            owner: capture.snapshot.installationOwner, entries: grantEntries, credentials: [], retainedRevisions: [])
        let qualified = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: expectations)
        let candidate = try DeviceMixedStructuralState.validating(generationID: delivery.desiredGenerationID,
            installationOwner: capture.snapshot.installationOwner, entries: entries,
            configuredEntryID: delivery.resultingSet.configuredEntryID)
        _ = try DeviceMixedStructuralStateCodec.encode(candidate)
        return .init(capture: capture, delivery: delivery, candidate: candidate, packageInputs: inputs,
            grantInput: input, qualifiedGrant: qualified, grantOperationID: grantOperationID)
    }
}
