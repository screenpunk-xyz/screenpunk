import Foundation

#if os(macOS)
/// A sourceCommit may update only the selected project's display name in the
/// portable catalog. Identity, location, ordering and every other project are
/// immutable in this operation; the source descriptor is validated separately.
enum WorkbenchScreenCatalogRename {
    static func matches(before: WorkspaceCatalog, after: WorkspaceCatalog,
                        projectId: String, expectedGeneration: Int) -> Bool {
        guard before.projects.count == after.projects.count,
              before.archivedDashboardIds == after.archivedDashboardIds,
              before.generation <= expectedGeneration,
              after.generation == expectedGeneration + 1,
              let index = before.projects.firstIndex(where: { $0.projectId == projectId }),
              before.projects.indices.allSatisfy({ offset in
                  offset == index || before.projects[offset] == after.projects[offset]
              }) else { return false }
        let old = before.projects[index], new = after.projects[index]
        return old.name != new.name && old.projectId == new.projectId &&
            old.dashboardId == new.dashboardId && old.location == new.location &&
            old.collectionIds == new.collectionIds && old.sortOrder == new.sortOrder
    }
}
#endif
