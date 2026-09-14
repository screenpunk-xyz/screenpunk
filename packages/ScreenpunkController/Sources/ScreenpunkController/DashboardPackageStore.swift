import Darwin
import Foundation
import ScreenpunkCore

public final class DashboardPackageStore: @unchecked Sendable {
    public let root: URL
    private let fileManager: FileManager
    private let lockURL: URL
    private var lockHandle: FileHandle?
    private let localLock = NSLock()

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        self.lockURL = root.appendingPathComponent("lock")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: lockURL.path) == false {
            fileManager.createFile(atPath: lockURL.path, contents: Data())
        }
        lockHandle = try FileHandle(forUpdating: lockURL)
    }

    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["SCREENPUNK_CONTROLLER_HOME"], override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("xyz.screenpunk.controller", isDirectory: true)
    }

    public func listDashboards() throws -> [DashboardSummary] {
        try withLock {
            let dir = dashboardsDir()
            guard fileManager.fileExists(atPath: dir.path) else { return [] }
            let ids = try fileManager.contentsOfDirectory(atPath: dir.path).sorted()
            return try ids.compactMap { id in
                let head = try readHead(dashboardId: id)
                let revisions = try revisionIDs(dashboardId: id)
                return DashboardSummary(
                    dashboardId: id,
                    name: head.name,
                    draftRevision: head.draftRevision,
                    revisionCount: revisions.count
                )
            }
        }
    }

    public func listRevisions(dashboardId: String) throws -> [String] {
        try withLock {
            _ = try readHead(dashboardId: dashboardId)
            return try revisionIDs(dashboardId: dashboardId)
        }
    }

    public func getRevision(dashboardId: String, revision: String?) throws -> DashboardRevisionRecord {
        try withLock {
            let head = try readHead(dashboardId: dashboardId)
            let revisionId = revision ?? head.draftRevision
            let packageDir = revisionDir(dashboardId: dashboardId, revision: revisionId)
            let manifestURL = packageDir.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw ControllerError.validationFailed(detail: "revision not found")
            }
            let manifest = try decodeManifest(at: manifestURL)
            var files: [String: Data] = [:]
            for entry in manifest.files {
                let path = try PackagePath.normalize(entry.path)
                files[path] = try Data(contentsOf: packageDir.appendingPathComponent(path))
            }
            return DashboardRevisionRecord(
                manifest: manifest,
                files: files,
                createdAt: head.updatedAt,
                packageDirectory: packageDir
            )
        }
    }

    public func putDashboard(
        dashboardId: String?,
        name: String,
        baseRevision: String?,
        target: ManifestTarget,
        connections: [ManifestConnection],
        files: [DashboardFileInput]
    ) throws -> DashboardRevisionRecord {
        try withLock {
            if files.isEmpty {
                throw ControllerError.validationFailed(detail: "files required")
            }
            let id = dashboardId ?? UUID().uuidString.lowercased()
            var preservedSettings: Data?
            if let existing = try? readHead(dashboardId: id) {
                if let baseRevision, baseRevision != existing.draftRevision {
                    throw ControllerError.revisionConflict(
                        "baseRevision \(baseRevision) does not match draft \(existing.draftRevision)"
                    )
                }
                if baseRevision == nil {
                    throw ControllerError.revisionConflict("baseRevision is required after the first revision")
                }
            }

            if let existing = try? readHead(dashboardId: id) {
                preservedSettings = try? Data(contentsOf: revisionDir(dashboardId: id, revision: existing.draftRevision).appendingPathComponent(ScreenDesignSettings.path))
            }
            var inputs = files
            if let preservedSettings, !inputs.contains(where: { $0.path == ScreenDesignSettings.path }) {
                inputs.append(DashboardFileInput(path: ScreenDesignSettings.path, base64: preservedSettings.base64EncodedString()))
            }
            var assets: [(path: String, data: Data)] = []
            var inventory: [ManifestFile] = []
            var seen = Set<String>()
            for file in inputs {
                let path = try PackagePath.normalize(file.path)
                if seen.contains(path) {
                    throw ControllerError.validationFailed(detail: "duplicate path \(path)")
                }
                seen.insert(path)
                let data = try file.bytes()
                assets.append((path, data))
                inventory.append(
                    ManifestFile(
                        path: path,
                        bytes: data.count,
                        sha256: DeploymentDigest.sha256Hex(data)
                    )
                )
            }

            let settings = try ScreenDesignSettings.read(files: Dictionary(uniqueKeysWithValues: assets.map { ($0.path, $0.data) }))
            guard let orientation = DeviceOrientation(rawValue: target.orientation), settings.orientations.allows(orientation) else {
                throw ControllerError.validationFailed(detail: "The target orientation is not supported by this screen.")
            }
            let revision = UUID().uuidString.lowercased()
            var manifest = DashboardManifest(
                schemaVersion: PackageLimits.schemaMajor,
                dashboardId: id,
                name: name,
                revision: revision,
                entrypoint: inferEntrypoint(from: seen),
                sdkVersion: "1",
                digest: nil,
                target: target,
                connections: connections,
                files: inventory.sorted { $0.path < $1.path }
            )
            try PackageValidator.validate(manifest)
            manifest.digest = try DeploymentDigest.digest(for: manifest)

            let dest = revisionDir(dashboardId: id, revision: revision)
            let staging = dest.appendingPathExtension("staging")
            try? fileManager.removeItem(at: staging)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for asset in assets {
                let url = staging.appendingPathComponent(asset.path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try asset.data.write(to: url, options: .atomic)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            if fileManager.fileExists(atPath: dest.path) {
                throw ControllerError.validationFailed(detail: "revision collision")
            }
            try fileManager.moveItem(at: staging, to: dest)

            let now = Date()
            let head = HeadRecord(name: name, draftRevision: revision, updatedAt: now)
            try writeHead(dashboardId: id, head: head)
            return try getRevisionUnlocked(dashboardId: id, revision: revision)
        }
    }

    /// Remove the library entry; keep deployed device content untouched.
    public func deleteDashboard(dashboardId: String) throws {
        guard UUID(uuidString: dashboardId) != nil else {
            throw ControllerError.validationFailed(detail: "invalid screen identifier")
        }
        try withLock {
            _ = try readHead(dashboardId: dashboardId)
            try fileManager.removeItem(at: dashboardDir(dashboardId))
        }
    }

    private func inferEntrypoint(from paths: Set<String>) -> String {
        if paths.contains("index.html") { return "index.html" }
        return paths.first { $0.hasSuffix(".html") } ?? "index.html"
    }

    private struct HeadRecord: Codable {
        var name: String
        var draftRevision: String
        var updatedAt: Date
    }

    private func dashboardsDir() -> URL {
        root.appendingPathComponent("dashboards", isDirectory: true)
    }

    private func dashboardDir(_ id: String) -> URL {
        dashboardsDir().appendingPathComponent(id, isDirectory: true)
    }

    private func revisionDir(dashboardId: String, revision: String) -> URL {
        dashboardDir(dashboardId).appendingPathComponent("revisions/\(revision)", isDirectory: true)
    }

    private func readHead(dashboardId: String) throws -> HeadRecord {
        let url = dashboardDir(dashboardId).appendingPathComponent("head.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ControllerError.validationFailed(detail: "dashboard not found")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HeadRecord.self, from: Data(contentsOf: url))
    }

    private func writeHead(dashboardId: String, head: HeadRecord) throws {
        let dir = dashboardDir(dashboardId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = dir.appendingPathComponent("head.json")
        let temp = url.appendingPathExtension("tmp")
        try encoder.encode(head).write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temp, to: url)
    }

    private func revisionIDs(dashboardId: String) throws -> [String] {
        let dir = dashboardDir(dashboardId).appendingPathComponent("revisions", isDirectory: true)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: dir.path).filter { !$0.hasSuffix(".staging") }.sorted()
    }

    private func decodeManifest(at url: URL) throws -> DashboardManifest {
        try JSONDecoder().decode(DashboardManifest.self, from: Data(contentsOf: url))
    }

    private func getRevisionUnlocked(dashboardId: String, revision: String) throws -> DashboardRevisionRecord {
        let packageDir = revisionDir(dashboardId: dashboardId, revision: revision)
        let manifest = try decodeManifest(at: packageDir.appendingPathComponent("manifest.json"))
        var files: [String: Data] = [:]
        for entry in manifest.files {
            let path = try PackagePath.normalize(entry.path)
            files[path] = try Data(contentsOf: packageDir.appendingPathComponent(path))
        }
        return DashboardRevisionRecord(
            manifest: manifest,
            files: files,
            createdAt: Date(),
            packageDirectory: packageDir
        )
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        localLock.lock()
        defer { localLock.unlock() }
        flockExclusive()
        defer { flockUnlock() }
        return try body()
    }

    private func flockExclusive() {
        guard let fd = lockHandle?.fileDescriptor else { return }
        _ = flock(fd, LOCK_EX)
    }

    private func flockUnlock() {
        guard let fd = lockHandle?.fileDescriptor else { return }
        _ = flock(fd, LOCK_UN)
    }
}
