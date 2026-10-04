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
/// Unmounted, live-receipt-only coordinator. Original requests/IDs/selection are never regenerated.
/// The gate releases every lock before this method returns. No activation/notification is dispatched.
/// Missing in-memory resource receipts require a future explicit resolver; metadata cannot recreate them.
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
}
