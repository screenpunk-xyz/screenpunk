import Foundation

#if os(macOS)
/// The sole extra catalog delta allowed in a contained source commit is an
/// exact dashboard identity replacement for one project. Source bytes and the
/// package selected by the public domain are verified separately.
enum WorkbenchScreenCatalogAssociation {
    static func matches(before: WorkspaceCatalog, after: WorkspaceCatalog,
        projectId: String, expectedGeneration: Int) -> Bool {
        guard before.archivedDashboardIds == after.archivedDashboardIds,
              before.projects.count == after.projects.count,
              before.generation <= expectedGeneration,
              after.generation == expectedGeneration + 1,
              let index = before.projects.firstIndex(where: { $0.projectId == projectId }),
              before.projects.indices.allSatisfy({
                  $0 == index || before.projects[$0] == after.projects[$0]
              }) else { return false }
        let old = before.projects[index], new = after.projects[index]
        return old.dashboardId != new.dashboardId &&
            old.projectId == new.projectId && old.name == new.name &&
            old.location == new.location && old.collectionIds == new.collectionIds &&
            old.sortOrder == new.sortOrder &&
            !before.projects.contains(where: { $0.dashboardId == new.dashboardId }) &&
            !before.archivedDashboardIds.contains(new.dashboardId)
    }
}
#endif
