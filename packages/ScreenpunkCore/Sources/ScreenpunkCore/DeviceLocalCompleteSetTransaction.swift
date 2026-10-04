import Foundation

/// Supplied baseline evidence only, not a current-store read or legacy migration decision.
enum DeviceLocalCompleteSetBaseline {
    case initialExplicit(legacyGrantSet: String?)
    case expectedEnvelope(Data)
}
struct DeviceLocalCompleteSetPackageBinding {
    let entryID: UUID
    let receipt: DevicePreparedPackageReceipt
}
/// No IDs, selection, owner or legacy grantSet are inferred. Preparation operations have their own IDs.
struct DeviceLocalCompleteSetRequest: GrantSecretRedacted {
    let structuralRootID: UUID
    let operationID: UUID
    let expectedGenerationID: UUID?
    let baseline: DeviceLocalCompleteSetBaseline
    let snapshot: DeviceStructuralSnapshot
    let packages: [DeviceLocalCompleteSetPackageBinding]
    let grantReceipt: DevicePreparedGrantReceipt
    let grantRequest: DeviceGrantPreparationRequest
    let owner: PairingIdentity
}
/// Nonsecret caller-supplied candidate. Resolver checkpoints remain in the opaque bundle and are
/// never reconstructed from these references. Latest-only resources are not selected implicitly.
struct DeviceLocalCompleteSetRecoveredRequest {
    let structuralRootID: UUID
    let operationID: UUID
    let expectedGenerationID: UUID?
    let baseline: DeviceLocalCompleteSetBaseline
    let snapshot: DeviceStructuralSnapshot
    let packages: [DeviceRetainedEntryPackageBinding]
    let owner: PairingIdentity
}
enum DeviceLocalCompleteSetFailure: Error, Equatable {
    case sizeLimit, invalidInput, baselineMismatch, packageMismatch, ownerMismatch
}
/// Versioned nonsecret references. Decoding/possession never substitutes for receipt verification.
struct DeviceLocalCompleteSetReferences: Codable, Equatable {
    struct Package: Codable, Equatable {
        let entryID: UUID
        let rootID: UUID
        let contentID: String
        let preparationOperationID: UUID
        let directory: String
    }
    struct Grants: Codable, Equatable {
        let identity: DeviceGrantRevisionIdentity
        let preparationOperationID: UUID
    }
    let schemaVersion: Int
    let structuralRootID: UUID
    let operationID: UUID
    let generationID: UUID
    let packages: [Package]
    let grants: Grants
}
/// Schema-local conservative expansion, bounded BEFORE encoding or constructing copied inventories.
/// Actual encoding is also checked. Limits are fail-closed, never truncation. No private grant bytes or
/// public grant metadata are embedded in intent/outcome. Legacy grantSet remains a distinct opaque field.
enum DeviceLocalCompleteSetBounds {
    static let intentLimit = 32 * 1024
    static let outcomeLimit = 32 * 1024
    static let envelopeLimit = 128 * 1024
    static func string(_ value: String) throws -> Int {
        guard !value.isEmpty, value.utf8.count <= 256, !value.unicodeScalars.contains(where:{$0.value < 32}) else { throw DeviceLocalCompleteSetFailure.sizeLimit }
        return 2 + 6 * value.utf8.count
    }
    static func preflight(_ request: DeviceLocalCompleteSetRequest) throws {
        guard request.packages.count <= 12, request.snapshot.entries.count <= 12 else { throw DeviceLocalCompleteSetFailure.sizeLimit }
        try preflight(snapshot:request.snapshot,baseline:request.baseline,owner:request.owner,
                      references:request.packages.map { $0.receipt.reference },count:request.packages.count)
    }
    static func preflight(_ request: DeviceLocalCompleteSetRecoveredRequest, resources: DeviceResolvedRetainedResources) throws {
        // Check all inventory counts before any maps/copies, including latest-only bundle resources.
        guard request.packages.count <= 12, request.snapshot.entries.count <= 12, resources.packageReceipts.count <= 24,
              (1...2).contains(resources.grantReceipts.count) else { throw DeviceLocalCompleteSetFailure.sizeLimit }
        try preflight(snapshot:request.snapshot,baseline:request.baseline,owner:request.owner,
                      references:request.packages.map(\.reference),count:request.packages.count)
        for receipt in resources.packageReceipts { _ = try string(receipt.reference.directory); _ = try string(receipt.reference.contentID) }
    }
    private static func preflight(snapshot:DeviceStructuralSnapshot,baseline:DeviceLocalCompleteSetBaseline,
                                  owner:PairingIdentity,references:[DevicePreparedPackageReference],count:Int) throws {
        guard snapshot.entries.count <= 12, count <= 12,
              owner.publicKey.count <= PairingLimits.identityByteCount else { throw DeviceLocalCompleteSetFailure.sizeLimit }
        if case .expectedEnvelope(let bytes) = baseline, bytes.count > envelopeLimit { throw DeviceLocalCompleteSetFailure.sizeLimit }
        var snapshotBudget = 2048, referenceBudget = 1024
        for entry in snapshot.entries {
            for field in [entry.displayName,entry.packageDirectory,entry.revision.dashboardId,entry.revision.revision,entry.revision.name,entry.revision.digest] { snapshotBudget += try string(field) }
            snapshotBudget += 512
        }
        if let grantSet = snapshot.grantSet { snapshotBudget += try string(grantSet) }
        for reference in references {
            referenceBudget += 512 + (try string(reference.directory)) + (try string(reference.contentID))
        }
        if case .initialExplicit(let legacy) = baseline, let legacy { _ = try string(legacy) }
        guard snapshotBudget <= 64 * 1024, referenceBudget <= intentLimit, referenceBudget <= outcomeLimit,
              snapshotBudget + 2 * (((referenceBudget + 2) / 3) * 4) + 1024 <= envelopeLimit else { throw DeviceLocalCompleteSetFailure.sizeLimit }
    }
    static func encode<T: Encodable>(_ value: T, maximum: Int) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximum else { throw DeviceLocalCompleteSetFailure.sizeLimit }; return bytes
    }
}

/// Strict local interpretation of an already committed candidate, never legacy conversion or approval.
/// All bytes are bounded before decoding. Canonical equality rejects normalized aliases and alternate
/// encodings instead of silently reconstructing a different exact operation.
enum DeviceLocalCompleteSetRestoreCodec {
    struct Candidate {
        let request:DeviceLocalCompleteSetRecoveredRequest
        let selected:DeviceRetainedGrantResolutionGroup
    }
    static func candidate(_ supplied:DeviceStructuralOperationRecord)throws->Candidate {
        guard supplied.candidate.count <= DeviceLocalCompleteSetBounds.envelopeLimit,
              (supplied.expectedOld?.count ?? 0) <= DeviceLocalCompleteSetBounds.envelopeLimit,
              supplied.phase == .terminal,supplied.resourceAssertions.isEmpty else { throw DeviceLocalCompleteSetFailure.invalidInput }
        let record=try StructuralStoreCodec.record(StructuralStoreCodec.encode(supplied))
        let envelope=try StructuralStoreCodec.envelope(record.candidate)
        let references=try references(envelope.intent)
        guard envelope.outcome == envelope.intent,
              try DeviceLocalCompleteSetBounds.encode(references,maximum:DeviceLocalCompleteSetBounds.intentLimit) == envelope.intent,
              try DeviceLocalCompleteSetBounds.encode(envelope,maximum:DeviceLocalCompleteSetBounds.envelopeLimit) == record.candidate,
              references.structuralRootID == record.rootID,references.operationID == record.operationID,
              references.operationID == envelope.operationID,references.generationID == envelope.snapshot.generationID,
              references.packages.count == envelope.snapshot.entries.count,
              let owner=envelope.snapshot.contentOwner,owner.role == .controller,owner.isWellFormed,
              owner.publicKey.count <= PairingLimits.identityByteCount else { throw DeviceLocalCompleteSetFailure.invalidInput }
        for (entry,reference) in zip(envelope.snapshot.entries,references.packages) {
            guard entry.entryID == reference.entryID,entry.packageDirectory.utf8.elementsEqual(reference.directory.utf8) else { throw DeviceLocalCompleteSetFailure.packageMismatch }
        }
        let bindings=references.packages.map { DeviceRetainedEntryPackageBinding(entryID:$0.entryID,reference:.init(rootID:$0.rootID,contentID:$0.contentID,preparationOperationID:$0.preparationOperationID,directory:$0.directory)) }
        let baseline:DeviceLocalCompleteSetBaseline=record.expectedOld.map { .expectedEnvelope($0) } ?? .initialExplicit(legacyGrantSet:envelope.snapshot.grantSet)
        let request=DeviceLocalCompleteSetRecoveredRequest(structuralRootID:record.rootID,operationID:record.operationID,
            expectedGenerationID:envelope.expectedGenerationID,baseline:baseline,snapshot:envelope.snapshot,packages:bindings,owner:owner)
        return .init(request:request,selected:.init(reference:.init(identity:references.grants.identity,operationID:references.grants.preparationOperationID),expectedOwner:owner,packages:bindings))
    }
    static func references(_ bytes:Data)throws->DeviceLocalCompleteSetReferences {
        let object=try StructuralStoreCodec.object(bytes,limit:DeviceLocalCompleteSetBounds.intentLimit)
        try StructuralStoreCodec.keys(object,required:["schemaVersion","structuralRootID","operationID","generationID","packages","grants"])
        guard let packages=object["packages"] as? [[String:Any]],packages.count <= 12,
              let grants=object["grants"] as? [String:Any],let identity=grants["identity"] as? [String:Any] else { throw DeviceLocalCompleteSetFailure.invalidInput }
        for package in packages { try StructuralStoreCodec.keys(package,required:["entryID","rootID","contentID","preparationOperationID","directory"]) }
        try StructuralStoreCodec.keys(grants,required:["identity","preparationOperationID"])
        try StructuralStoreCodec.keys(identity,required:["rootID","revisionID"])
        let decoded=try JSONDecoder().decode(DeviceLocalCompleteSetReferences.self,from:bytes)
        guard decoded.schemaVersion == 1,Set(decoded.packages.map(\.entryID)).count == decoded.packages.count else { throw DeviceLocalCompleteSetFailure.invalidInput }
        for reference in decoded.packages { _ = try DeviceLocalCompleteSetBounds.string(reference.contentID);_ = try DeviceLocalCompleteSetBounds.string(reference.directory);guard reference.contentID.utf8.count == 64 else { throw DeviceLocalCompleteSetFailure.invalidInput } }
        return decoded
    }
}
