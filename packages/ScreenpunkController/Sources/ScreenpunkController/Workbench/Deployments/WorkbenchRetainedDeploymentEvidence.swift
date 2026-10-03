import Foundation
#if os(macOS)

/// Historical package identity from active, receipted local deployments.
/// This is evidence for a fresh rollback plan, never an approval or proof of
/// the device's current installed set.
public struct WorkbenchRetainedDeploymentPackage: Codable, Sendable, Equatable {
    public let planId: String
    public let workspaceId: String
    public let deviceId: String
    public let deviceProfileHash: String
    public let dashboardId: String
    public let sourceRevision: String
    public let preparedRevision: String
    public let digest: String
    public let declaredCapabilities: [String]

    init(_ evidence: WorkbenchRollbackEvidence) {
        planId = evidence.planId; workspaceId = evidence.workspaceId
        deviceId = evidence.deviceId; deviceProfileHash = evidence.deviceProfileHash
        dashboardId = evidence.dashboardId; sourceRevision = evidence.sourceRevision
        preparedRevision = evidence.preparedRevision; digest = evidence.digest
        declaredCapabilities = evidence.declaredCapabilities
    }
    public func validate() throws {
        guard [planId, workspaceId, deviceId, dashboardId, sourceRevision,
               preparedRevision].allSatisfy(WorkspaceValidation.id),
              WorkspaceValidation.sha256(deviceProfileHash),
              WorkspaceValidation.sha256(digest), declaredCapabilities.count <= 32,
              declaredCapabilities.allSatisfy(WorkspaceValidation.id) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

public struct WorkbenchRetainedDeploymentEvidenceRead: Codable, Sendable, Equatable {
    public static let method = "deployment.retainedEvidence"
    public let schemaVersion: Int
    public let kind: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let deviceId: String
    public let provenance: String
    public let complete: Bool
    public let packages: [WorkbenchRetainedDeploymentPackage]

    init(workspaceId: String, selectionGeneration: Int, deviceId: String,
         packages: [WorkbenchRetainedDeploymentPackage]) {
        schemaVersion = 1; kind = "retainedDeploymentEvidence"
        self.workspaceId = workspaceId; self.selectionGeneration = selectionGeneration
        self.deviceId = deviceId; provenance = "active-receipted-local-ledger"
        complete = true; self.packages = packages
    }
    public func validate() throws {
        guard schemaVersion == 1, kind == "retainedDeploymentEvidence",
              WorkspaceValidation.id(workspaceId), selectionGeneration > 0,
              WorkspaceValidation.id(deviceId),
              provenance == "active-receipted-local-ledger", complete,
              packages.count <= 128,
              packages.allSatisfy({ $0.workspaceId == workspaceId && $0.deviceId == deviceId }) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        for package in packages { try package.validate() }
    }
}
#endif
