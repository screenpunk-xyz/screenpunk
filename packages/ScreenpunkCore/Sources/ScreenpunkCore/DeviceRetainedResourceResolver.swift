import Foundation

struct DeviceRetainedGrantReference: Equatable {
    let identity: DeviceGrantRevisionIdentity
    let operationID: UUID
}
struct DeviceRetainedEntryPackageBinding {
    let entryID: UUID
    let reference: DevicePreparedPackageReference
}
struct DeviceRetainedGrantResolutionGroup {
    let reference: DeviceRetainedGrantReference
    let expectedOwner: PairingIdentity
    let packages: [DeviceRetainedEntryPackageBinding]
}
/// Only this resolver constructs evidence from fresh checked package bytes. Not qualification,
/// durability or authority: the stores and final shared gate must still validate persisted evidence.
final class DeviceRetainedGrantPackageEvidence {
    let reference: DeviceRetainedGrantReference
    let owner: PairingIdentity
    let expectations: [DeviceGrantEntryExpectation]
    fileprivate init(_ group: DeviceRetainedGrantResolutionGroup, _ expectations: [DeviceGrantEntryExpectation]) {
        reference=group.reference;owner=group.expectedOwner;self.expectations=expectations
    }
}
/// Private-construction returned live receipts only. No secret input/accessor, execution authority,
/// restart commit request, migration, ownership inference, or physical backend durability assertion.
final class DeviceResolvedRetainedResources {
    let selected: DeviceRetainedGrantReference
    let packageReceipts: [DevicePreparedPackageReceipt]
    let grantReceipts: [DevicePreparedGrantReceipt]
    let packageCheckpoint:DevicePackageResolutionCheckpoint
    let grantCheckpoint:DeviceGrantResolutionCheckpoint
    fileprivate init(selected:DeviceRetainedGrantReference,packages:DevicePackageTerminalResolution,grants:DeviceGrantTerminalResolution) {
        self.selected=selected;packageReceipts=packages.receipts;grantReceipts=grants.receipts
        packageCheckpoint=packages.checkpoint;grantCheckpoint=grants.checkpoint
    }
}
/// Terminal-only effectful resolver. No automatic retry, no orphan adoption, no callbacks/notifications.
/// Full store inventories remain mandatory, even for nonselected retained resources. Package byte
/// preflight is explicitly not acknowledgment; receipts escape only after final shared read verification.
/// Cross-store observations preceding the final gate are non-atomic. Later mutation invalidates live
/// receipts; a future commit overload must reverify and cannot infer private input from public metadata.
final class DeviceRetainedResourceResolver {
    private let packages: DevicePackagePreparationStore
    private let grants: DeviceGrantPreparationStore
    private let gate: DeviceLocalResourceGate
    init(packageStore:DevicePackagePreparationStore,grantStore:DeviceGrantPreparationStore,structuralStore:DeviceStructuralStore) {
        packages=packageStore;grants=grantStore;gate = .init(packageStore:packageStore,grantStore:grantStore,structuralStore:structuralStore)
    }
    func resolveTerminalExact(selected: DeviceRetainedGrantReference,
                              groups: [DeviceRetainedGrantResolutionGroup]) throws -> DeviceResolvedRetainedResources {
        let references = try preflight(selected,groups)
        let observed = try packages.inspectRetainedTerminalExact(references)
        let initial = try evidence(groups,observed)
        // Validate actual selected/latest set, private shape/owner/capabilities BEFORE repair effects.
        try grants.validateRetainedTerminalExact(selected:selected,evidence:initial)
        let packageResolution = try packages.resolveRetainedTerminalExact(references)
        let packageReceipts = packageResolution.receipts
        let refreshed = try packageReceipts.map { try packages.verify($0) }
        let bound = try evidence(groups,refreshed)
        let grantResolution = try grants.resolveRetainedTerminalExact(selected:selected,evidence:bound)
        let grantReceipts = grantResolution.receipts
        return try gate.withReadScope { scope in
            try scope.verifyResolutionCheckpoints(packages:packageResolution.checkpoint,grants:grantResolution.checkpoint)
            let fresh = try packageReceipts.map { try scope.verifyPackage($0) }
            let finalEvidence = try evidence(groups,fresh)
            for group in finalEvidence {
                guard let receipt = grantReceipts.first(where:{$0.operationID == group.reference.operationID && $0.identity == group.reference.identity}) else { throw DeviceGrantPreparationError.conflict }
                _ = try scope.verifyRecoveredGrants(receipt,expectedEntries:group.expectations,expectedOwner:group.owner)
            }
            try scope.verifyResolutionCheckpoints(packages:packageResolution.checkpoint,grants:grantResolution.checkpoint)
            return DeviceResolvedRetainedResources(selected:selected,packages:packageResolution,grants:grantResolution)
        }
    }
    private func preflight(_ selected: DeviceRetainedGrantReference,_ groups:[DeviceRetainedGrantResolutionGroup]) throws -> [DevicePreparedPackageReference] {
        guard (1...2).contains(groups.count), Set(groups.map{$0.reference.operationID}).count == groups.count,
              groups.contains(where:{$0.reference == selected}) else { throw DeviceGrantPreparationError.conflict }
        var references:[DevicePreparedPackageReference]=[],count=0
        for group in groups {
            guard group.reference.identity.rootID == selected.identity.rootID, group.packages.count <= 12,
                  group.expectedOwner.publicKey.count <= PairingLimits.identityByteCount,
                  group.expectedOwner.role == .controller, group.expectedOwner.isWellFormed,
                  Set(group.packages.map(\.entryID)).count == group.packages.count else { throw DeviceGrantPreparationError.conflict }
            count += group.packages.count;guard count <= 24 else { throw DeviceGrantPreparationError.sizeLimit }
            for binding in group.packages {
                let ref=binding.reference
                guard ref.contentID.utf8.count == 64,ref.directory.utf8.count <= 256 else { throw DevicePackagePreparationError.conflict }
                if let previous=references.first(where:{$0.preparationOperationID == ref.preparationOperationID}) {
                    guard exact(previous,ref) else { throw DevicePackagePreparationError.conflict }
                } else { references.append(ref) }
            }
        }
        return references
    }
    private func evidence(_ groups:[DeviceRetainedGrantResolutionGroup],_ observed:[DeviceVerifiedPreparedPackage]) throws -> [DeviceRetainedGrantPackageEvidence] {
        try groups.map { group in
            let expectations = try group.packages.map { binding -> DeviceGrantEntryExpectation in
                guard let package=observed.first(where:{exact($0.reference,binding.reference)}) else { throw DevicePackagePreparationError.conflict }
                return .init(entryID:binding.entryID,package:package.package)
            }
            return .init(group,expectations)
        }
    }
    private func exact(_ a:DevicePreparedPackageReference,_ b:DevicePreparedPackageReference)->Bool {
        a.rootID == b.rootID && a.preparationOperationID == b.preparationOperationID
            && a.contentID.utf8.elementsEqual(b.contentID.utf8) && a.directory.utf8.elementsEqual(b.directory.utf8)
    }
}
