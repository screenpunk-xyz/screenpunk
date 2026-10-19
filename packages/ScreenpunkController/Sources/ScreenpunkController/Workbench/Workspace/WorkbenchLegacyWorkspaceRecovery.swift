import Foundation
#if os(macOS)
/// Copies a reviewed legacy library into a new workspace. The original library,
/// device identity, credentials and machine preferences are never moved or reset.
public enum WorkbenchLegacyWorkspaceRecovery {
    public static func recover(client: WorkbenchBrokerClient, source: String,
                               destination: String) throws -> WorkbenchWorkspaceStatus {
        _ = try client.reconnectIfPeerClosed()
        let current = try client.workspaceStatus()
        guard current.state == "unconfigured" else { throw WorkbenchIPCError(.workspaceConflict) }
        guard let plan = try client.performAuthoring(method: .migrationPlan, params: [
            "schemaVersion": 1, "path": source, "destination": destination
        ]).migrationPlan, plan.applyAvailable, plan.unsupportedPortablePaths.isEmpty,
              plan.sourcePath == source, plan.destinationPath == destination else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let parameters: [String: Any] = ["schemaVersion": 1, "migrationId": plan.migrationId]
        guard try client.performAuthoring(method: .migrationReview, params: parameters).migrationPlan == plan else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        // Never resend apply after a transport failure: selection may have committed.
        _ = try client.performAuthoring(method: .migrationApply, params: parameters)
        return try client.workspaceStatus()
    }
}
#endif
