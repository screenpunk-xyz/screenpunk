import Foundation

/// Private-construction acknowledgment of one exact structural commit. Not execution admission,
/// ongoing resource validity, live Keychain qualification, or restart receipt reconstruction.
final class DeviceLocalCompleteSetCommitAcknowledgment {
    let operationID: UUID
    let generationID: UUID
    let envelopeBytes: Data
    private let originalCapture:DeviceStructuralStore.QualifiedCurrentCapture
    fileprivate init(_ capture: DeviceStructuralStore.QualifiedCurrentCapture, generationID: UUID) {
        originalCapture=capture;operationID = capture.operationID; self.generationID = generationID; envelopeBytes = capture.envelopeBytes
    }
    func verifyOriginalUnderScope(_ scope:DeviceLocalResourceReadScope)throws {try scope.verifyQualifiedStructuralCapture(originalCapture)}
}
/// Unmounted coordinator for supplied live receipts or explicit resolver bundles. Requests/IDs/selection are never regenerated.
/// The gate releases every lock before this method returns. No activation/notification is dispatched.
/// Missing receipts require explicit terminal resolution; metadata cannot recreate them or renew stale checkpoints.
final class DeviceLocalCompleteSetCommitCoordinator {
    private let gate: DeviceLocalResourceGate
    init(packageStore: DevicePackagePreparationStore, grantStore: DeviceGrantPreparationStore, structuralStore: DeviceStructuralStore) {
        gate = .init(packageStore:packageStore,grantStore:grantStore,structuralStore:structuralStore)
    }
    func commitPreparedExact(_ request: DeviceLocalCompleteSetRequest) throws -> DeviceLocalCompleteSetCommitAcknowledgment {
        try DeviceLocalCompleteSetBounds.preflight(request)
        let capture = try gate.commitPreparedExact(request)
        return .init(capture,generationID:request.snapshot.generationID)
    }
    func commitRecoveredExact(_ request:DeviceLocalCompleteSetRecoveredRequest,
                              resources:DeviceResolvedRetainedResources) throws -> DeviceLocalCompleteSetCommitAcknowledgment {
        try DeviceLocalCompleteSetBounds.preflight(request,resources:resources)
        let capture=try gate.commitRecoveredExact(request,resources:resources)
        return .init(capture,generationID:request.snapshot.generationID)
    }

    /// Consumes only the original bound-v2 terminal receipt. The pending journal remains retained;
    /// this acknowledgment is structural durability, never activation or journal completion.
    func commitBoundTerminalExact(_ receipt:DeviceBoundTerminalGrantReceipt,
        journal:DeviceLocalProvisioningIntentStore)throws->DeviceLocalCompleteSetCommitAcknowledgment {
        let (capture,generation)=try gate.commitBoundTerminalExact(receipt,journal:journal)
        return .init(capture,generationID:generation)
    }

    func completeProvisioningExact(_ terminal:DeviceBoundTerminalGrantReceipt,
        acknowledgment:DeviceLocalCompleteSetCommitAcknowledgment,journal:DeviceLocalProvisioningIntentStore)throws->DeviceLocalProvisioningIntentStore.CompletionReceipt {
        try gate.completeProvisioningExact(terminal,acknowledgment:acknowledgment,journal:journal)
    }

}
