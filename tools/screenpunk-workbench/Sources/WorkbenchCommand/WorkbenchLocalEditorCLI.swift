import Foundation
import Darwin
import ScreenpunkController

/// Edits a private draft, then submits one source-version-checked broker patch.
/// The visible project is never handed to an editor for direct mutation.
enum WorkbenchLocalEditorCLI {
    static func run(projectId: String, path: String, selected: WorkbenchWorkspaceStatus,
                    client: WorkbenchBrokerClient, presentation: Presentation,
                    environment: [String: String],
                    edit: ((URL) throws -> Void)? = nil,
                    temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        guard selected.state == "selected", let workspacePath = selected.path,
              let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration,
              WorkspaceValidation.id(projectId), WorkspaceValidation.member(path),
              path != "screenpunk.project.json", path != "screenpunk.lock.json" else {
            throw Options.usage("project edit-local requires a selected contained project and source path.")
        }
        let project = try client.getProject(projectId)
        guard project.location.kind == "workspace", let relative = project.location.path,
              relative.hasPrefix("Screens/") else { throw WorkbenchIPCError(.invalidWorkspacePath) }
        let inspected = try client.performAuthoring(method: .projectInspect, params: [
            "schemaVersion": 1, "projectId": projectId,
            "expectedWorkspaceId": workspaceId,
            "expectedSelectionGeneration": generation])
        guard let sourceVersion = inspected.project?.sourceVersion else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let original = try readFile(workspacePath + "/" + relative + "/" + path)
        let draftFolder = temporaryRoot.appendingPathComponent("screenpunk-edit-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: draftFolder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let draft = draftFolder.appendingPathComponent(String(path.split(separator: "/").last!))
        let fd = Darwin.open(draft.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkbenchIPCError(.unavailable) }
        do { try write(fd, original) }
        catch { Darwin.close(fd); throw error }
        Darwin.close(fd)
        var submissionStarted = false
        var patchConfirmed = false
        do {
            if let edit { try edit(draft) }
            else { try launchEditor(draft, environment: environment) }
            let route = try WorkbenchAuthoringRecoveryCLI.route([
                "project", "edit", projectId, sourceVersion, path, draft.path])
            guard let route else { throw WorkbenchIPCError(.invalidRequest) }
            var params = route.params
            params["expectedWorkspaceId"] = workspaceId
            params["expectedSelectionGeneration"] = generation
            submissionStarted = true
            let result = try client.performAuthoring(method: .projectPatch, params: params)
            patchConfirmed = true
            try WorkbenchAuthoringRecoveryCLI.present(result, for: .projectPatch,
                with: presentation, checkedOutput: true)
            try? FileManager.default.removeItem(at: draftFolder)
        } catch {
            let code = patchConfirmed ? "edit_applied_display_failed" :
                (submissionStarted ? "edit_outcome_unknown" : "edit_not_submitted")
            let explanation = patchConfirmed ? "The patch was confirmed, but its result could not be displayed." :
                (submissionStarted ? "The patch was submitted, but its outcome is unknown. Check the current source version before any retry." :
                    "The patch was not submitted.")
            throw CommandFailure(code,
                "The editor draft was kept at \(draft.path). \(explanation) \(error)",
                6, nextActions: ["Inspect the project and current source version before deciding whether to use the saved draft."],
                details: ["draftPath": draft.path])
        }
    }

    private static func launchEditor(_ draft: URL, environment: [String: String]) throws {
        let process = Process()
        if let editor = environment["SCREENPUNK_EDITOR"] {
            guard WorkspaceValidation.absolute(editor),
                  FileManager.default.isExecutableFile(atPath: editor) else {
                throw Options.usage("SCREENPUNK_EDITOR must be one absolute executable path; shell commands are not accepted.")
            }
            process.executableURL = URL(fileURLWithPath: editor)
            process.arguments = [draft.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-W", "-e", draft.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WorkbenchIPCError(.unavailable)
        }
    }

    private static func readFile(_ path: String) throws -> Data {
        guard WorkspaceValidation.absolute(path) else { throw WorkbenchIPCError(.invalidWorkspacePath) }
        let parts = path.split(separator: "/").map(String.init)
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw WorkbenchIPCError(.unavailable) }
        defer { Darwin.close(current) }
        for (index, part) in parts.enumerated() {
            guard part != ".", part != ".." else { throw WorkbenchIPCError(.invalidWorkspacePath) }
            let final = index == parts.count - 1
            let next = Darwin.openat(current, part,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (final ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw WorkbenchIPCError(.invalidWorkspacePath) }
            Darwin.close(current); current = next
        }
        var before = stat()
        guard fstat(current, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              (0...Int64(5 * 1024 * 1024)).contains(before.st_size) else {
            throw WorkbenchIPCError(.resourceLimit)
        }
        var data = Data(); var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= 5 * 1024 * 1024 {
            let limit = min(chunk.count, 5 * 1024 * 1024 + 1 - data.count)
            let count = Darwin.read(current, &chunk, limit)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorkbenchIPCError(.unavailable) }
            if count == 0 { break }
            data.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard fstat(current, &after) == 0, data.count == before.st_size,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        return data
    }

    private static func write(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkbenchIPCError(.unavailable) }
                offset += count
            }
        }
    }
}
