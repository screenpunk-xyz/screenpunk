/// A source revision is usable for Apply only when an authoritative current
/// build head links the registered project and exact selected-workspace
/// package identity. Imported and older historical packages have no inferred
/// source revision through this route.
struct MacBrokerSourceProvenance {
    struct Package {
        let dashboardId: String
        let revision: String
        let digest: String
    }
    struct Project {
        let projectId: String
        let dashboardId: String
    }
    struct BuildHead {
        let projectId: String
        let dashboardId: String
        let sourceVersion: String
        let revision: String
        let digest: String
    }
    enum Failure: Error { case unproven }

    static func sourceRevision(for package: Package, project: Project?,
                               head: BuildHead?) throws -> String {
        guard let project, let head,
              project.dashboardId == package.dashboardId,
              head.projectId == project.projectId,
              head.dashboardId == package.dashboardId,
              head.revision == package.revision,
              head.digest == package.digest,
              !head.sourceVersion.isEmpty else { throw Failure.unproven }
        return head.sourceVersion
    }
}
