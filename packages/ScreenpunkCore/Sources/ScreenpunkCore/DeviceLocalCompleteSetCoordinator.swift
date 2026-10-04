import Foundation

/// NON-ATOMIC sequential observations only. No admission, commit, execution or authority capability.
/// Resources can change after any verify. Receipt verification must be repeated under a future common
/// all-writer gate before admission. This value never calls the structural store or publishes an outcome.
final class DeviceLocalCompleteSetObservation {
    let references: DeviceLocalCompleteSetReferences
    let expectedOldEnvelopeBytes: Data?
    let candidateEnvelopeBytes: Data
    let observedSnapshot: DeviceStructuralSnapshot
    fileprivate init(references: DeviceLocalCompleteSetReferences, old: Data?, candidate: Data, snapshot: DeviceStructuralSnapshot) {
        self.references = references; expectedOldEnvelopeBytes = old; candidateEnvelopeBytes = candidate; observedSnapshot = snapshot
    }
}


/// Unmounted read-only join. Concrete stores are verified sequentially, without a common admission gate.
/// No callbacks, structural store writes, filesystem initialization, migration or runtime activation.
final class DeviceLocalCompleteSetCoordinator {
    private let packageStore: DevicePackagePreparationStore
    private let grantStore: DeviceGrantPreparationStore
    init(packageStore: DevicePackagePreparationStore, grantStore: DeviceGrantPreparationStore) {
        self.packageStore = packageStore; self.grantStore = grantStore
    }
    func observeSequentially(_ request: DeviceLocalCompleteSetRequest) throws -> DeviceLocalCompleteSetObservation {
        try observe(request,verifyPackage:{try self.packageStore.verify($0)},
                    verifyGrants:{try self.grantStore.verify($0,exactRequest:$1,expectedEntries:$2)})
    }
    /// Candidate construction under a held gate is still not itself an acknowledgment.
    func observeUnderGate(_ request: DeviceLocalCompleteSetRequest, scope: DeviceLocalResourceReadScope) throws -> DeviceLocalCompleteSetObservation {
        try observe(request,verifyPackage:{try scope.verifyPackage($0)},
                    verifyGrants:{try scope.verifyGrants($0,exactRequest:$1,expectedEntries:$2)})
    }
    private func observe(_ request: DeviceLocalCompleteSetRequest,
        verifyPackage: (DevicePreparedPackageReceipt) throws -> DeviceVerifiedPreparedPackage,
        verifyGrants: (DevicePreparedGrantReceipt,DeviceGrantPreparationRequest,[DeviceGrantEntryExpectation]) throws -> DeviceVerifiedGrantPreparation) throws -> DeviceLocalCompleteSetObservation {
        try DeviceLocalCompleteSetBounds.preflight(request)
        let snapshot = request.snapshot
        guard snapshot.schemaVersion == 1, request.expectedGenerationID != snapshot.generationID,
              snapshot.entries.count == request.packages.count,
              Set(snapshot.entries.map(\.entryID)).count == snapshot.entries.count,
              Set(request.packages.map(\.entryID)).count == request.packages.count,
              snapshot.entries.isEmpty ? snapshot.configuredEntryID == nil : snapshot.entries.contains(where:{$0.entryID == snapshot.configuredEntryID}) else { throw DeviceLocalCompleteSetFailure.invalidInput }
        guard request.owner.role == .controller, request.owner.isWellFormed,
              let owner = snapshot.contentOwner, exactOwner(owner,request.owner),
              exactOwner(request.grantRequest.input.owner,request.owner) else { throw DeviceLocalCompleteSetFailure.ownerMismatch }
        let old: Data?
        switch request.baseline {
        case .initialExplicit(let legacy):
            guard request.expectedGenerationID == nil, exactOptional(legacy,snapshot.grantSet) else { throw DeviceLocalCompleteSetFailure.baselineMismatch }; old = nil
        case .expectedEnvelope(let bytes):
            let prior = try StructuralStoreCodec.envelope(bytes)
            guard prior.snapshot.generationID == request.expectedGenerationID, prior.operationID != request.operationID,
                  exactOptional(prior.snapshot.grantSet,snapshot.grantSet) else { throw DeviceLocalCompleteSetFailure.baselineMismatch }; old = bytes
        }
        var expectations: [DeviceGrantEntryExpectation] = [], packages: [DeviceLocalCompleteSetReferences.Package] = []
        for entry in snapshot.entries {
            guard let binding = request.packages.first(where:{$0.entryID == entry.entryID}), entry.provenance == .retainedLocal else { throw DeviceLocalCompleteSetFailure.packageMismatch }
            let observed = try verifyPackage(binding.receipt)
            guard entry.packageDirectory.utf8.elementsEqual(observed.reference.directory.utf8),
                  try DeviceLocalCompleteSetBounds.encode(entry.revision,maximum:8192) == DeviceLocalCompleteSetBounds.encode(observed.package.revision,maximum:8192) else { throw DeviceLocalCompleteSetFailure.packageMismatch }
            expectations.append(.init(entryID:entry.entryID,package:observed.package))
            packages.append(.init(entryID:entry.entryID,rootID:observed.reference.rootID,contentID:observed.reference.contentID,
                preparationOperationID:observed.reference.preparationOperationID,directory:observed.reference.directory))
        }
        let grants = try verifyGrants(request.grantReceipt,request.grantRequest,expectations)
        let references = DeviceLocalCompleteSetReferences(schemaVersion:1,structuralRootID:request.structuralRootID,
            operationID:request.operationID,generationID:snapshot.generationID,packages:packages,
            grants:.init(identity:grants.identity,preparationOperationID:request.grantReceipt.operationID))
        let intent = try DeviceLocalCompleteSetBounds.encode(references,maximum:DeviceLocalCompleteSetBounds.intentLimit)
        // Candidate outcome bytes describe the exact proposed set; they are NOT a returned committed result.
        let outcome = try DeviceLocalCompleteSetBounds.encode(references,maximum:DeviceLocalCompleteSetBounds.outcomeLimit)
        let envelope = DeviceStructuralCommitEnvelope(operationID:request.operationID,expectedGenerationID:request.expectedGenerationID,
            snapshot:snapshot,intent:intent,outcome:outcome)
        let candidate = try DeviceLocalCompleteSetBounds.encode(envelope,maximum:DeviceLocalCompleteSetBounds.envelopeLimit)
        _ = try StructuralStoreCodec.envelope(candidate)
        return DeviceLocalCompleteSetObservation(references:references,old:old,candidate:candidate,snapshot:snapshot)
    }
    private func exactOwner(_ first: PairingIdentity, _ second: PairingIdentity) -> Bool {
        first.role == .controller && second.role == .controller && first.isWellFormed && second.isWellFormed && first.publicKey == second.publicKey
    }
    private func exactOptional(_ first: String?, _ second: String?) -> Bool {
        switch (first,second) { case (nil,nil): return true; case (.some(let a),.some(let b)): return a.utf8.elementsEqual(b.utf8); default:return false }
    }
}
