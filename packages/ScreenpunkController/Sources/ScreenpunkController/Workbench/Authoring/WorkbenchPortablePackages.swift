import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

public struct WorkbenchPortablePackage: Sendable {
    public let manifest: DashboardManifest
    public let files: [String: Data]
    public let storage = "workspace-history"
    public let provenance = "imported-package-untrusted"
    public let sourceReconstructible = false
    public init(manifest: DashboardManifest, files: [String: Data]) {
        self.manifest = manifest; self.files = files
    }
}

struct WorkbenchPortablePackagePage {
    let manifests: [DashboardManifest]
    let lastObjectId: String?
    let hasMore: Bool
    let inventoryHash: String
}

/// Immutable package importer/reader. Archive parsing belongs to the CLI adapter;
/// this boundary accepts measured bytes, never archive paths or executable claims.
public final class WorkbenchPortablePackages {
    private let workspace: WorkspaceStore
    private let localReadTimeout: TimeInterval
    public init(workspace: WorkspaceStore, localReadTimeout: TimeInterval = 15) {
        self.workspace = workspace; self.localReadTimeout = localReadTimeout
    }

    @discardableResult public func importVerified(_ package: WorkbenchPortablePackage,
        expectedWorkspaceId: String? = nil,
        expectedSelectionGeneration: Int? = nil,
        expectedCatalogGeneration: Int? = nil) throws -> WorkbenchPortablePackage {
        try validate(package)
        let overview = try current()
        guard (expectedWorkspaceId == nil && expectedSelectionGeneration == nil) ||
              (expectedWorkspaceId == overview.descriptor.workspaceId &&
               expectedSelectionGeneration == overview.selectionGeneration) else {
            throw WorkspaceError.conflict
        }
        guard expectedCatalogGeneration == nil ||
              expectedCatalogGeneration == overview.descriptor.generation else {
            throw WorkspaceError.conflict
        }
        let objectId = Self.objectId(package.manifest)
        if let current = try? get(dashboardId: package.manifest.dashboardId, revision: package.manifest.revision) {
            guard current.manifest == package.manifest, current.files == package.files else { throw WorkspaceError.conflict }
            return current
        }
        let manifestBytes = try JSONEncoder().encode(package.manifest)
        var payloads: [String: Data] = ["manifest.json": manifestBytes]
        for (path, bytes) in package.files { payloads["files/" + path] = bytes }
        guard payloads.count <= 2_000 else { throw WorkspaceError.limitExceeded }
        var operations = payloads.keys.sorted().map { path -> WorkbenchTransactionOperation in
            let bytes = payloads[path]!
            return .init(target: .history("package", objectId, path), before: .absent,
                         after: .present(bytes), recoveryBlobHash: WorkbenchTransactionDigest.hex(bytes))
        }
        var blobs: [String: Data] = [:]
        for bytes in payloads.values { blobs[WorkbenchTransactionDigest.hex(bytes)] = bytes }
        let root = try WorkspaceFiles(path: overview.path)
        try WorkbenchHistoryPublicationMetadata.append(to: &operations, blobs: &blobs,
            overview: overview, root: root)
        let journal = WorkbenchTransactionJournal(schemaVersion: 2, transactionId: UUID().uuidString.lowercased(),
            workspaceId: overview.descriptor.workspaceId, kind: .historyPublish,
            expectedGeneration: overview.descriptor.generation, operations: operations)
        let engine = WorkbenchTransactionEngine(selection: workspace.selection)
        try engine.prepare(journal, blobs: blobs)
        try engine.commit(journal.transactionId)
        return try get(dashboardId: package.manifest.dashboardId, revision: package.manifest.revision)
    }

    public func get(dashboardId: String, revision: String, deadline: TimeInterval? = nil,
                    cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchPortablePackage {
        try get(dashboardId: dashboardId, revision: revision,
                budget: readBudget(deadline: deadline, cancelled: cancelled))
    }
    private func get(dashboardId: String, revision: String,
                     budget: WorkspaceReadBudget) throws -> WorkbenchPortablePackage {
        guard WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(revision) else { throw WorkspaceError.invalidPath }
        let overview = try current(budget: budget)
        let root = try WorkspaceFiles(path: overview.path)
        let id = Self.objectId(dashboardId: dashboardId, revision: revision)
        let base = ["Workbench", "History", "Packages", id]
        let folder = try root.directory(base); defer { close(folder) }
        let manifestData = try root.read(folder, "manifest.json", maxBytes: 8 * 1024 * 1024, readBudget: budget)
        let manifest: DashboardManifest
        do { manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestData) }
        catch { throw WorkspaceError.invalidSchema }
        guard manifest.dashboardId == dashboardId, manifest.revision == revision else { throw WorkspaceError.conflict }
        do { try PackageValidator.validateInventoryBounds(manifest.files) }
        catch { throw WorkspaceError.invalidSchema }
        var files: [String: Data] = [:]
        for entry in manifest.files {
            try budget.check()
            guard WorkspaceValidation.member(entry.path) else { throw WorkspaceError.invalidPath }
            let parts = entry.path.split(separator: "/").map(String.init)
            let parent = try root.directory(base + ["files"] + Array(parts.dropLast()))
            defer { close(parent) }
            files[entry.path] = try root.read(parent, parts.last!, maxBytes: min(entry.bytes, 50 * 1024 * 1024), readBudget: budget)
        }
        let package = WorkbenchPortablePackage(manifest: manifest, files: files)
        try validate(package, budget: budget)
        try budget.check()
        return package
    }

    public func list(deadline: TimeInterval? = nil,
                     cancelled: @escaping () -> Bool = { false }) throws -> [DashboardManifest] {
        let budget = readBudget(deadline: deadline, cancelled: cancelled)
        let overview = try current(budget: budget)
        let root = try WorkspaceFiles(path: overview.path)
        let folder = try root.directory(["Workbench", "History", "Packages"]); defer { close(folder) }
        let copy = dup(folder)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var ids: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard ids.count < 100_000, WorkspaceValidation.sha256(name) else { throw WorkspaceError.invalidSchema }
            ids.append(name)
        }
        var manifests: [DashboardManifest] = []
        for id in ids.sorted() {
            try budget.check()
            let item = try root.directory(["Workbench", "History", "Packages", id]); defer { close(item) }
            let bytes = try root.read(item, "manifest.json", readBudget: budget)
            let manifest: DashboardManifest
            do { manifest = try JSONDecoder().decode(DashboardManifest.self, from: bytes) }
            catch { throw WorkspaceError.invalidSchema }
            guard Self.objectId(manifest) == id else { throw WorkspaceError.conflict }
            manifests.append(try get(dashboardId: manifest.dashboardId, revision: manifest.revision, budget: budget).manifest)
        }
        try budget.check()
        return manifests.sorted { ($0.dashboardId, $0.revision) < ($1.dashboardId, $1.revision) }
    }

    /// Scan only bounded directory metadata before selecting a page. Complete
    /// package validation is performed for at most `limit` returned entries.
    func listPage(afterObjectId: String?, expectedInventoryHash: String?, limit: Int = 128,
                  deadline: TimeInterval? = nil,
                  cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchPortablePackagePage {
        guard (1...128).contains(limit), afterObjectId == nil ||
              WorkspaceValidation.sha256(afterObjectId!) else { throw WorkspaceError.invalidSchema }
        let budget = readBudget(deadline: deadline, cancelled: cancelled)
        let overview = try current(budget: budget)
        let root = try WorkspaceFiles(path: overview.path)
        let folder = try root.directory(["Workbench", "History", "Packages"]); defer { close(folder) }
        let copy = dup(folder)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        var ids: [String] = []
        while true {
            try budget.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name == "." || name == ".." { continue }
            guard ids.count < 100_000, WorkspaceValidation.sha256(name) else {
                throw WorkspaceError.invalidSchema
            }
            ids.append(name)
        }
        ids.sort()
        let inventoryHash = WorkbenchTransactionDigest.hex(Data(ids.joined(separator: "\n").utf8))
        guard expectedInventoryHash == nil || expectedInventoryHash == inventoryHash else {
            throw WorkspaceError.conflict
        }
        let start: Int
        if let afterObjectId {
            guard let index = ids.firstIndex(of: afterObjectId) else { throw WorkspaceError.conflict }
            start = index + 1
        } else { start = 0 }
        let end = min(ids.count, start + limit)
        var manifests: [DashboardManifest] = []
        for id in ids[start..<end] {
            try budget.check()
            let item = try root.directory(["Workbench", "History", "Packages", id]); defer { close(item) }
            let bytes = try root.read(item, "manifest.json", readBudget: budget)
            let manifest: DashboardManifest
            do { manifest = try JSONDecoder().decode(DashboardManifest.self, from: bytes) }
            catch { throw WorkspaceError.invalidSchema }
            guard Self.objectId(manifest) == id else { throw WorkspaceError.conflict }
            manifests.append(try get(dashboardId: manifest.dashboardId,
                revision: manifest.revision, budget: budget).manifest)
        }
        try budget.check()
        return .init(manifests: manifests, lastObjectId: end > start ? ids[end - 1] : nil,
            hasMore: end < ids.count, inventoryHash: inventoryHash)
    }

    /// Returns verified bytes to an explicit caller export adapter. It does not
    /// claim the imported package can reconstruct an editable source project.
    public func exportVerified(dashboardId: String, revision: String, deadline: TimeInterval? = nil,
                               cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchPortablePackage {
        try get(dashboardId: dashboardId, revision: revision, deadline: deadline, cancelled: cancelled)
    }

    func validate(_ package: WorkbenchPortablePackage, budget: WorkspaceReadBudget? = nil) throws {
        try budget?.check()
        let manifest = package.manifest
        do { try PackageValidator.validate(manifest) }
        catch { throw WorkspaceError.invalidSchema }
        guard let digest = manifest.digest, digest == (try DeploymentDigest.digest(for: manifest)),
              manifest.files.count == package.files.count, manifest.files.count < 2_000 else {
            throw WorkspaceError.conflict
        }
        var collisions = WorkspacePathCollisionDetector()
        var total = 0
        for file in manifest.files {
            try budget?.check()
            guard WorkspaceValidation.member(file.path),
                  let bytes = package.files[file.path], bytes.count == file.bytes,
                  WorkbenchTransactionDigest.hex(bytes) == file.sha256,
                  bytes.count <= PackageLimits.expandedBytes - total else { throw WorkspaceError.invalidSchema }
            try collisions.insert(file.path)
            total += bytes.count
        }
        guard Set(package.files.keys) == Set(manifest.files.map(\.path)) else { throw WorkspaceError.invalidSchema }
        let manifestSize = try JSONEncoder().encode(manifest).count
        guard total + manifestSize <= 50 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        try budget?.check()
    }
    private func current() throws -> WorkspaceOverview {
        try current(budget: readBudget(deadline: nil, cancelled: { false }))
    }
    private func current(budget: WorkspaceReadBudget) throws -> WorkspaceOverview {
        guard let value = try workspace.current(readBudget: budget) else { throw WorkspaceError.unavailable }
        return value
    }
    private func readBudget(deadline: TimeInterval?, cancelled: @escaping () -> Bool) -> WorkspaceReadBudget {
        WorkspaceReadBudget(deadline: min(deadline ?? .infinity, ProcessInfo.processInfo.systemUptime + localReadTimeout),
                            cancelled: cancelled)
    }
    private static func objectId(_ manifest: DashboardManifest) -> String {
        objectId(dashboardId: manifest.dashboardId, revision: manifest.revision)
    }
    private static func objectId(dashboardId: String, revision: String) -> String {
        WorkbenchTransactionDigest.hex(Data((dashboardId + "\0" + revision).utf8))
    }
}
#endif
