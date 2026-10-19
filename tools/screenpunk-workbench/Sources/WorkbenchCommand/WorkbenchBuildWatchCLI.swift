import Foundation
import ScreenpunkController

/// A content version must remain observed for 300 ms before one build is
/// submitted. Repeated notifications or scans of the same version coalesce.
struct WorkbenchBuildWatchDebouncer {
    private(set) var candidate: String?
    private(set) var candidateSince: TimeInterval = 0
    private(set) var attempted: String?

    mutating func observe(_ version: String, at now: TimeInterval) -> String? {
        if candidate != version {
            candidate = version; candidateSince = now
            return nil
        }
        guard now - candidateSince >= 0.3, attempted != version else { return nil }
        attempted = version
        return version
    }
}

enum WorkbenchBuildWatchCLI {
    static func projectId(_ words: [String]) throws -> String? {
        if words.count == 3, words[0] == "build", words[1] == "--watch" {
            return words[2]
        }
        if words.count == 4, words[0] == "build", words[1] == "run",
           words[3] == "--watch" { return words[2] }
        if words.first == "build", words.contains("--watch") {
            throw Options.usage("build --watch requires PROJECT_ID (or build run PROJECT_ID --watch).")
        }
        return nil
    }

    static func run(projectId: String, selected: WorkbenchWorkspaceStatus,
                    client: WorkbenchBrokerClient, presentation: Presentation,
                    cancelled: () -> Bool,
                    onEvent: (([String: Any]) -> Void)? = nil) throws {
        guard WorkspaceValidation.id(projectId), let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw Options.usage("build --watch requires a registered project and selected workspace.")
        }
        var debounce = WorkbenchBuildWatchDebouncer()
        while !cancelled() {
            _ = try client.reconnectIfPeerClosed()
            let observed: WorkbenchAuthoringRecoveryResult
            do {
                observed = try client.performAuthoring(method: .projectInspect,
                    params: ["schemaVersion": 1, "projectId": projectId,
                             "expectedWorkspaceId": workspaceId,
                             "expectedSelectionGeneration": generation])
            } catch let error as WorkbenchIPCError where
                [.disconnected, .timedOut, .instanceMismatch].contains(error.code) {
                throw CommandFailure("watch_disconnected",
                    "The build watcher lost its broker connection.", 7,
                    nextActions: ["Inspect the selected workspace and build head before starting a new watcher."],
                    details: ["projectId": projectId])
            }
            guard let project = observed.project else { throw WorkbenchIPCError(.invalidRequest) }
            if let version = debounce.observe(project.sourceVersion,
                at: ProcessInfo.processInfo.systemUptime) {
                try build(projectId: projectId, sourceVersion: version,
                    workspaceId: workspaceId, generation: generation,
                    client: client, presentation: presentation, onEvent: onEvent)
            }
            if !cancelled() { Thread.sleep(forTimeInterval: 0.3) }
        }
    }

    private static func build(projectId: String, sourceVersion: String,
                              workspaceId: String, generation: Int,
                              client: WorkbenchBrokerClient,
                              presentation: Presentation,
                              onEvent: (([String: Any]) -> Void)?) throws {
        let common: [String: Any] = ["schemaVersion": 1, "projectId": projectId,
            "expectedWorkspaceId": workspaceId, "expectedSelectionGeneration": generation]
        let base: String?
        do {
            base = try client.performAuthoring(method: .buildHead, params: common).build?.revision
        } catch let error as WorkbenchIPCError where error.code == .unavailable {
            base = nil // No prior package head exists for this project.
            _ = try client.reconnectIfPeerClosed()
        }
        var params = common
        params["expectedSourceVersion"] = sourceVersion
        if let base { params["baseRevision"] = base }
        do {
            let result = try client.performAuthoring(method: .buildRun, params: params)
            guard let built = result.build else { throw WorkbenchIPCError(.invalidRequest) }
            let event: [String: Any] = [
                "kind": "buildWatchEvent", "state": "built", "projectId": projectId,
                "sourceVersion": sourceVersion, "revision": built.revision,
                "digest": built.digest, "deployment": "not_requested"]
            do {
                try presentation.checkedSuccess(event,
                    human: "Built \(projectId) source \(sourceVersion) as \(built.revision).")
            } catch {
                throw CommandFailure("build_applied_display_failed",
                    "The watched build completed, but its result could not be displayed.", 6,
                    nextActions: ["Inspect build head before another build."],
                    details: ["projectId": projectId, "sourceVersion": sourceVersion,
                              "revision": built.revision])
            }
            onEvent?(event)
        } catch let error as WorkbenchIPCError where
            [.disconnected, .timedOut, .unavailable].contains(error.code) {
            throw CommandFailure("outcome_unknown",
                "The watched build lost its broker reply; a new immutable package may have been published.", 7,
                nextActions: ["Inspect build head and retained history before another build."],
                details: ["projectId": projectId, "sourceVersion": sourceVersion])
        } catch let failure as CommandFailure { throw failure }
        catch {
            let code = (error as? WorkbenchIPCError)?.code.rawValue ?? "build_failed"
            let event: [String: Any] = [
                "kind": "buildWatchEvent", "state": "failed", "projectId": projectId,
                "sourceVersion": sourceVersion, "code": code,
                "priorPackage": "unchanged", "deployment": "not_requested"]
            try presentation.checkedSuccess(event,
                human: "Build for \(projectId) source \(sourceVersion) failed (\(code)); package head unchanged.")
            onEvent?(event)
        }
    }
}
