import Foundation
import ScreenpunkCore

#if os(macOS)
/// Only the service's retained deployment ledger may implement this provider.
/// Restored workspace files and GUI history labels are not provenance.
protocol WorkbenchRollbackEvidenceProvider {
    func retainedPackages(workspaceId: String, deviceId: String) throws -> [WorkbenchRollbackEvidence]
}

struct WorkbenchRollbackEvidence: Equatable {
    let planId: String
    let workspaceId: String
    let deviceId: String
    let deviceProfileHash: String
    let dashboardId: String
    let sourceRevision: String
    let preparedRevision: String
    let digest: String
    let declaredCapabilities: [String]
}

struct WorkbenchRollbackSelection {
    let packages: [WorkbenchPreparedSelection]
    let selectedDashboardId: String
    let removedDashboardIds: [String]
}

enum WorkbenchRollbackProvenanceError: Error, Equatable {
    case noPreviousSet, missingProvenance, ambiguousProvenance, unsupportedCapabilities
}

/// Resolves an earlier installed set to exact prepared packages. The normal
/// rollbackPlan path still re-observes the device, verifies retained bytes and
/// requires fresh durable approval before any transfer.
enum WorkbenchRollbackProvenance {
    /// The provider may index only a completed operation's retained review.
    /// A merely planned or admitted deployment never proves an installed set.
    static func evidence(from review: WorkbenchDeploymentReview,
        operation: WorkbenchDeploymentOperationRecord) throws -> [WorkbenchRollbackEvidence] {
        guard operation.state == .active, operation.receiptJSON != nil,
              operation.planId == review.plan.planId,
              operation.planHash == review.planHash,
              try WorkbenchDeploymentHash.plan(review.plan) == review.planHash else {
            throw WorkbenchRollbackProvenanceError.missingProvenance
        }
        return review.plan.packages.map { package in
            .init(planId: review.plan.planId, workspaceId: review.plan.workspaceId,
                deviceId: review.plan.deviceId,
                deviceProfileHash: review.plan.deviceProfileHash,
                dashboardId: package.dashboardId,
                sourceRevision: package.sourceRevision,
                preparedRevision: package.revision,
                digest: package.digest,
                declaredCapabilities: package.declaredCapabilities)
        }
    }

    static func resolve(workspaceId: String, deviceId: String,
        deviceProfileHash: String, previous: [LANScreenSetEntry],
        previouslySelectedDashboardId: String?, current: [LANScreenSetEntry],
        provider: any WorkbenchRollbackEvidenceProvider) throws -> WorkbenchRollbackSelection {
        guard WorkspaceValidation.id(workspaceId), WorkspaceValidation.id(deviceId),
              WorkspaceValidation.sha256(deviceProfileHash),
              (1...12).contains(previous.count),
              let selected = previouslySelectedDashboardId,
              previous.contains(where: { $0.dashboardId == selected }),
              Set(previous.map(\.dashboardId)).count == previous.count,
              Set(current.map(\.dashboardId)).count == current.count else {
            throw WorkbenchRollbackProvenanceError.noPreviousSet
        }
        let retained = try provider.retainedPackages(workspaceId: workspaceId, deviceId: deviceId)
        var resolved: [WorkbenchPreparedSelection] = []
        for old in previous {
            let exact = retained.filter {
                $0.workspaceId == workspaceId && $0.deviceId == deviceId &&
                $0.deviceProfileHash == deviceProfileHash &&
                $0.dashboardId == old.dashboardId &&
                $0.preparedRevision == old.revision &&
                WorkspaceValidation.sha256($0.digest) &&
                WorkspaceValidation.id($0.sourceRevision) &&
                WorkspaceValidation.id($0.planId)
            }
            guard !exact.isEmpty else { throw WorkbenchRollbackProvenanceError.missingProvenance }
            // Every ordinary web package declares the baseline runtime. The
            // current Mac review can show that baseline, but no live connection,
            // navigation, device-behavior or other capability scope.
            guard exact.allSatisfy({
                $0.declaredCapabilities.isEmpty ||
                    $0.declaredCapabilities == ["web-runtime"]
            }) else {
                throw WorkbenchRollbackProvenanceError.unsupportedCapabilities
            }
            let identities = Set(exact.map {
                $0.sourceRevision + ":" + $0.digest
            })
            guard identities.count == 1, let evidence = exact.first else {
                throw WorkbenchRollbackProvenanceError.ambiguousProvenance
            }
            resolved.append(.init(dashboardId: old.dashboardId,
                sourceRevision: evidence.sourceRevision,
                revision: old.revision,
                dataDescription: "Retained broker deployment plan \(evidence.planId)"))
        }
        let priorIDs = Set(previous.map(\.dashboardId))
        return .init(packages: resolved.sorted { $0.dashboardId.utf8.lexicographicallyPrecedes($1.dashboardId.utf8) },
            selectedDashboardId: selected,
            removedDashboardIds: current.map(\.dashboardId).filter { !priorIDs.contains($0) }.sorted())
    }
}
#endif
