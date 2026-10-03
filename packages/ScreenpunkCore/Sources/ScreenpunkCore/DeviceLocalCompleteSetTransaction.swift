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
        guard request.snapshot.entries.count <= 12, request.packages.count <= 12,
              request.owner.publicKey.count <= PairingLimits.identityByteCount else { throw DeviceLocalCompleteSetFailure.sizeLimit }
        if case .expectedEnvelope(let bytes) = request.baseline, bytes.count > envelopeLimit { throw DeviceLocalCompleteSetFailure.sizeLimit }
        var snapshotBudget = 2048, referenceBudget = 1024
        for entry in request.snapshot.entries {
            for field in [entry.displayName,entry.packageDirectory,entry.revision.dashboardId,entry.revision.revision,entry.revision.name,entry.revision.digest] { snapshotBudget += try string(field) }
            snapshotBudget += 512
        }
        if let grantSet = request.snapshot.grantSet { snapshotBudget += try string(grantSet) }
        for binding in request.packages {
            referenceBudget += 512 + (try string(binding.receipt.reference.directory)) + (try string(binding.receipt.reference.contentID))
        }
        if case .initialExplicit(let legacy) = request.baseline, let legacy { _ = try string(legacy) }
        guard snapshotBudget <= 64 * 1024, referenceBudget <= intentLimit, referenceBudget <= outcomeLimit,
              snapshotBudget + 2 * (((referenceBudget + 2) / 3) * 4) + 1024 <= envelopeLimit else { throw DeviceLocalCompleteSetFailure.sizeLimit }
    }
    static func encode<T: Encodable>(_ value: T, maximum: Int) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximum else { throw DeviceLocalCompleteSetFailure.sizeLimit }; return bytes
    }
}
