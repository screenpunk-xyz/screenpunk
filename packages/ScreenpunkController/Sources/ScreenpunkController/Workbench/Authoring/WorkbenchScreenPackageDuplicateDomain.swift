import Foundation
import ScreenpunkCore

#if os(macOS)
/// The same closed fields as package rename, but with a distinct broker method
/// and fresh dashboard/revision identities. No approval or device binding moves.
public struct WorkbenchScreenPackageDuplicateRequest: Sendable {
    let source: WorkbenchScreenPackageRenameRequest

    public static func parse(_ fields: [String: Any]) throws -> Self {
        .init(source: try WorkbenchScreenPackageRenameRequest.parse(fields))
    }
}

public struct WorkbenchScreenPackageDuplicateResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let sourceDashboardId: String
    public let sourceRevision: String
    public let dashboardId: String
    public let revision: String
    public let digest: String
    public let name: String
}

/// Copies verified assets into a new package-only screen. Historical source
/// bytes, credentials, grants and deployed sets are not copied or restored.
public final class WorkbenchScreenPackageDuplicateDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func duplicate(_ request: WorkbenchScreenPackageDuplicateRequest) throws
        -> WorkbenchScreenPackageDuplicateResult {
        let input = request.source
        guard let overview = try workspace.current(),
              overview.descriptor.workspaceId == input.expectedWorkspaceId,
              overview.selectionGeneration == input.expectedSelectionGeneration,
              overview.descriptor.generation == input.expectedCatalogGeneration else {
            throw WorkspaceError.conflict
        }
        let packages = WorkbenchPortablePackages(workspace: workspace)
        let source = try packages.get(dashboardId: input.dashboardId,
            revision: input.expectedRevision)
        guard source.manifest.digest == input.expectedDigest else { throw WorkspaceError.conflict }
        var manifest = source.manifest
        manifest.dashboardId = UUID().uuidString.lowercased()
        manifest.revision = UUID().uuidString.lowercased()
        manifest.name = input.name
        manifest.digest = nil
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let published = try packages.importVerified(.init(manifest: manifest, files: source.files),
            expectedWorkspaceId: input.expectedWorkspaceId,
            expectedSelectionGeneration: input.expectedSelectionGeneration,
            expectedCatalogGeneration: input.expectedCatalogGeneration)
        guard published.manifest == manifest, published.files == source.files,
              let digest = published.manifest.digest else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "screenPackageDuplicate",
                workspaceId: input.expectedWorkspaceId, projectId: nil)
        }
        return .init(workspaceId: input.expectedWorkspaceId,
            selectionGeneration: input.expectedSelectionGeneration,
            catalogGeneration: input.expectedCatalogGeneration + 1,
            sourceDashboardId: input.dashboardId, sourceRevision: input.expectedRevision,
            dashboardId: manifest.dashboardId, revision: manifest.revision,
            digest: digest, name: input.name)
    }
}
#endif
