@main
struct MacBrokerSourceProvenanceTest {
    static func main() throws {
        let package = MacBrokerSourceProvenance.Package(dashboardId: "screen-a", revision: "rev-2", digest: "digest-2")
        let project = MacBrokerSourceProvenance.Project(projectId: "project-a", dashboardId: "screen-a")
        let head = MacBrokerSourceProvenance.BuildHead(projectId: "project-a", dashboardId: "screen-a",
            sourceVersion: "source-2", revision: "rev-2", digest: "digest-2")
        let proven = try MacBrokerSourceProvenance.sourceRevision(for: package,
            project: project, head: head)
        precondition(proven == "source-2")
        func rejects(_ project: MacBrokerSourceProvenance.Project?,
                     _ head: MacBrokerSourceProvenance.BuildHead?) {
            do {
                _ = try MacBrokerSourceProvenance.sourceRevision(for: package, project: project, head: head)
                fatalError("unproven source accepted")
            } catch MacBrokerSourceProvenance.Failure.unproven { }
            catch { fatalError("unexpected failure") }
        }
        rejects(nil, nil) // Imported package with no registered source project.
        rejects(project, nil) // Historical package without a current build head.
        rejects(project, .init(projectId: "project-a", dashboardId: "screen-a",
            sourceVersion: "source-1", revision: "rev-1", digest: "digest-1"))
        rejects(project, .init(projectId: "project-a", dashboardId: "screen-a",
            sourceVersion: "source-2", revision: "rev-2", digest: "different"))
        rejects(project, .init(projectId: "wrong-project", dashboardId: "screen-a",
            sourceVersion: "source-2", revision: "rev-2", digest: "digest-2"))
        print("MacBrokerSourceProvenanceTest passed")
    }
}
