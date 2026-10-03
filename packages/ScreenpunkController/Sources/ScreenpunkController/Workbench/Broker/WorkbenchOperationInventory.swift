import Foundation
#if os(macOS)

/// Bounded local evidence across workspace copies and the durable deployment
/// ledger. It deliberately makes no claim about other operation domains.
public struct WorkbenchOperationEntry: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let operationId: String
    public let kind: String
    public let durability: String
    public let state: String
    public let cancellationRequested: Bool
    public let workspaceId: String?
    public let deviceId: String?
    public let planId: String?
    public let sendAttempted: Bool?
    public let workspaceCopy: WorkbenchWorkspaceOperationStatus?

    init(copy: WorkbenchWorkspaceOperationStatus, durable: Bool = false) {
        schemaVersion = 1; operationId = copy.operationId
        kind = "workspaceCopy"; durability = durable ? "durable-local-journal" : "process-local"
        state = copy.state; cancellationRequested = copy.cancellationRequested
        workspaceId = copy.workspaceId; deviceId = nil; planId = nil; sendAttempted = nil
        workspaceCopy = copy
    }
    init(deployment: WorkbenchDeploymentOperationRecord,
         plan: WorkbenchDeploymentPlanRecord) {
        schemaVersion = 1; operationId = deployment.operationId
        kind = "deployment"; durability = "durable-local-ledger"
        state = deployment.state.rawValue
        cancellationRequested = deployment.cancelRequested
        workspaceId = plan.workspaceId; deviceId = plan.deviceId
        planId = deployment.planId; sendAttempted = deployment.sendAttempted
        workspaceCopy = nil
    }
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: operationId) != nil else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if kind == "workspaceCopy" {
            guard ["process-local", "durable-local-journal"].contains(durability),
                  workspaceId == workspaceCopy?.workspaceId, deviceId == nil,
                  planId == nil, sendAttempted == nil,
                  let workspaceCopy, workspaceCopy.operationId == operationId,
                  workspaceCopy.state == state,
                  workspaceCopy.cancellationRequested == cancellationRequested else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try workspaceCopy.validate()
        } else if kind == "deployment" {
            guard durability == "durable-local-ledger", workspaceCopy == nil,
                  let workspaceId, WorkspaceValidation.id(workspaceId),
                  let deviceId, WorkspaceValidation.id(deviceId),
                  let planId, WorkspaceValidation.id(planId),
                  sendAttempted != nil,
                  ["admitted", "sending", "received", "active", "failed",
                   "cancelled", "unknown"].contains(state) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        } else { throw WorkbenchIPCError(.invalidRequest) }
    }
}

public struct WorkbenchOperationInventory: Codable, Sendable, Equatable {
    public static let listMethod = "operation.inventory"
    public static let showMethod = "operation.inspect"
    public static let cancelMethod = "operation.requestCancel"
    public let schemaVersion: Int
    public let instanceId: String
    public let scope: String
    public let complete: Bool
    public let workspaceHistoryTruncated: Bool
    public let deploymentHistoryTruncated: Bool
    public let entries: [WorkbenchOperationEntry]

    init(instanceId: String, copies: [WorkbenchOperationEntry],
         deployments: [WorkbenchOperationEntry],
         workspaceHistoryTruncated: Bool, deploymentHistoryTruncated: Bool) {
        schemaVersion = 1; self.instanceId = instanceId
        scope = "workspace-copy-and-local-deployment"
        complete = false
        self.workspaceHistoryTruncated = workspaceHistoryTruncated
        self.deploymentHistoryTruncated = deploymentHistoryTruncated
        entries = copies + deployments
    }
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: instanceId) != nil,
              scope == "workspace-copy-and-local-deployment", !complete,
              entries.count <= 256,
              Set(entries.map(\.operationId)).count == entries.count,
              entries.filter({ $0.kind == "workspaceCopy" }).count <= 128,
              entries.filter({ $0.kind == "deployment" }).count <= 128 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        for entry in entries { try entry.validate() }
    }
}
#endif
