import Foundation

/// Only the latest request for the currently displayed workspace/project may publish.
struct BrokerProjectReadGate {
    private(set) var projectId: String?
    private var workspaceId: String?
    private var selectionGeneration: Int?
    private var requestId = UUID()

    mutating func begin(projectId: String, workspaceId: String, selectionGeneration: Int) -> UUID {
        self.projectId = projectId
        self.workspaceId = workspaceId
        self.selectionGeneration = selectionGeneration
        requestId = UUID()
        return requestId
    }

    mutating func invalidate() {
        projectId = nil; workspaceId = nil; selectionGeneration = nil
        requestId = UUID()
    }

    func accepts(_ request: UUID, projectId: String, workspaceId: String,
                 selectionGeneration: Int) -> Bool {
        request == requestId && self.projectId == projectId && self.workspaceId == workspaceId &&
            self.selectionGeneration == selectionGeneration
    }
}
