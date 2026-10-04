import Foundation

/// Qualified exact terminal restoration only. Not runtime admission, ongoing resource validity,
/// new approval, legacy migration, or a portable/physical credential durability guarantee.
final class DeviceLocalCompleteSetRestoreAcknowledgment {
    let operationID:UUID
    let generationID:UUID
    let envelopeBytes:Data
    fileprivate init(_ capture:DeviceStructuralStore.QualifiedCurrentCapture,generationID:UUID) {
        operationID=capture.operationID;self.generationID=generationID;envelopeBytes=capture.envelopeBytes
    }
}
/// Unmounted effectful restoration of the actual existing committed terminal tip. No new IDs or set
/// choices. Missing latest grant mappings require explicit original provisioning evidence; revision
/// names/public metadata never manufacture package provenance. Resolver epochs are never refreshed
/// implicitly. Structural change during resolution fails before structural effects.
final class DeviceLocalCompleteSetRestoreCoordinator {
    private let gate:DeviceLocalResourceGate
    private let resolver:DeviceRetainedResourceResolver
    init(packageStore:DevicePackagePreparationStore,grantStore:DeviceGrantPreparationStore,structuralStore:DeviceStructuralStore) {
        gate = .init(packageStore:packageStore,grantStore:grantStore,structuralStore:structuralStore)
        resolver = .init(packageStore:packageStore,grantStore:grantStore,structuralStore:structuralStore)
    }
    func restoreLatestTerminalExact(latestGroup:DeviceRetainedGrantResolutionGroup?=nil)throws->DeviceLocalCompleteSetRestoreAcknowledgment {
        // Caller mapping bounds precede copies/discovery/resolution. Selected mappings come ONLY
        // from the strict checked committed candidate. An unnecessary duplicate mapping is rejected.
        if let group=latestGroup {
            guard group.packages.count <= 12,group.expectedOwner.publicKey.count <= PairingLimits.identityByteCount,
                  group.expectedOwner.role == .controller,group.expectedOwner.isWellFormed else { throw DeviceLocalCompleteSetFailure.invalidInput }
            for binding in group.packages { _ = try DeviceLocalCompleteSetBounds.string(binding.reference.directory);_ = try DeviceLocalCompleteSetBounds.string(binding.reference.contentID) }
        }
        let discovery=try gate.withReadScope { try $0.inspectLatestStructuralTerminalExact() }
        let candidate=try DeviceLocalCompleteSetRestoreCodec.candidate(discovery.record)
        var groups=[candidate.selected]
        if let group=latestGroup {
            guard group.reference != candidate.selected.reference else { throw DeviceLocalCompleteSetFailure.invalidInput };groups.append(group)
        }
        let resources=try resolver.resolveTerminalExact(selected:candidate.selected.reference,groups:groups)
        try DeviceLocalCompleteSetBounds.preflight(candidate.request,resources:resources)
        let capture=try gate.commitRecoveredExact(candidate.request,resources:resources,discovery:discovery)
        return .init(capture,generationID:candidate.request.snapshot.generationID)
    }
}
