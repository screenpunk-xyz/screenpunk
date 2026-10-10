@main
struct MacBrokerReviewSelectionGateTest {
    static func main() {
        let gate = MacBrokerReviewSelectionGate.self
        precondition(gate.matches(expectedId: "workspace-a", expectedGeneration: 7,
            state: "selected", currentId: "workspace-a", currentGeneration: 7))
        precondition(!gate.matches(expectedId: "workspace-a", expectedGeneration: 7,
            state: "selected", currentId: "workspace-b", currentGeneration: 7))
        precondition(!gate.matches(expectedId: "workspace-a", expectedGeneration: 7,
            state: "selected", currentId: "workspace-a", currentGeneration: 8))
        precondition(!gate.matches(expectedId: "workspace-a", expectedGeneration: 7,
            state: "unconfigured", currentId: nil, currentGeneration: nil))
        print("MacBrokerReviewSelectionGateTest passed")
    }
}
