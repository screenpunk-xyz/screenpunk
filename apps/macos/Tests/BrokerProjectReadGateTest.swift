import Foundation

@main
struct BrokerProjectReadGateTest {
    static func main() {
        var gate = BrokerProjectReadGate()
        let workspace = "workspace-a"
        let slowA = gate.begin(projectId: "project-a", workspaceId: workspace, selectionGeneration: 1)
        let fastB = gate.begin(projectId: "project-b", workspaceId: workspace, selectionGeneration: 1)
        var displayed: String?
        // A fake B response arrives first; the older A response arrives later.
        if gate.accepts(fastB, projectId: "project-b", workspaceId: workspace,
                        selectionGeneration: 1) { displayed = "project-b" }
        if gate.accepts(slowA, projectId: "project-a", workspaceId: workspace,
                        selectionGeneration: 1) { displayed = "project-a" }
        precondition(displayed == "project-b")
        gate.invalidate()
        precondition(!gate.accepts(fastB, projectId: "project-b", workspaceId: workspace,
                                   selectionGeneration: 1))
        let newSelection = gate.begin(projectId: "project-b", workspaceId: workspace,
                                      selectionGeneration: 2)
        precondition(!gate.accepts(newSelection, projectId: "project-b", workspaceId: workspace,
                                   selectionGeneration: 1))
        print("BrokerProjectReadGateTest passed")
    }
}
