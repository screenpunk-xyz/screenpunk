import Foundation

/// Private-construction acknowledgment of one exact structural commit. Not execution admission,
/// ongoing resource validity, live Keychain qualification, or restart receipt reconstruction.
final class DeviceLocalCompleteSetCommitAcknowledgment {
    let operationID: UUID
    let generationID: UUID
    let envelopeBytes: Data
    fileprivate init(_ capture: DeviceStructuralStore.QualifiedCurrentCapture, generationID: UUID) {
        operationID = capture.operationID; self.generationID = generationID; envelopeBytes = capture.envelopeBytes
    }
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

}
