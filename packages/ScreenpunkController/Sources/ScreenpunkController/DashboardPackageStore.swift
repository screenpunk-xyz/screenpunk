import Darwin
import Foundation
import ScreenpunkCore

struct DashboardReadBudget {
    let deadline: TimeInterval
    let cancelled: () -> Bool
    func check() throws {
        guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else {
            throw ControllerError.validationFailed(detail: "local read cancelled or timed out")
        }
    }
}

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
        try listDashboards(readBudget: nil)
    }

    func listDashboards(readBudget: DashboardReadBudget?) throws -> [DashboardSummary] {
        try withLock(readBudget: readBudget) {
            let dir = dashboardsDir()
            guard fileManager.fileExists(atPath: dir.path) else { return [] }
            let ids = try fileManager.contentsOfDirectory(atPath: dir.path).sorted()
            return try ids.compactMap { id in
                try readBudget?.check()
                let head = try readHead(dashboardId: id, readBudget: readBudget)
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
        let dashboardId = try Self.safeIdentifier(dashboardId, field: "dashboardId")
        return try withLock {
            _ = try readHead(dashboardId: dashboardId)
            return try revisionIDs(dashboardId: dashboardId)
        }
    }

    public func getRevision(dashboardId: String, revision: String?) throws -> DashboardRevisionRecord {
        try getRevision(dashboardId: dashboardId, revision: revision, readBudget: nil)
    }

    func getRevision(dashboardId: String, revision: String?, readBudget: DashboardReadBudget?) throws -> DashboardRevisionRecord {
        let dashboardId = try Self.safeIdentifier(dashboardId, field: "dashboardId")
        let revision = try revision.map { try Self.safeIdentifier($0, field: "revision") }
        return try withLock(readBudget: readBudget) {
            let head = try readHead(dashboardId: dashboardId, readBudget: readBudget)
            let revisionId = revision ?? head.draftRevision
            let packageDir = revisionDir(dashboardId: dashboardId, revision: revisionId)
            let manifestURL = packageDir.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw ControllerError.validationFailed(detail: "revision not found")
            }
            let manifest = try decodeManifest(at: manifestURL, readBudget: readBudget)
            try PackageValidator.validateInventoryBounds(manifest.files)
            var files: [String: Data] = [:]
            for entry in manifest.files {
                try readBudget?.check()
                let path = try PackagePath.normalize(entry.path)
                let url = packageDir.appendingPathComponent(path)
                let bytes = try readRegularFile(at: url, maxBytes: entry.bytes, readBudget: readBudget)
                guard bytes.count == entry.bytes else {
                    throw ControllerError.validationFailed(detail: "package file size mismatch")
                }
                files[path] = bytes
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
        files: [DashboardFileInput],
        pages: [DashboardPage]? = nil,
        defaultPageId: String? = nil,
        eventRules: [ManifestEventRule]? = nil,
        deviceBehavior: DeviceBehavior? = nil
    ) throws -> DashboardRevisionRecord {
        let dashboardId = try dashboardId.map { try Self.safeIdentifier($0, field: "dashboardId") }
        let baseRevision = try baseRevision.map { try Self.safeIdentifier($0, field: "baseRevision") }
        return try withLock {
            if files.isEmpty {
                throw ControllerError.validationFailed(detail: "files required")
            }
            let id = dashboardId ?? UUID().uuidString.lowercased()
            var preservedSettings: Data?
            var previousManifest: DashboardManifest?
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
                previousManifest = try decodeManifest(at: revisionDir(dashboardId: id, revision: existing.draftRevision).appendingPathComponent("manifest.json"))
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
                files: inventory.sorted { $0.path < $1.path },
                pages: pages?.isEmpty == true ? nil : (pages ?? previousManifest?.pages),
                defaultPageId: pages?.isEmpty == true ? nil : (defaultPageId ?? previousManifest?.defaultPageId),
                eventRules: eventRules ?? previousManifest?.eventRules,
                deviceBehavior: deviceBehavior ?? previousManifest?.deviceBehavior
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

    /// Dashboard and revision identifiers become path components under the
    /// controller home. Existing ids are lowercase UUIDs; MCP callers (a
    /// possibly prompt-injected agent) supply them directly, so reject anything
    /// that could escape or point outside the store before it touches disk.
    static func safeIdentifier(_ value: String, field: String) throws -> String {
        guard (1...128).contains(value.count), value != ".", value != "..",
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw ControllerError.validationFailed(detail: "\(field) must be a plain identifier")
        }
        return value
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

    private func readHead(dashboardId: String, readBudget: DashboardReadBudget? = nil) throws -> HeadRecord {
        let url = dashboardDir(dashboardId).appendingPathComponent("head.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ControllerError.validationFailed(detail: "dashboard not found")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HeadRecord.self, from: readRegularFile(at: url, maxBytes: 1_048_576, readBudget: readBudget))
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

    private func decodeManifest(at url: URL, readBudget: DashboardReadBudget? = nil) throws -> DashboardManifest {
        try JSONDecoder().decode(DashboardManifest.self, from: readRegularFile(at: url, maxBytes: 8_388_608, readBudget: readBudget))
    }

    private func getRevisionUnlocked(dashboardId: String, revision: String) throws -> DashboardRevisionRecord {
        let packageDir = revisionDir(dashboardId: dashboardId, revision: revision)
        let manifest = try decodeManifest(at: packageDir.appendingPathComponent("manifest.json"))
        try PackageValidator.validateInventoryBounds(manifest.files)
        var files: [String: Data] = [:]
        for entry in manifest.files {
            let path = try PackagePath.normalize(entry.path)
            files[path] = try readRegularFile(at: packageDir.appendingPathComponent(path), maxBytes: entry.bytes)
        }
        return DashboardRevisionRecord(
            manifest: manifest,
            files: files,
            createdAt: Date(),
            packageDirectory: packageDir
        )
    }

    private func withLock<T>(readBudget: DashboardReadBudget? = nil, _ body: () throws -> T) throws -> T {
        if let readBudget {
            try requireLocalStore()
            while !localLock.try() {
                try readBudget.check()
                Thread.sleep(forTimeInterval: 0.01)
            }
        } else { localLock.lock() }
        defer { localLock.unlock() }
        if let readBudget {
            try flockExclusive(readBudget: readBudget)
        } else { try flockExclusive() }
        defer { flockUnlock() }
        try readBudget?.check()
        return try body()
    }

    private func flockExclusive(readBudget: DashboardReadBudget? = nil) throws {
        guard let fd = lockHandle?.fileDescriptor else { throw ControllerError.validationFailed(detail: "store lock unavailable") }
        if let readBudget {
            while true {
                try readBudget.check()
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    throw ControllerError.validationFailed(detail: "store lock failed")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ControllerError.validationFailed(detail: "store lock failed") }
        }
    }

    private func requireLocalStore() throws {
        var info = statfs()
        guard statfs(root.path, &info) == 0, info.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw ControllerError.validationFailed(detail: "local store required for bounded read")
        }
    }

    private func readRegularFile(at url: URL, maxBytes: Int, readBudget: DashboardReadBudget? = nil) throws -> Data {
        try readBudget?.check()
        guard maxBytes >= 0, maxBytes <= PackageLimits.expandedBytes || maxBytes == 8_388_608 else {
            throw ControllerError.validationFailed(detail: "package file exceeds read bound")
        }
        let fd = try openContainedRegularFile(url)
        defer { close(fd) }
        if readBudget != nil {
            var filesystem = statfs()
            guard fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw ControllerError.validationFailed(detail: "local package file required")
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= maxBytes else {
            throw ControllerError.validationFailed(detail: "invalid package file")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try readBudget?.check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, count <= maxBytes - result.count else {
                throw ControllerError.validationFailed(detail: "package file exceeds read bound")
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == info.st_size else {
            throw ControllerError.validationFailed(detail: "package file changed during read")
        }
        return result
    }

    private func openContainedRegularFile(_ url: URL) throws -> Int32 {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw ControllerError.validationFailed(detail: "package path outside store") }
        let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ControllerError.validationFailed(detail: "invalid package path")
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ControllerError.validationFailed(detail: "store root unavailable") }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ControllerError.validationFailed(detail: "package directory unavailable") }
            close(directory); directory = next
        }
        let fd = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ControllerError.validationFailed(detail: "package file unavailable") }
        return fd
    }

    private func flockUnlock() {
        guard let fd = lockHandle?.fileDescriptor else { return }
        _ = flock(fd, LOCK_UN)
    }
}
