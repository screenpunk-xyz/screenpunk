import Foundation
import ScreenpunkCore

#if os(macOS)
/// A bounded proposal from the service's active, receipted deployment ledger.
/// A caller must still obtain a fresh device observation, broker rollback plan,
/// complete review and new approval before sending any package.
public struct WorkbenchRetainedRollbackSelection: Sendable, Equatable {
    public struct Package: Sendable, Equatable {
        public let dashboardId: String
        public let sourceRevision: String
        public let revision: String
        public let digest: String
        public let dataDescription: String
    }
    public let packages: [Package]
    public let selectedDashboardId: String
    public let removedDashboardIds: [String]

    private struct Provider: WorkbenchRollbackEvidenceProvider {
        let read: WorkbenchRetainedDeploymentEvidenceRead
        func retainedPackages(workspaceId: String, deviceId: String) throws
            -> [WorkbenchRollbackEvidence] {
            read.packages.map {
                .init(planId: $0.planId, workspaceId: $0.workspaceId,
                    deviceId: $0.deviceId, deviceProfileHash: $0.deviceProfileHash,
                    dashboardId: $0.dashboardId, sourceRevision: $0.sourceRevision,
                    preparedRevision: $0.preparedRevision, digest: $0.digest,
                    declaredCapabilities: $0.declaredCapabilities)
            }
        }
    }

    public static func resolve(read: WorkbenchRetainedDeploymentEvidenceRead,
        deviceProfileHash: String, previous: [LANScreenSetEntry],
        previouslySelectedDashboardId: String?, current: [LANScreenSetEntry]) throws -> Self {
        try read.validate()
        let selection = try WorkbenchRollbackProvenance.resolve(
            workspaceId: read.workspaceId, deviceId: read.deviceId,
            deviceProfileHash: deviceProfileHash, previous: previous,
            previouslySelectedDashboardId: previouslySelectedDashboardId,
            current: current, provider: Provider(read: read))
        let resolved = try selection.packages.map { item -> Package in
            let matching = read.packages.filter {
                $0.dashboardId == item.dashboardId &&
                    $0.sourceRevision == item.sourceRevision &&
                    $0.preparedRevision == item.revision &&
                    $0.deviceProfileHash == deviceProfileHash
            }
            guard let exact = matching.first,
                  matching.allSatisfy({ $0.digest == exact.digest }) else {
                throw WorkbenchRollbackProvenanceError.ambiguousProvenance
            }
            return .init(dashboardId: item.dashboardId,
                sourceRevision: item.sourceRevision, revision: item.revision,
                digest: exact.digest, dataDescription: item.dataDescription)
        }
        return .init(packages: resolved, selectedDashboardId: selection.selectedDashboardId,
            removedDashboardIds: selection.removedDashboardIds)
    }
}
#endif
