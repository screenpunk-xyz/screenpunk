import Foundation

/// Opaque retained outbox head. Only the common inventory session can construct
/// its resource verification and exact durable acknowledgement closures.
@_spi(NativeInstallation) public final class NativeUnifiedCloudObservation: @unchecked Sendable, CustomReflectable {
    let original: DeviceMixedInventoryStore.CloudObservation
    private let verify: () throws -> Void
    private let acknowledge: () throws -> Void
    init(original: DeviceMixedInventoryStore.CloudObservation, verify: @escaping () throws -> Void,
         acknowledge: @escaping () throws -> Void) {
        self.original = original; self.verify = verify; self.acknowledge = acknowledge
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    func validatedBody(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch) throws -> Data {
        try current.requireInstallationAssociation(installation); try verify()
        guard original.exactBody.count <= 20_000 else { throw DeviceStructuralStoreError.conflict }
        return original.exactBody
    }
    func acceptResponse(_ bytes: Data, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch) throws {
        _ = try validatedBody(installation: installation, current: current)
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let body = try JSONSerialization.jsonObject(with: original.exactBody) as? [String: Any],
              let state = body["state"] as? [String: Any],
              Set(response.keys) == Set(["accepted", "installationId", "transitionId", "generationId"]),
              response["accepted"] as? Bool == true,
              response["installationId"] as? String == state["installationId"] as? String,
              response["transitionId"] as? String == state["transitionId"] as? String,
              response["generationId"] as? String == original.generationID.uuidString.lowercased() else {
            throw DeviceStructuralStoreError.conflict
        }
        try verify(); try current.requireInstallationAssociation(installation); try acknowledge()
    }
}

@_spi(NativeInstallation) extension DeviceUnifiedInventorySession {
    /// Retains the pending head; transport retries reuse its immutable wire body.
    public func pendingCloudObservation() throws -> NativeUnifiedCloudObservation? {
        guard let original = try nextCloudObservation() else { return nil }
        try validateCloudObservation(original)
        return NativeUnifiedCloudObservation(original: original,
            verify: { [self] in try validateCloudObservation(original) },
            acknowledge: { [self] in try acknowledgeCloudObservation(original) })
    }
    public func retainCloudCheckpoint(authenticatedGenerationID: UUID) throws {
        _ = try retainCloudObservation(authenticatedGenerationID: authenticatedGenerationID)
    }
}
