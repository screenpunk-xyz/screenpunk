import Foundation

/// A single local deployment's original durable package/grant graph. It is never
/// substituted for the legacy graph or admitted by transport receipt alone.
struct DeviceMixedIncomingLocalResources {
    let session: DeviceLegacyMigrationSession
    let binding: DeviceBoundRestoredRuntimeBinding
    let gate: DeviceLocalResourceGate
    let operationID: UUID
}

@_spi(NativeInstallation) public final class DeviceIncomingLocalPreparation {
    let resources: DeviceMixedIncomingLocalResources
    /// The session must have completed the real scoped provisioning transaction.
    /// A caller cannot create this capability from package metadata or an approval flag.
    public init(completed session: DeviceLegacyMigrationSession, operationID: UUID) throws {
        guard let binding = session.binding, binding.operationID == operationID else {
            throw DeviceStructuralStoreError.conflict
        }
        let gate = DeviceLocalResourceGate(packageStore: session.packages,
            grantStore: session.grants, structuralStore: session.structural)
        resources = .init(session: session, binding: binding, gate: gate, operationID: operationID)
    }
}
