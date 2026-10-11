import Foundation
import ScreenpunkController

/// Captures the exact displayed selection and version for a broker rename.
/// A newer selection or project read invalidates the result before it reaches
/// the Mac view. The app never writes package or source files itself.
struct BrokerScreenRenameGate {
    struct SourceIntent {
        let workspaceId: String
        let selectionGeneration: Int
        let catalogGeneration: Int
        let projectId: String
        let sourceVersion: String
        let name: String

        var fields: [String: Any] {
            ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
             "expectedSelectionGeneration": selectionGeneration,
             "expectedCatalogGeneration": catalogGeneration,
             "projectId": projectId, "expectedSourceVersion": sourceVersion,
             "name": name]
        }
        func accepts(_ result: WorkbenchScreenRenameResult,
                     current: WorkbenchWorkspaceStatus,
                     displayedProjectId: String?) -> Bool {
            current.workspaceId == workspaceId &&
                current.selectionGeneration == selectionGeneration &&
                displayedProjectId == projectId &&
                result.workspaceId == workspaceId &&
                result.selectionGeneration == selectionGeneration &&
                result.catalogGeneration == catalogGeneration + 1 &&
                result.project.project.projectId == projectId &&
                result.project.project.name == name &&
                result.project.sourceVersion != sourceVersion
        }
    }

    struct PackageIntent {
        let workspaceId: String
        let selectionGeneration: Int
        let catalogGeneration: Int
        let dashboardId: String
        let revision: String
        let digest: String
        let name: String

        var fields: [String: Any] {
            ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
             "expectedSelectionGeneration": selectionGeneration,
             "expectedCatalogGeneration": catalogGeneration,
             "dashboardId": dashboardId, "expectedRevision": revision,
             "expectedDigest": digest, "name": name]
        }
        func accepts(_ result: WorkbenchScreenPackageRenameResult,
                     current: WorkbenchWorkspaceStatus,
                     displayedPackageKey: String?) -> Bool {
            current.workspaceId == workspaceId &&
                current.selectionGeneration == selectionGeneration &&
                displayedPackageKey == dashboardId + ":" + revision &&
                result.workspaceId == workspaceId &&
                result.selectionGeneration == selectionGeneration &&
                result.catalogGeneration == catalogGeneration + 1 &&
                result.dashboardId == dashboardId &&
                result.priorRevision == revision &&
                result.revision != revision &&
                result.name == name
        }

        func acceptsDuplicate(_ result: WorkbenchScreenPackageDuplicateResult,
                              current: WorkbenchWorkspaceStatus,
                              displayedPackageKey: String?) -> Bool {
            current.workspaceId == workspaceId &&
                current.selectionGeneration == selectionGeneration &&
                displayedPackageKey == dashboardId + ":" + revision &&
                result.workspaceId == workspaceId &&
                result.selectionGeneration == selectionGeneration &&
                result.catalogGeneration == catalogGeneration + 1 &&
                result.sourceDashboardId == dashboardId &&
                result.sourceRevision == revision &&
                result.dashboardId != dashboardId &&
                result.revision != revision &&
                result.name == name
        }
    }

    static func source(workspace: WorkbenchWorkspaceStatus,
                       project: WorkbenchSourceProject, name: String) throws -> SourceIntent {
        guard let workspaceId = workspace.workspaceId,
              let selection = workspace.selectionGeneration,
              let generation = workspace.generation else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let intent = SourceIntent(workspaceId: workspaceId,
            selectionGeneration: selection, catalogGeneration: generation,
            projectId: project.project.projectId, sourceVersion: project.sourceVersion,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard intent.name != project.project.name else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        _ = try WorkbenchScreenRenameRequest.parse(intent.fields)
        return intent
    }

    static func package(workspace: WorkbenchWorkspaceStatus,
                        package: WorkbenchWorkspacePackageSummary,
                        name: String) throws -> PackageIntent {
        guard let workspaceId = workspace.workspaceId,
              let selection = workspace.selectionGeneration,
              let generation = workspace.generation else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let intent = PackageIntent(workspaceId: workspaceId,
            selectionGeneration: selection, catalogGeneration: generation,
            dashboardId: package.dashboardId, revision: package.revision,
            digest: package.digest,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard intent.name != package.name else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        _ = try WorkbenchScreenPackageRenameRequest.parse(intent.fields)
        return intent
    }
}
