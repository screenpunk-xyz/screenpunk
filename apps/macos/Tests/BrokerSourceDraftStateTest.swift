import Foundation

@main
struct BrokerSourceDraftStateTest {
    static func main() {
        var editor = BrokerSourceDraftState()
        editor.load(workspaceId: "workspace-a", projectId: "project-a",
                    path: "web/index.html", version: "v1", text: "old")
        editor.draft = "my edit"
        editor.saveFailed() // Fake broker CAS conflict; user text survives.
        precondition(editor.conflict && editor.draft == "my edit" && editor.version == "v1" &&
                     !editor.canSave)
        editor.load(workspaceId: "workspace-a", projectId: "project-a",
                    path: "web/index.html", version: "v2", text: "remote edit")
        precondition(!editor.conflict && editor.draft == "remote edit" && !editor.dirty)
        editor.draft = "saved version"
        precondition(editor.saveSucceeded(expectedVersion: "v2", submittedText: "saved version",
                                        newVersion: "v3"))
        editor.draft = "new unsaved work"
        precondition(editor.dirty && editor.savedText == "saved version")
        precondition(!editor.saveSucceeded(expectedVersion: "v2", submittedText: "stale",
                                         newVersion: "v4"))
        editor.invalidateBinding(preserveDraft: true)
        precondition(editor.draft == "new unsaved work" && !editor.canSave)
        precondition(editor.orphaned && editor.originProjectId == "project-a")
        precondition(editor.needsDiscardBeforeNavigating(from: nil, to: "project-a"))
        // Reopening the original workspace/project cannot silently discard the orphan.
        precondition(editor.draft == "new unsaved work")
        editor.discardDraft() // Explicit user action.
        precondition(!editor.orphaned && editor.draft.isEmpty)

        editor.load(workspaceId: "workspace-a", projectId: "project-a",
                    path: "web/index.html", version: "v5", text: "baseline")
        var gate = BrokerProjectReadGate()
        let selectedA = gate.begin(projectId: "project-a", workspaceId: "workspace-a",
                                   selectionGeneration: 4)
        editor.draft = "unsaved A"
        // A click on B is blocked when the user chooses Keep Editing; a failed
        // inspection for B cannot make A's draft disappear.
        if !editor.needsDiscardBeforeNavigating(from: "project-a", to: "project-b") {
            _ = gate.begin(projectId: "project-b", workspaceId: "workspace-a",
                           selectionGeneration: 4)
        }
        precondition(gate.accepts(selectedA, projectId: "project-a", workspaceId: "workspace-a",
                                  selectionGeneration: 4) && editor.draft == "unsaved A")

        let pendingReadRevision = editor.draftRevision
        editor.draft = "typed after reload started"
        precondition(editor.needsExplicitReplacement(since: pendingReadRevision))
        // Keep Editing leaves the delayed broker response unapplied.
        precondition(editor.draft == "typed after reload started")
        editor.load(workspaceId: "workspace-a", projectId: "project-a",
                    path: "web/index.html", version: "v6", text: "remote source")
        precondition(editor.draft == "remote source" && !editor.dirty)
        print("BrokerSourceDraftStateTest passed")
    }
}
