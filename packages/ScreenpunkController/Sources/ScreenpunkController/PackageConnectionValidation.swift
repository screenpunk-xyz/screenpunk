import Foundation
import Darwin
import ScreenpunkCore

/// App-owned validation-only process. Never launches workspace scripts, system
/// Node, or an installed authoring kit. Package bytes are a frozen JSON request.
enum PackageConnectionValidation {
    private static let admission = NSLock()
    private static var active = 0
    static func validate(files: [String: Data], connections: [ManifestConnection],
                         root explicitRoot: URL? = nil,
                         cancelled: () -> Bool = { false }) throws {
        let extensions: Set<String> = ["js", "mjs", "cjs", "html", "htm"]
        let selected = files.filter { extensions.contains(URL(fileURLWithPath: $0.key).pathExtension.lowercased()) }
        guard !selected.isEmpty else { return }
        guard selected.count <= 2000, selected.values.reduce(0, { $0 + $1.count }) <= 5 * 1024 * 1024 else {
            throw failure("Connection validation supports at most 5 MiB of JavaScript and HTML.")
        }
        admission.lock()
        guard active < 2 else { admission.unlock(); throw failure("Connection validation is busy; preserve source and retry the same build.") }
        active += 1; admission.unlock()
        defer { admission.lock(); active -= 1; admission.unlock() }
        guard !cancelled() else { throw failure("Connection validation cancelled; previous package kept.") }
        let candidates = explicitRoot.map { [$0] } ?? [
            Bundle.module.resourceURL?.appendingPathComponent("ConnectionValidator"),
            Bundle.main.resourceURL?.appendingPathComponent("ConnectionValidator"),
            Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/ConnectionValidator")
        ].compactMap { $0 }
        guard let selectedRoot = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("validate.cjs").path) }) else {
            throw failure("App-owned connection validator is unavailable. Repair the Screenpunk application; no authoring kit is required. Previous package kept.")
        }
        let root = selectedRoot.resolvingSymlinksInPath()
        let node = root.appendingPathComponent("node"), script = root.appendingPathComponent("validate.cjs")
        for url in [node, script] {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("Invalid app-owned connection validator.") }
        }
        let work = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("screenpunk-connection-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        struct File: Encodable { let path: String; let text: String }
        struct Request: Encodable { let files: [File]; let connections: [ManifestConnection] }
        let captured = try selected.keys.sorted().map { path -> File in
            guard let text = String(data: selected[path]!, encoding: .utf8) else { throw failure("Executable package content must be valid UTF-8.") }
            return File(path: path, text: text)
        }
        let input = work.appendingPathComponent("request.json"), output = work.appendingPathComponent("result.json")
        try JSONEncoder().encode(Request(files: captured, connections: connections)).write(to: input, options: .atomic)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = node
        let inputPath = try physicalPath(input.path), helperPath = try physicalPath(root.path)
        process.arguments = ["--jitless", "--max-old-space-size=256", "--stack-size=1024", "--permission", "--allow-fs-read=" + inputPath, "--allow-fs-read=" + helperPath, helperPath + "/validate.cjs", inputPath]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": work.path, "TMPDIR": work.path]
        process.currentDirectoryURL = work
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && !cancelled() && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            let stop = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stop { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else { throw failure("Connection validation cancelled or timed out; previous package kept.") }
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 else { throw failure("Connection validation exceeded diagnostic limits.") }
        struct Reply: Decodable { let ok: Bool; let message: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(contentsOf: output)) else { throw failure("Connection validation could not complete within parser limits; simplify source and rebuild.") }
        guard reply.ok, process.terminationStatus == 0 else { throw failure(String((reply.message ?? "Connection validation failed.").prefix(4096))) }
    }
    private static func physicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw failure("Validator path is unavailable.") }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private static func failure(_ message: String) -> ControllerError { .validationFailed(detail: message) }
}
