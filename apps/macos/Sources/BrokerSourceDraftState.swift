import Foundation

/// Keeps an unsaved draft through CAS conflicts; only an explicit load replaces it.
struct BrokerSourceDraftState {
    var requestedPath = "web/index.html"
    var draft = "" { didSet { draftRevision &+= 1 } }
    private(set) var draftRevision: UInt64 = 0
    private(set) var loadedProjectId: String?
    private(set) var loadedPath = ""
    private(set) var originWorkspaceId = ""
    private(set) var originProjectId = ""
    private(set) var originPath = ""
    private(set) var version = ""
    private(set) var savedText = ""
    private(set) var conflict = false

    var dirty: Bool { draft != savedText }
    var requiresDiscard: Bool { dirty || conflict }
    var orphaned: Bool { loadedProjectId == nil && requiresDiscard }
    var canSave: Bool {
        loadedProjectId != nil && loadedPath == requestedPath && !version.isEmpty && !conflict &&
            draft.utf8.count <= 2_048
    }

    func needsDiscardBeforeNavigating(from currentProjectId: String?,
                                      to newProjectId: String) -> Bool {
        requiresDiscard && currentProjectId != newProjectId
    }

    func needsExplicitReplacement(since revision: UInt64) -> Bool {
        requiresDiscard || draftRevision != revision
    }

    mutating func load(workspaceId: String, projectId: String, path: String,
                       version: String, text: String) {
        requestedPath = path; loadedPath = path; loadedProjectId = projectId
        originWorkspaceId = workspaceId; originProjectId = projectId; originPath = path
        self.version = version; draft = text; savedText = text; conflict = false
    }

    @discardableResult mutating func saveSucceeded(expectedVersion: String,
                                                     submittedText: String,
                                                     newVersion: String) -> Bool {
        guard loadedProjectId != nil, version == expectedVersion, !newVersion.isEmpty else { return false }
        version = newVersion; savedText = submittedText; conflict = false
        return true
    }

    mutating func saveFailed() { conflict = true }

    mutating func invalidateBinding(preserveDraft: Bool) {
        let keep = preserveDraft && requiresDiscard
        loadedProjectId = nil; loadedPath = ""; version = ""
        conflict = keep && conflict
        if !keep {
            draft = ""; savedText = ""
            originWorkspaceId = ""; originProjectId = ""; originPath = ""
        }
    }

    mutating func discardDraft() {
        loadedProjectId = nil; loadedPath = ""; version = ""; conflict = false
        draft = ""; savedText = ""
        originWorkspaceId = ""; originProjectId = ""; originPath = ""
    }
}
