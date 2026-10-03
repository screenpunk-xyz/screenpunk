import Foundation
import CoreFoundation
import ScreenpunkCore

#if os(macOS)
/// A package-only screen has no editable source to rename. This request names
/// one exact immutable package and one workspace generation; it has no path,
/// writer role, consent source or arbitrary manifest field.
public struct WorkbenchScreenPackageRenameRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedCatalogGeneration: Int
    public let dashboardId: String
    public let expectedRevision: String
    public let expectedDigest: String
    public let name: String

    public static func parse(_ fields: [String: Any]) throws -> Self {
        guard Set(fields.keys) == ["schemaVersion", "expectedWorkspaceId",
            "expectedSelectionGeneration", "expectedCatalogGeneration", "dashboardId",
            "expectedRevision", "expectedDigest", "name"],
            let version = integer(fields["schemaVersion"], minimum: 1), version == 1,
            let workspaceId = fields["expectedWorkspaceId"] as? String,
            WorkspaceValidation.id(workspaceId),
            let selection = integer(fields["expectedSelectionGeneration"], minimum: 1),
            let generation = integer(fields["expectedCatalogGeneration"], minimum: 0),
            let dashboardId = fields["dashboardId"] as? String,
            WorkspaceValidation.id(dashboardId),
            let revision = fields["expectedRevision"] as? String,
            WorkspaceValidation.id(revision),
            let digest = fields["expectedDigest"] as? String,
            WorkspaceValidation.sha256(digest),
            let name = fields["name"] as? String,
            !name.isEmpty, name.utf8.count <= 120, WorkspaceValidation.text(name),
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw WorkspaceError.invalidSchema
        }
        return .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selection, expectedCatalogGeneration: generation,
            dashboardId: dashboardId, expectedRevision: revision,
            expectedDigest: digest, name: name)
    }

    private static func integer(_ value: Any?, minimum: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue >= minimum else { return nil }
        return number.intValue
    }
}

public struct WorkbenchScreenPackageRenameResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let dashboardId: String
    public let priorRevision: String
    public let revision: String
    public let digest: String
    public let name: String
}

/// Publishes a new verified immutable package revision with the same dashboard
/// identity and assets. The prior manifest/digest and all prior history remain
/// untouched. Contained source association, if any, remains a separate authoring
/// concern; a later build never inherits this renamed package automatically.
public final class WorkbenchScreenPackageRenameDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func rename(_ request: WorkbenchScreenPackageRenameRequest) throws
        -> WorkbenchScreenPackageRenameResult {
        guard let overview = try workspace.current(),
              overview.descriptor.workspaceId == request.expectedWorkspaceId,
              overview.selectionGeneration == request.expectedSelectionGeneration,
              overview.descriptor.generation == request.expectedCatalogGeneration else {
            throw WorkspaceError.conflict
        }
        let packages = WorkbenchPortablePackages(workspace: workspace)
        let prior = try packages.get(dashboardId: request.dashboardId,
            revision: request.expectedRevision)
        guard prior.manifest.digest == request.expectedDigest else { throw WorkspaceError.conflict }
        if prior.manifest.name == request.name {
            return .init(workspaceId: request.expectedWorkspaceId,
                selectionGeneration: request.expectedSelectionGeneration,
                catalogGeneration: overview.descriptor.generation,
                dashboardId: request.dashboardId, priorRevision: request.expectedRevision,
                revision: request.expectedRevision, digest: request.expectedDigest,
                name: request.name)
        }
        var manifest = prior.manifest
        manifest.name = request.name
        manifest.revision = UUID().uuidString.lowercased()
        manifest.digest = nil
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let published = try packages.importVerified(.init(manifest: manifest, files: prior.files),
            expectedWorkspaceId: request.expectedWorkspaceId,
            expectedSelectionGeneration: request.expectedSelectionGeneration,
            expectedCatalogGeneration: request.expectedCatalogGeneration)
        guard published.manifest == manifest, published.files == prior.files,
              let digest = published.manifest.digest else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "screenPackageRename",
                workspaceId: request.expectedWorkspaceId, projectId: nil)
        }
        return .init(workspaceId: request.expectedWorkspaceId,
            selectionGeneration: request.expectedSelectionGeneration,
            catalogGeneration: overview.descriptor.generation + 1,
            dashboardId: request.dashboardId, priorRevision: request.expectedRevision,
            revision: manifest.revision, digest: digest, name: request.name)
    }
}
#endif
