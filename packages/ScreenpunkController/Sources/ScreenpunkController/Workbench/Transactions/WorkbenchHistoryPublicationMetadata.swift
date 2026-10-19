import Foundation
#if os(macOS)

/// Adds an exact, recoverable generation commit to a portable history object.
/// Callers add their immutable history targets first, then these three targets.
enum WorkbenchHistoryPublicationMetadata {
    static func append(to operations: inout [WorkbenchTransactionOperation],
                       blobs: inout [String: Data],
                       overview: WorkspaceOverview, root: WorkspaceFiles) throws {
        let nextGeneration = overview.descriptor.generation + 1
        guard nextGeneration < WorkspaceValidation.maxUInt,
              overview.catalog.generation <= overview.descriptor.generation,
              overview.settings.generation <= overview.descriptor.generation else {
            throw WorkspaceError.conflict
        }
        let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
        let settings = try root.directory(["Workbench", "Settings"]); defer { close(settings) }
        let oldDescriptor = try root.read(root.fd, "workspace.json")
        let oldCatalog = try root.read(library, "catalog.json")
        let oldSettings = try root.read(settings, "workbench.json")
        guard try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: oldDescriptor,
                  shape: .descriptor) == overview.descriptor,
              try WorkspaceJSON.decode(WorkspaceCatalog.self, from: oldCatalog,
                  shape: .catalog) == overview.catalog,
              try WorkspaceJSON.decode(WorkspaceSettings.self, from: oldSettings,
                  shape: .settings) == overview.settings else { throw WorkspaceError.conflict }
        let nextDescriptor = WorkspaceDescriptor(copy: overview.descriptor, generation: nextGeneration)
        let nextCatalog = WorkspaceCatalog(generation: nextGeneration,
            projects: overview.catalog.projects,
            archivedDashboardIds: overview.catalog.archivedDashboardIds)
        let nextSettings = WorkspaceSettings(generation: nextGeneration,
            presentation: overview.settings.presentation, profiles: overview.settings.profiles,
            screenIcons: overview.settings.screenIcons)
        let metadata: [(String, Data, Data)] = [
            ("libraryCatalog", oldCatalog, try WorkspaceJSON.encode(nextCatalog)),
            ("workbenchSettings", oldSettings, try WorkspaceJSON.encode(nextSettings)),
            ("workspaceDescriptor", oldDescriptor, try WorkspaceJSON.encode(nextDescriptor))]
        for (name, before, after) in metadata {
            let hash = WorkbenchTransactionDigest.hex(after)
            operations.append(.init(target: .metadata(name), before: .present(before),
                after: .present(after), recoveryBlobHash: hash))
            blobs[hash] = after
        }
    }
}
#endif
