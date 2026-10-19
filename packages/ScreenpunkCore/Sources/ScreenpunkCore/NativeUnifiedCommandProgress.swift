import Foundation
import CoreFoundation

/// Progress is distinct from a qualified activation outcome. This type cannot
/// report applied or failed without the existing durable outcome protocol.
@_spi(NativeInstallation) public enum NativeUnifiedCommandProgressPhase: String, Sendable {
    case preparing, superseded
}
@_spi(NativeInstallation) public final class NativeUnifiedCommandProgress: @unchecked Sendable, CustomReflectable {
    let operationID: UUID, expectedGenerationID: UUID
    private let validate: () throws -> Void
    private let validateCurrent: ((NativeOperationalInstallation, NativeCurrentInstallationDispatch) throws -> Void)?
    init(operationID: UUID, expectedGenerationID: UUID, validate: @escaping () throws -> Void,
         validateCurrent: ((NativeOperationalInstallation, NativeCurrentInstallationDispatch) throws -> Void)? = nil) {
        self.operationID = operationID; self.expectedGenerationID = expectedGenerationID; self.validate = validate; self.validateCurrent = validateCurrent
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    func requireCurrent(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch) throws {
        try current.requireInstallationAssociation(installation); try validateCurrent?(installation, current)
    }
    func validatedBody(phase: NativeUnifiedCommandProgressPhase) throws -> Data {
        try validate()
        return try JSONSerialization.data(withJSONObject: ["operationId": operationID.uuidString.lowercased(),
            "expectedGenerationId": expectedGenerationID.uuidString.lowercased(), "phase": phase.rawValue], options: [.sortedKeys])
    }
    func validateReceipt(_ bytes: Data, phase: NativeUnifiedCommandProgressPhase) throws {
        try validate()
        typealias C = DeviceNativeDeliveryAttachmentCodec
        let response = try C.object(bytes, limit: 4096, keys: ["operationId", "phase", "accepted"])
        guard try C.uuid(response["operationId"]) == operationID,
              response["phase"] as? String == phase.rawValue,
              let accepted = response["accepted"] as? NSNumber,
              CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue else { throw NativeDeliveryExecutionError.association }
    }
}
@_spi(NativeInstallation) extension DeviceUnifiedInventorySession {
    public func retainedCloudProgress() throws -> NativeUnifiedCommandProgress {
        let association = try retainedCloudProgressAssociation()
        return NativeUnifiedCommandProgress(operationID: association.operationID,
            expectedGenerationID: association.expectedGenerationID, validate: association.validate)
    }
}

@_spi(NativeInstallation) public enum NativeUnifiedMountFailureCode: String, Sendable {
    case navigationFailed = "navigation_failed"
    case renderProcessTerminated = "render_process_terminated"
    case mountValidationFailed = "mount_validation_failed"
}
/// Structural commit remains true when rendering fails. This opaque proof can
/// report only the exact committed command generation, never a fake rollback.
@_spi(NativeInstallation) public final class NativeUnifiedCommandMountFailure: @unchecked Sendable, CustomReflectable {
    private let operationID: UUID, expectedGenerationID: UUID, committedGenerationID: UUID
    private let validate: () throws -> Void
    private let acknowledge: ((Data) throws -> Void)?
    init(operationID: UUID, expectedGenerationID: UUID, committedGenerationID: UUID, validate: @escaping () throws -> Void, acknowledge: ((Data) throws -> Void)? = nil) {
        self.operationID = operationID; self.expectedGenerationID = expectedGenerationID
        self.committedGenerationID = committedGenerationID; self.validate = validate; self.acknowledge = acknowledge
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    func validatedBody(code: NativeUnifiedMountFailureCode) throws -> Data {
        try validate()
        return try JSONSerialization.data(withJSONObject: ["operationId": operationID.uuidString.lowercased(),
            "expectedGenerationId": expectedGenerationID.uuidString.lowercased(), "phase": "failed",
            "committedGenerationId": committedGenerationID.uuidString.lowercased(), "failureCode": code.rawValue], options: [.sortedKeys])
    }
    func validateReceipt(_ bytes: Data) throws {
        try validate()
        typealias C = DeviceNativeDeliveryAttachmentCodec
        let response = try C.object(bytes, limit: 4096, keys: ["operationId", "phase", "accepted"])
        guard try C.uuid(response["operationId"]) == operationID, response["phase"] as? String == "failed",
              let accepted = response["accepted"] as? NSNumber,
              CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue else { throw NativeDeliveryExecutionError.association }
        try acknowledge?(bytes)
    }
}

@_spi(NativeInstallation) extension DeviceUnifiedInventorySession {
    public func retainedCloudMountFailure() throws -> NativeUnifiedCommandMountFailure {
        let association = try retainedCloudMountFailureAssociation()
        return NativeUnifiedCommandMountFailure(operationID: association.operationID,
            expectedGenerationID: association.expectedGenerationID, committedGenerationID: association.committedGenerationID,
            validate: association.validate, acknowledge: association.acknowledge)
    }
}
