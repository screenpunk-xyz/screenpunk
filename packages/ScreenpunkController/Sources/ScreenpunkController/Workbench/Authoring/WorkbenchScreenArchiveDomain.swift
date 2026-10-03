import Foundation
import CoreFoundation
import ScreenpunkCore

#if os(macOS)
/// A screen-library removal is a portable visibility change. The request pins
/// one verified package revision or one exact contained source version, so a
/// stale GUI selection cannot hide a different screen.
public struct WorkbenchScreenArchiveRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedCatalogGeneration: Int
    public let dashboardId: String
    public let expectedRevision: String?
    public let expectedDigest: String?
    public let projectId: String?
    public let expectedSourceVersion: String?

    public static func parse(_ fields: [String: Any]) throws -> Self {
        let common: Set<String> = ["schemaVersion", "expectedWorkspaceId",
            "expectedSelectionGeneration", "expectedCatalogGeneration",
            "dashboardId"]
        let keys = Set(fields.keys)
        guard keys == common.union(["expectedRevision", "expectedDigest"]) ||
              keys == common.union(["projectId", "expectedSourceVersion"]),
            let version = integer(fields["schemaVersion"], minimum: 1), version == 1,
            let workspaceId = fields["expectedWorkspaceId"] as? String,
            WorkspaceValidation.id(workspaceId),
            let selection = integer(fields["expectedSelectionGeneration"], minimum: 1),
            let generation = integer(fields["expectedCatalogGeneration"], minimum: 0),
            let dashboardId = fields["dashboardId"] as? String,
            WorkspaceValidation.id(dashboardId) else { throw WorkspaceError.invalidSchema }
        let revision = fields["expectedRevision"] as? String
        let digest = fields["expectedDigest"] as? String
        let projectId = fields["projectId"] as? String
        let sourceVersion = fields["expectedSourceVersion"] as? String
        guard (revision != nil && digest != nil &&
               WorkspaceValidation.id(revision!) && WorkspaceValidation.sha256(digest!)) ||
              (projectId != nil && sourceVersion != nil &&
               WorkspaceValidation.id(projectId!) && WorkspaceValidation.sha256(sourceVersion!))
        else { throw WorkspaceError.invalidSchema }
        return .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selection, expectedCatalogGeneration: generation,
            dashboardId: dashboardId, expectedRevision: revision,
            expectedDigest: digest, projectId: projectId,
            expectedSourceVersion: sourceVersion)
    }

    private static func integer(_ value: Any?, minimum: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue >= minimum else { return nil }
        return number.intValue
    }
}

public struct WorkbenchScreenArchiveResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let dashboardId: String
    public let sourceRetained: Bool
    public let packageHistoryRetained: Bool
    public let deviceContentsUntouched: Bool
}

public final class WorkbenchScreenArchiveDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    /// Library view omits tombstones; historical list/get remain complete for
    /// recovery and deployed-reference reads.
    public func visiblePackageManifests() throws -> [DashboardManifest] {
        guard let overview = try workspace.current() else { throw WorkspaceError.unavailable }
        let hidden = Set(overview.catalog.archivedDashboardIds)
        return try WorkbenchPortablePackages(workspace: workspace).list()
            .filter { !hidden.contains($0.dashboardId) }
    }

    public func archive(_ request: WorkbenchScreenArchiveRequest) throws
        -> WorkbenchScreenArchiveResult {
        guard let overview = try workspace.current(),
              overview.descriptor.workspaceId == request.expectedWorkspaceId,
              overview.selectionGeneration == request.expectedSelectionGeneration,
              overview.descriptor.generation == request.expectedCatalogGeneration,
              !overview.catalog.archivedDashboardIds.contains(request.dashboardId) else {
            throw WorkspaceError.conflict
        }
        if let revision = request.expectedRevision, let digest = request.expectedDigest {
            let exact = try WorkbenchPortablePackages(workspace: workspace).get(
                dashboardId: request.dashboardId, revision: revision)
            guard exact.manifest.digest == digest else { throw WorkspaceError.conflict }
        } else if let projectId = request.projectId,
                  let sourceVersion = request.expectedSourceVersion {
            let (captured, project, files) = try WorkbenchContainedAuthoring(workspace: workspace)
                .capture(projectId)
            guard captured.descriptor.generation == request.expectedCatalogGeneration,
                  project.dashboardId == request.dashboardId,
                  try WorkbenchSourceHasher.hash(files) == sourceVersion else {
                throw WorkspaceError.conflict
            }
        } else { throw WorkspaceError.invalidSchema }
        let sourceRetained = overview.catalog.projects.contains {
            $0.dashboardId == request.dashboardId
        }
        let catalog = try workspace.archiveScreen(dashboardId: request.dashboardId,
            expectedWorkspaceId: request.expectedWorkspaceId,
            expectedSelectionGeneration: request.expectedSelectionGeneration,
            expectedGeneration: request.expectedCatalogGeneration)
        return .init(workspaceId: request.expectedWorkspaceId,
            selectionGeneration: request.expectedSelectionGeneration,
            catalogGeneration: catalog.generation, dashboardId: request.dashboardId,
            sourceRetained: sourceRetained, packageHistoryRetained: true,
            deviceContentsUntouched: true)
    }
}
#endif
