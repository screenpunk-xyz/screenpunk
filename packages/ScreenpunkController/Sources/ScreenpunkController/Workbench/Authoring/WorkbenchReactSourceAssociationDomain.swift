import Foundation
import CoreFoundation

#if os(macOS)
/// Attach an existing contained React project to one immutable package identity.
/// This is authoring provenance only; it does not execute the source or grant
/// a kit, connection, deployment, credential, or device permission.
public struct WorkbenchReactSourceAssociationRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedCatalogGeneration: Int
    public let projectId: String
    public let expectedSourceVersion: String
    public let dashboardId: String
    public let expectedRevision: String
    public let expectedDigest: String

    public static func parse(_ fields: [String: Any]) throws -> Self {
        guard Set(fields.keys) == ["schemaVersion", "expectedWorkspaceId",
            "expectedSelectionGeneration", "expectedCatalogGeneration", "projectId",
            "expectedSourceVersion", "dashboardId", "expectedRevision", "expectedDigest"],
            let version = integer(fields["schemaVersion"], minimum: 1), version == 1,
            let workspaceId = fields["expectedWorkspaceId"] as? String,
            WorkspaceValidation.id(workspaceId),
            let selection = integer(fields["expectedSelectionGeneration"], minimum: 1),
            let generation = integer(fields["expectedCatalogGeneration"], minimum: 0),
            let projectId = fields["projectId"] as? String,
            WorkspaceValidation.id(projectId),
            let sourceVersion = fields["expectedSourceVersion"] as? String,
            WorkspaceValidation.sha256(sourceVersion),
            let dashboardId = fields["dashboardId"] as? String,
            WorkspaceValidation.id(dashboardId),
            let revision = fields["expectedRevision"] as? String,
            WorkspaceValidation.id(revision),
            let digest = fields["expectedDigest"] as? String,
            WorkspaceValidation.sha256(digest) else { throw WorkspaceError.invalidSchema }
        return .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selection, expectedCatalogGeneration: generation,
            projectId: projectId, expectedSourceVersion: sourceVersion,
            dashboardId: dashboardId, expectedRevision: revision, expectedDigest: digest)
    }
    private static func integer(_ value: Any?, minimum: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue >= minimum else { return nil }
        return number.intValue
    }
}

public struct WorkbenchReactSourceAssociationResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let project: WorkbenchSourceProject
    public let packageRevision: String
    public let packageDigest: String
    public let authorityRestored: Bool
}

public final class WorkbenchReactSourceAssociationDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func attach(_ request: WorkbenchReactSourceAssociationRequest) throws
        -> WorkbenchReactSourceAssociationResult {
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let (overview, project, before) = try authoring.capture(request.projectId)
        guard overview.descriptor.workspaceId == request.expectedWorkspaceId,
              overview.selectionGeneration == request.expectedSelectionGeneration,
              overview.descriptor.generation == request.expectedCatalogGeneration,
              try WorkbenchSourceHasher.hash(before) == request.expectedSourceVersion,
              !overview.catalog.archivedDashboardIds.contains(request.dashboardId),
              !overview.catalog.projects.contains(where: {
                  $0.dashboardId == request.dashboardId && $0.projectId != request.projectId
              }) else { throw WorkspaceError.conflict }
        let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: before["screenpunk.project.json"] ?? Data(), shape: .project)
        try document.validate(matching: project)
        guard document.kind == "react" else { throw WorkspaceError.invalidSchema }
        // A portable pin is descriptive only. If present, it must match the
        // workspace's requirement; this never authenticates or launches a kit.
        if let lockBytes = before["screenpunk.lock.json"] {
            let pin = try WorkspaceJSON.decode(WorkbenchSourceKitPin.self,
                from: lockBytes, shape: .sourceKitPin)
            let root = try WorkspaceFiles(path: overview.path)
            let folder = try root.directory(["Workbench", "Toolchains"])
            defer { close(folder) }
            let requirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
                from: root.read(folder, "requirements.json"), shape: .requirements)
            try requirements.validate()
            guard pin.schemaVersion == 1,
                  requirements.required.contains(pin.requirement),
                  pin.kitVersion == document.kitVersion else { throw WorkspaceError.conflict }
        }
        let package = try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: request.dashboardId, revision: request.expectedRevision)
        guard package.manifest.digest == request.expectedDigest else { throw WorkspaceError.conflict }
        if project.dashboardId == request.dashboardId {
            return .init(workspaceId: request.expectedWorkspaceId,
                selectionGeneration: request.expectedSelectionGeneration,
                catalogGeneration: overview.catalog.generation,
                project: try authoring.get(request.projectId),
                packageRevision: request.expectedRevision,
                packageDigest: request.expectedDigest, authorityRestored: false)
        }
        let replacement = WorkspaceProject(projectId: project.projectId,
            dashboardId: request.dashboardId, name: project.name,
            location: project.location, collectionIds: project.collectionIds,
            sortOrder: project.sortOrder)
        let descriptor = WorkspaceProjectDocument(schemaVersion: document.schemaVersion,
            projectId: document.projectId, dashboardId: request.dashboardId,
            name: document.name, kind: document.kind, kitVersion: document.kitVersion,
            entry: document.entry, screenConfig: document.screenConfig)
        try descriptor.validate(matching: replacement)
        var after = before
        after["screenpunk.project.json"] = try WorkspaceJSON.encode(descriptor)
        let nextVersion = try WorkbenchSourceHasher.hash(after)
        let root = try WorkspaceFiles(path: overview.path)
        try authoring.commitSource(project: replacement, before: before, after: after,
            expected: overview, register: false, root: root)
        let read: WorkbenchSourceProject
        do { read = try authoring.get(request.projectId) }
        catch {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "reactSourceAssociate",
                workspaceId: request.expectedWorkspaceId, projectId: request.projectId)
        }
        guard read.project == replacement, read.sourceVersion == nextVersion else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "reactSourceAssociate",
                workspaceId: request.expectedWorkspaceId, projectId: request.projectId)
        }
        return .init(workspaceId: request.expectedWorkspaceId,
            selectionGeneration: request.expectedSelectionGeneration,
            catalogGeneration: overview.descriptor.generation + 1,
            project: read, packageRevision: request.expectedRevision,
            packageDigest: request.expectedDigest, authorityRestored: false)
    }
}
#endif
