import Foundation
import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Source projects are local authoring records, never device packages.
public final class ScreenAuthoring: @unchecked Sendable {
    public let root: URL
    private let bundledKit: URL?
    private let buildTimeoutSeconds: TimeInterval
    private let fm = FileManager.default
    public init(root: URL, kit: URL? = nil, buildTimeoutSeconds: TimeInterval = 120) {
        self.buildTimeoutSeconds = buildTimeoutSeconds
        self.root = root.resolvingSymlinksInPath().appendingPathComponent("authoring", isDirectory: true)
        let env = ProcessInfo.processInfo.environment["SCREENPUNK_AUTHORING_KIT"].map { URL(fileURLWithPath: $0) }
        let app = Bundle.main.resourceURL?.appendingPathComponent("AuthoringKit")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AuthoringKit")
        bundledKit = kit ?? env ?? [app, executable].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("kit.json").path) }
    }
    private func fail(_ message: String) -> ControllerError { .validationFailed(detail: message) }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("authoring.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw fail("Cannot lock authoring store") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw fail("Cannot lock authoring store") }
        return try body()
    }
    private func json(_ url: URL) throws -> JSONValue { try JSONValue.parse(Data(contentsOf: url)) }
    private func write(_ value: JSONValue, _ url: URL) throws { try value.data().write(to: url, options: .atomic) }
    private func identifier(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 100, id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, id != ".", id != ".." else { throw fail("Invalid authoring identifier") }
        return id
    }
    private func directory(_ id: String) throws -> URL { root.appendingPathComponent("projects/\(try identifier(id))") }
    private func kit(_ version: String? = nil) throws -> URL {
        if let version {
            let cached = root.appendingPathComponent("kits/\(try identifier(version))")
            if fm.fileExists(atPath: cached.appendingPathComponent("kit.json").path) { return cached }
        }
        guard let bundledKit else { throw fail("Authoring kit missing. Install a Mac build that includes AuthoringKit.") }
        let metadata = try json(bundledKit.appendingPathComponent("kit.json"))
        guard let installedVersion = metadata["version"]?.string, version == nil || version == installedVersion else { throw fail("Required authoring kit \(version ?? "unknown") is unavailable; no automatic upgrade was performed") }
        let cached = root.appendingPathComponent("kits/\(try identifier(installedVersion))")
        if !fm.fileExists(atPath: cached.path) {
            try fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stage = cached.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            try fm.copyItem(at: bundledKit, to: stage)
            try fm.moveItem(at: stage, to: cached)
        }
        return cached
    }
    public func resource(_ name: String) throws -> String {
        try locked { let base = try kit(); return try String(contentsOf: base.appendingPathComponent(name == "catalog" ? "catalog.json" : "README.md"), encoding: .utf8) }
    }
    private func files(_ source: URL) throws -> [String: Data] {
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw fail("Source directory must not be a symlink") }
        let source = source.resolvingSymlinksInPath()
        var result: [String: Data] = [:]; var total = 0
        func visit(_ dir: URL) throws {
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey], options: []) {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw fail("Source symlinks are not supported") }
                if file.lastPathComponent.hasPrefix(".") { continue }
                if values.isDirectory == true { try visit(file); continue }
                guard values.isRegularFile == true else { throw fail("Only regular source files are supported") }
                let relative = file.standardizedFileURL.pathComponents.dropFirst(source.standardizedFileURL.pathComponents.count).joined(separator: "/")
                _ = try sourcePath(relative)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5 * 1024 * 1024, total + size <= 25 * 1024 * 1024, result.count < 2000 else { throw fail("Source size limit exceeded") }
                let data = try Data(contentsOf: file); total += data.count; result[relative] = data
            }
        }
        try visit(source); return result
    }
    private func sourcePath(_ value: String) throws -> String {
        let normalized: String
        do { normalized = try PackagePath.normalize(value) } catch { throw fail("Invalid source path: \(value)") }
        guard normalized == value, !value.isEmpty, value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
              !value.split(separator: "/").contains("node_modules"), !value.split(separator: "/").contains("dist"),
              ["tsx", "ts", "css", "json", "svg", "png", "jpg", "jpeg", "woff", "woff2"].contains(URL(fileURLWithPath: value).pathExtension) else { throw fail("Unsupported source path: \(value)") }
        return value
    }
    private func version(_ files: [String: Data]) -> String {
        let entries = files.keys.sorted().map { "\($0):\(DeploymentDigest.sha256Hex(files[$0]!))" }.joined(separator: "\n")
        return DeploymentDigest.sha256Hex(Data(entries.utf8))
    }
    private func result(_ id: String, include: [String] = []) throws -> JSONValue {
        let dir = try directory(id); let source = dir.appendingPathComponent("source")
        let assets = try files(source); var metadata = try json(dir.appendingPathComponent("project.json")).object ?? [:]
        metadata["projectId"] = .string(id); metadata["sourceLocation"] = .string(source.path); metadata["sourceVersion"] = .string(version(assets))
        metadata["inventory"] = .array(assets.keys.sorted().map { .object(["path": .string($0), "bytes": .int(assets[$0]!.count)]) })
        metadata["files"] = .array(try include.map { name in
            _ = try sourcePath(name); guard let data = assets[name] else { throw fail("Source file not found: \(name)") }
            return .object(["path": .string(name), "base64": .string(data.base64EncodedString())])
        })
        return .object(metadata)
    }
    public func create(starter: String, catalogVersion: String? = nil) throws -> JSONValue {
        try locked {
            guard ["earthquakes", "gallery"].contains(starter) else { throw fail("Unknown starter") }
            let base = try kit(catalogVersion); let version = try json(base.appendingPathComponent("kit.json"))["version"]?.string ?? ""
            let id = UUID().uuidString.lowercased(); let dir = try directory(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: base.appendingPathComponent("templates/\(starter)"), to: dir.appendingPathComponent("source"))
            try write(.object(["kitVersion": .string(version), "starter": .string(starter), "dashboardId": .string(UUID().uuidString.lowercased())]), dir.appendingPathComponent("project.json"))
            return try result(id)
        }
    }
    public func get(id: String, paths: [String] = []) throws -> JSONValue { try locked { try result(id, include: paths) } }
    public func update(id: String, expected: String, edits: [JSONValue]) throws -> JSONValue {
        try locked {
            let dir = try directory(id), source = dir.appendingPathComponent("source")
            var assets = try files(source)
            guard version(assets) == expected else { throw ControllerError.revisionConflict("Source changed; read the project again") }
            var seen = Set<String>()
            for edit in edits {
                let name = try sourcePath(edit["path"]?.string ?? "")
                guard seen.insert(name).inserted else { throw fail("Duplicate source edit") }
                if edit["delete"]?.bool == true { assets.removeValue(forKey: name) }
                else if let text = edit["text"]?.string { assets[name] = Data(text.utf8) }
                else if let encoded = edit["base64"]?.string, let data = Data(base64Encoded: encoded) { assets[name] = data }
                else { throw fail("Source edit requires text, base64, or delete") }
            }
            guard assets.count <= 2000, assets.values.reduce(0, { $0 + $1.count }) <= 25 * 1024 * 1024 else { throw fail("Source size limit exceeded") }
            let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: stage) }
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            for (name, data) in assets { let out = stage.appendingPathComponent(name); try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: out) }
            _ = try files(stage)
            // Same-volume replacement retains the old source until replacement succeeds.
            _ = try fm.replaceItemAt(source, withItemAt: stage)
            return try result(id)
        }
    }
    public func build(id: String, expected: String, baseRevision: String?, service: ControllerService) throws -> JSONValue {
        try locked {
            let dir = try directory(id); let metadata = try json(dir.appendingPathComponent("project.json"))
            let assets = try files(dir.appendingPathComponent("source"))
            guard version(assets) == expected else { throw ControllerError.revisionConflict("Source changed; read the project again") }
            let base = try kit(metadata["kitVersion"]?.string)
            let work = root.appendingPathComponent("builds/\(UUID().uuidString)")
            defer { try? fm.removeItem(at: work) }
            let snapshot = work.appendingPathComponent("source"), output = work.appendingPathComponent("output")
            for (name, data) in assets { let out = snapshot.appendingPathComponent(name); try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: out) }
            let config = try json(snapshot.appendingPathComponent("screen.json"))
            let log = work.appendingPathComponent("build.log"); fm.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            let process = Process(); process.executableURL = base.appendingPathComponent("bin/node")
            process.arguments = ["--jitless", base.appendingPathComponent("scripts/build.mjs").path, snapshot.path, output.path]
            process.currentDirectoryURL = base
            process.environment = ["PATH": base.appendingPathComponent("bin").path, "HOME": work.path, "TMPDIR": work.path, "NODE_ENV": "production"]
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            let deadline = Date().addingTimeInterval(buildTimeoutSeconds)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                let stopDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw fail("Build timed out; previous revision kept")
            }
            process.waitUntilExit()
            let diagnosticData = try Data(contentsOf: log)
            let diagnostics = String(decoding: diagnosticData.suffix(32 * 1024), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw fail("Build failed; previous revision kept.\n\(diagnostics)") }
            // External editors may change source while the immutable snapshot compiles.
            guard version(try files(dir.appendingPathComponent("source"))) == expected else { throw ControllerError.revisionConflict("Source changed during build; output was not saved") }
            let enumerator = fm.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
            var inputs: [JSONValue] = []
            while let file = enumerator.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw fail("Build output contains a symlink") }
                if values.isRegularFile == true { inputs.append(.object(["path": .string(file.resolvingSymlinksInPath().pathComponents.dropFirst(output.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")), "base64": .string(try Data(contentsOf: file).base64EncodedString())])) }
            }
            var arguments = (config.object ?? [:]).filter { ["name", "target", "connections", "pages", "defaultPageId", "eventRules"].contains($0.key) }
            arguments["dashboardId"] = metadata["dashboardId"]; arguments["files"] = .array(inputs)
            if let baseRevision { arguments["baseRevision"] = .string(baseRevision) }
            let record = try service.updateDashboard(arguments: .object(arguments))
            return .object(["projectId": .string(id), "sourceVersion": .string(expected), "dashboardId": .string(record.manifest.dashboardId), "revision": .string(record.manifest.revision), "digest": .string(record.manifest.digest ?? ""), "bytes": .int(record.manifest.files.reduce(0, { $0 + $1.bytes })), "diagnostics": .string(diagnostics)])
        }
    }
    public func project(for dashboardId: String) throws -> JSONValue? {
        try locked {
            let projects = root.appendingPathComponent("projects")
            guard fm.fileExists(atPath: projects.path) else { return nil }
            for dir in try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                if try json(dir.appendingPathComponent("project.json"))["dashboardId"]?.string == dashboardId { return try result(dir.lastPathComponent) }
            }
            return nil
        }
    }
}
