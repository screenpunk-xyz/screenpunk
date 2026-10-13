import Foundation

enum NativeEnrollmentStageError: Error, Equatable { case invalidEnvelope, inventoryBlocked, conflict, capacity, outcomeUncertain }

/// Keychain-only immutable payload. No secret or secret digest is encoded in a
/// journal frame, error, description or reflection projection.
final class NativeEnrollmentStageEnvelope: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let service = "xyz.screenpunk.installation.cloud.enrollment-stage.v1"
    static let finalService = "xyz.screenpunk.installation.cloud"
    static let maximumBytes = 4096
    let binding: NativeEnrollmentStageBinding
    private let material: Data
    var description: String { "NativeEnrollmentStageEnvelope(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [] as [(label: String?, value: Any)]) }
    private init(binding: NativeEnrollmentStageBinding, secret: Data) { self.binding = binding; material = secret }
    static func original(binding: NativeEnrollmentStageBinding, secret: Data) throws -> NativeEnrollmentStageEnvelope {
        guard secret.count == 48 else { throw NativeEnrollmentStageError.invalidEnvelope }
        guard binding.prefix.count + 48 <= maximumBytes else { throw NativeEnrollmentStageError.capacity }
        return .init(binding: binding, secret: secret)
    }
    static func qualify(_ bytes: Data, expected: NativeEnrollmentStageBinding) throws -> NativeEnrollmentStageEnvelope {
        guard bytes.count <= maximumBytes, bytes.count == expected.prefix.count + 48,
            bytes.prefix(expected.prefix.count).elementsEqual(expected.prefix) else { throw NativeEnrollmentStageError.invalidEnvelope }
        return try original(binding: expected, secret: Data(bytes.suffix(48)))
    }
    /// Only the immutable backend may receive these bytes. Never filesystem IO.
    func keychainPayload() -> Data { var bytes = binding.prefix; bytes.append(material); return bytes }
    func exactMaterial(_ value: Data) -> Bool { material == value }
    func exactEnvelope(_ other: NativeEnrollmentStageEnvelope) -> Bool { binding == other.binding && material == other.material }
}

struct NativeEnrollmentStageBinding: Equatable {
    let cloudRootID: UUID, preparationID: UUID, enrollmentID: UUID
    let binding: DeviceManagementFormatHistory.Binding
    let input: NativeClaimInput
    let stage: Data, final: Data
    let prefix: Data
    init(cloudRootID: UUID, proposal: NativeEnrollmentPreparationReconstructionProposal) throws {
        try self.init(root: cloudRootID, preparation: proposal.preparationId, enrollment: proposal.enrollmentId,
            binding: proposal.binding, input: proposal.claimInput, stage: proposal.stageReference)
    }
    init(cloudRootID: UUID, declaration: PreparationDeclaration) throws {
        try self.init(root: cloudRootID, preparation: declaration.preparationId, enrollment: declaration.enrollmentId,
            binding: declaration.binding, input: declaration.claimInput, stage: declaration.stageReference)
    }
    private init(root: UUID, preparation: UUID, enrollment: UUID, binding: DeviceManagementFormatHistory.Binding, input: NativeClaimInput, stage: String) throws {
        guard binding.format == .nativeInstallationV1, binding.transitionID == input.transitionId else { throw NativeEnrollmentStageError.conflict }
        let a = try Self.reference(Data(stage.utf8)), b = try Self.reference(Data(binding.credentialReference.utf8))
        guard a != b else { throw NativeEnrollmentStageError.conflict }
        cloudRootID = root; preparationID = preparation; enrollmentID = enrollment; self.binding = binding; self.input = input; self.stage = a; final = b
        let values = [root, preparation, enrollment, binding.credentialGenerationID, binding.transitionID,
            input.requestId, input.accountId].map { Data($0.uuidString.lowercased().utf8) }
            + [Data((input.locationId?.uuidString.lowercased() ?? "unassigned").utf8)]
            + [a, b, Data("nativeInstallationV1".utf8), Data(input.name.utf8), Data(input.profile.utf8)]
        var bytes = Data("screenpunk-enrollment-stage-envelope-v1\0".utf8)
        for value in values {
            guard value.count <= 512, bytes.count + 8 + value.count + 48 <= NativeEnrollmentStageEnvelope.maximumBytes else { throw NativeEnrollmentStageError.capacity }
            var size = UInt64(value.count).bigEndian; withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }; bytes.append(value)
        }
        prefix = bytes
    }
    static func reference(_ bytes: Data) throws -> Data {
        guard (1...128).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { throw NativeEnrollmentStageError.inventoryBlocked }
        return bytes
    }
    static func == (a: Self, b: Self) -> Bool { a.prefix == b.prefix }
}

/// Raw backend projection before any String-keyed or normalized container.
/// Backend must bound enumeration BEFORE allocating an unbounded result.
struct NativeEnrollmentRawCredentialItem: Equatable, CustomReflectable, CustomStringConvertible {
    let service: Data, account: Data, persistentReference: Data
    let accessible: Bool
    private let material: Data
    init(service: Data, account: Data, persistentReference: Data, payload: Data, accessible: Bool = true) {
        self.service = service; self.account = account; self.persistentReference = persistentReference; material = payload; self.accessible = accessible
    }
    var description: String { "NativeEnrollmentRawCredentialItem(redacted)" }
    var customMirror: Mirror { Mirror(self, children: [] as [(label: String?, value: Any)]) }
    func keychainPayload() -> Data { material }
}
