import Foundation
import CoreFoundation

#if os(macOS)
/// Closed ordinary broker request. B registers the method and supplies the
/// existing mutation gate; callers cannot choose a writer role or filesystem
/// target. The selected workspace determines the contained project path.
public struct WorkbenchScreenRenameRequest: Sendable {
    public let expectedWorkspaceId: String
    public let expectedSelectionGeneration: Int
    public let expectedCatalogGeneration: Int
    public let projectId: String
    public let expectedSourceVersion: String
    public let name: String

    public static func parse(_ fields: [String: Any]) throws -> Self {
        guard Set(fields.keys) == ["schemaVersion", "expectedWorkspaceId",
            "expectedSelectionGeneration", "expectedCatalogGeneration", "projectId",
            "expectedSourceVersion", "name"],
            let version = fields["schemaVersion"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
            version.doubleValue == 1,
            let workspaceId = fields["expectedWorkspaceId"] as? String,
            WorkspaceValidation.id(workspaceId),
            let selection = fields["expectedSelectionGeneration"] as? NSNumber,
            CFGetTypeID(selection) != CFBooleanGetTypeID(),
            selection.doubleValue == Double(selection.intValue), selection.intValue > 0,
            let catalog = fields["expectedCatalogGeneration"] as? NSNumber,
            CFGetTypeID(catalog) != CFBooleanGetTypeID(),
            catalog.doubleValue == Double(catalog.intValue), catalog.intValue >= 0,
            let projectId = fields["projectId"] as? String,
            WorkspaceValidation.id(projectId),
            let sourceVersion = fields["expectedSourceVersion"] as? String,
            WorkspaceValidation.sha256(sourceVersion),
            let name = fields["name"] as? String,
            !name.isEmpty, name.utf8.count <= 120,
            WorkspaceValidation.text(name),
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw WorkspaceError.invalidSchema
        }
        return .init(expectedWorkspaceId: workspaceId,
            expectedSelectionGeneration: selection.intValue,
            expectedCatalogGeneration: catalog.intValue,
            projectId: projectId, expectedSourceVersion: sourceVersion, name: name)
    }
}

public struct WorkbenchScreenRenameResult: Codable, Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let catalogGeneration: Int
    public let project: WorkbenchSourceProject
}

/// Renames the one contained source project and its screen configuration in a
/// single source/history/catalog transaction. Existing immutable packages and
/// prior source snapshots remain byte-for-byte unchanged; a rebuild is needed
/// before a package with the new name exists.
public final class WorkbenchScreenRenameDomain {
    private let workspace: WorkspaceStore
    public init(workspace: WorkspaceStore) { self.workspace = workspace }

    public func rename(_ request: WorkbenchScreenRenameRequest) throws -> WorkbenchScreenRenameResult {
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let (overview, project, before) = try authoring.capture(request.projectId)
        guard overview.descriptor.workspaceId == request.expectedWorkspaceId,
              overview.selectionGeneration == request.expectedSelectionGeneration,
              overview.catalog.generation == request.expectedCatalogGeneration,
              let relative = project.location.path,
              try WorkbenchSourceHasher.hash(before) == request.expectedSourceVersion else {
            throw WorkspaceError.conflict
        }
        if project.name == request.name {
            return .init(workspaceId: request.expectedWorkspaceId,
                selectionGeneration: request.expectedSelectionGeneration,
                catalogGeneration: overview.catalog.generation,
                project: try authoring.get(request.projectId))
        }
        let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: before["screenpunk.project.json"] ?? Data(), shape: .project)
        try descriptor.validate(matching: project)
        guard let configBytes = before[descriptor.screenConfig] else {
            throw WorkspaceError.invalidSchema
        }
        var config = try WorkspaceJSON.object(from: configBytes)
        config["name"] = request.name
        let renamed = WorkspaceProject(projectId: project.projectId,
            dashboardId: project.dashboardId, name: request.name,
            location: project.location, collectionIds: project.collectionIds,
            sortOrder: project.sortOrder)
        let renamedDescriptor = WorkspaceProjectDocument(schemaVersion: descriptor.schemaVersion,
            projectId: descriptor.projectId, dashboardId: descriptor.dashboardId,
            name: request.name, kind: descriptor.kind,
            kitVersion: descriptor.kitVersion, entry: descriptor.entry,
            screenConfig: descriptor.screenConfig)
        try renamedDescriptor.validate(matching: renamed)
        var after = before
        after["screenpunk.project.json"] = try WorkspaceJSON.encode(renamedDescriptor)
        after[descriptor.screenConfig] = try JSONSerialization.data(withJSONObject: config,
            options: [.sortedKeys])
        let nextVersion = try WorkbenchSourceHasher.hash(after)
        let root = try WorkspaceFiles(path: overview.path)
        try authoring.commitSource(project: renamed, before: before, after: after,
            expected: overview, register: false, root: root)
        let read: WorkbenchSourceProject
        do { read = try authoring.get(request.projectId) }
        catch {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "screenRename",
                workspaceId: request.expectedWorkspaceId, projectId: request.projectId)
        }
        guard read.project == renamed, read.sourceVersion == nextVersion,
              read.path == overview.path + "/" + relative else {
            throw WorkspaceAppliedMutationReadUnavailable(operation: "screenRename",
                workspaceId: request.expectedWorkspaceId, projectId: request.projectId)
        }
        return .init(workspaceId: request.expectedWorkspaceId,
            selectionGeneration: request.expectedSelectionGeneration,
            catalogGeneration: overview.descriptor.generation + 1, project: read)
    }
}
#endif
