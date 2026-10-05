import Foundation

/// Supplied schema3 resources. No admission, immutable storage or secret identity is inferred
/// from the nonsecret joined plan. Only the fixed command may consume this request.
struct DeviceNativeGrantPreparationRequest: GrantSecretRedacted {
    let operationID: UUID
    let input: DeviceNativeGrantRevisionInput
    let qualified: QualifiedDeviceNativeGrantRevision
    let expectedEntries: [DeviceGrantEntryExpectation]
    let plan: DeviceValidatedNativeProvisioningPlan
}

/// Explicit supplied nonsecret recovery resources. Native owner/IDs/selection remain supplied;
/// no authority, secret input or durable package evidence is inferred from this representation.
struct DeviceNativeGrantRecoveryResources {
    let roots: DeviceProvisioningRoots
    let delivery: DeviceNativeDeliveryCommandBinding
    let baseline: DeviceStructuralStore.NativeGenesisCheckpoint
    let candidate: DeviceNativeStructuralState
    let packages: [DeviceProvisioningPackageInput]
}

enum DeviceNativeGrantPreparationError: Error, Equatable {
    case invalidRecord, sizeLimit, unsafeBinding, scopeOverlap, conflict, capacity
    case repairRequired, outcomeUncertain
    case io(Int32)
}

/// Native3 is an independent namespace/domain. No Local private attempt decoder is relaxed.
/// Private frame bytes never appear in filesystem records, hashes or descriptions.
enum NativeGrantPreparationCodec {
    static let privateLimit = 4 * 1024 * 1024
    static let publicIntentLimit = 32768
    static let bindingLimit = 65536
    static let recordLimit = 65536
    static let confirmationLimit = 131072
    static let privateTotalLimit = 128 * 1024 * 1024
    static let credentialTotalLimit = 32 * 1024 * 1024
    static let itemLimit = 4225
    private struct PrivateAttempt: Codable, GrantSecretRedacted {
        let schemaVersion: Int
        let rootID: UUID
        let operationID: UUID
        let input: DeviceNativeGrantRevisionInput
        let completeSetIntent: Data
    }
    static func encode<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= limit else { throw DeviceNativeGrantPreparationError.sizeLimit }
        return bytes
    }
    static func privateBytes(_ request: DeviceNativeGrantPreparationRequest, rootID: UUID) throws -> Data {
        guard request.input.entries.count <= 12, request.expectedEntries.count <= 12,
              request.input.retainedRevisions.isEmpty,
              request.plan.intentBytes.count <= publicIntentLimit else { throw DeviceNativeGrantPreparationError.sizeLimit }
        let intent = try DeviceNativeProvisioningIntentCodec.decode(request.plan.intentBytes)
        guard rootID == request.input.identity.rootID, intent.roots.grantID == rootID,
              intent.grantOperationID == request.operationID,
              intent.grantIdentity == request.input.identity else { throw DeviceNativeGrantPreparationError.conflict }
        let fresh = try DeviceNativeGrantRevisionQualifier.qualify(request.input, expectedEntries: request.expectedEntries)
        guard fresh.exactlyMatches(request.qualified), fresh.publicMetadataBytes == intent.grantPublicMetadata else {
            throw DeviceNativeGrantPreparationError.conflict
        }
        let input = DeviceNativeGrantRevisionInput(schemaVersion: request.input.schemaVersion,
            identity: request.input.identity, owner: request.input.owner,
            entries: request.input.entries.sorted { $0.entryID.uuidString < $1.entryID.uuidString },
            credentials: request.input.credentials.sorted { $0.revisionID.uuidString < $1.revisionID.uuidString },
            retainedRevisions: [])
        let count = try DeviceNativePrivateAttemptV3.byteCount(input: input, operationID: request.operationID, intent: request.plan.intentBytes)
        guard count == intent.privateAttemptByteCount else { throw DeviceNativeGrantPreparationError.conflict }
        let bytes = try encode(PrivateAttempt(schemaVersion: 3, rootID: rootID,
            operationID: request.operationID, input: input, completeSetIntent: request.plan.intentBytes), limit: privateLimit)
        guard bytes.count == count else { throw DeviceNativeGrantPreparationError.conflict }
        return bytes
    }
}
