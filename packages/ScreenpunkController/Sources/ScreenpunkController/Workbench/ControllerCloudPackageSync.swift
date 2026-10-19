import Foundation
import ScreenpunkCore
#if os(macOS)
import CryptoKit
/// Package versions are immutable additions. They never overwrite source or select a device.
/// A durable mapping owns fresh local identities and suppresses upload/import echoes.
struct ControllerCloudPackageSync {
    let root: URL
    let session: ControllerCloudSession
    let client: WorkbenchBrokerClient
    let accountId: String
    let workspaceId: String
    let localWorkspaceId: String
    struct Package: Codable, Sendable {
        let packageId: String
        let projectId: String
        let sourceVersionId: String?
        let packageDigest: String
        let manifestSha256: String
        let archiveSha256: String
        let archiveBytes: Int
        let manifest: DashboardManifest
    }
    private struct Page: Decodable, Sendable { let items: [Package]; let nextCursor: String? }
    private struct Journal: Codable {
        var binding: ControllerCloudProjectBinding
        let dashboardId: String
        let outbound: Bool
        let creationName: String
        var hasLocalCopy: Bool = false
        var creationPending: Bool
        var retiredForSource: Bool? = nil
        var uploadedDigests: Set<String> = []
        var imported: [String: String] = [:]
        var pendingArchiveSha256: String?
        var pendingPackageDigest: String?
    }
    private func directory() throws -> URL {
        let value = root.appendingPathComponent("projects/\(localWorkspaceId)/packages/\(accountId.sha256Scope)/\(workspaceId)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return value
    }
    private func save(_ value: Journal) throws {
        let file = try directory().appendingPathComponent(value.binding.cloudProjectId + ".json")
        try ControllerCloudPersistence.write(JSONEncoder().encode(value), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func journals() throws -> [Journal] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(Journal.self, from: Data(contentsOf: $0))
        }
    }
    func bindings() throws -> [ControllerCloudProjectBinding] { try journals().filter { $0.retiredForSource != true }.map(\.binding) }
    /// Existing package content or an interrupted measured import already owns this Screen.
    /// An old empty placeholder does not prevent a genuine source import.
    func discoveryBindings() throws -> [ControllerCloudProjectBinding] {
        let directory = root.appendingPathComponent("projects/\(localWorkspaceId)/packages")
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [ControllerCloudProjectBinding] = []
        for case let file as URL in files where file.pathExtension == "json" {
            guard result.count < 4_096 else { throw ControllerCloudError.sourceLimitExceeded }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            if journal.outbound || journal.hasLocalCopy || !journal.imported.isEmpty { result.append(journal.binding) }
        }
        return result
    }
    func markUnavailable(cloudProjectIds: Set<String>) throws {
        for var row in try journals() where cloudProjectIds.contains(row.binding.cloudProjectId) && row.binding.status != .deleted {
            row.binding.status = .unavailable; try save(row)
        }
    }
    private func prefix(_ project: String) throws -> String {
        guard UUID(uuidString: project) != nil, UUID(uuidString: workspaceId) != nil else { throw ControllerCloudError.invalidSource }
        return "/controller/v1/workspaces/\(workspaceId)/projects/\(project)"
    }
    private func packages(_ project: String) async throws -> [Package] {
        var values: [Package] = [], cursor: String?, seen = Set<String>()
        repeat {
            let suffix = cursor.map { "?cursor=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! } ?? ""
            let page = try await session.request(try prefix(project) + "/packages" + suffix, as: Page.self)
            guard values.count + page.items.count <= 4_096 else { throw ControllerCloudError.sourceLimitExceeded }
            for package in page.items {
                guard package.projectId == project, UUID(uuidString: package.packageId) != nil,
                      package.manifest.digest == package.packageDigest,
                      try DeploymentDigest.digest(for: package.manifest) == package.packageDigest else { throw ControllerCloudError.invalidResponse }
                try PackageValidator.validate(package.manifest)
            }
            values += page.items; cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw ControllerCloudError.invalidResponse }
        } while cursor != nil
        return values
    }
    /// Missing/archived local copies remain suppressed, and Cloud deletion is terminal.
    /// Both sides retain immutable versions; no remote deletion is inferred from local removal.
    func synchronize(cloud: [ControllerCloudProject], sourceBindings: [ControllerCloudProjectBinding], sourceDashboardIds: Set<String>, cloudProjectIds: Set<String>? = nil, localDashboardIds: Set<String>? = nil) async throws {
        let selected = try client.workspaceStatus()
        guard selected.workspaceId == localWorkspaceId else { throw ControllerCloudError.accountMismatch }
        let visible = try client.listWorkspacePackages(in: selected)
        var records = try journals()
        let allRecordsRoot = root.appendingPathComponent("projects/\(localWorkspaceId)/packages")
        var allRecords: [Journal] = []
        if let files = FileManager.default.enumerator(at: allRecordsRoot, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "json" {
                guard allRecords.count < 4_096 else { throw ControllerCloudError.sourceLimitExceeded }
                allRecords.append(try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file)))
            }
        }
        let knownDashboards = Set(allRecords.map(\.dashboardId))
        for dashboard in Set(visible.map(\.dashboardId)).subtracting(sourceDashboardIds).subtracting(knownDashboards).sorted() where localDashboardIds == nil || localDashboardIds!.contains(dashboard) {
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            guard let item = visible.first(where: { $0.dashboardId == dashboard }) else { continue }
            let id = UUID().uuidString.lowercased()
            let binding = ControllerCloudProjectBinding(accountId: accountId, workspaceId: workspaceId,
                localProjectId: dashboard, cloudProjectId: id, status: .linked)
            let record = Journal(binding: binding, dashboardId: dashboard, outbound: true, creationName: item.name, creationPending: true)
            try save(record); records.append(record)
        }
        let knownCloud = Set((allRecords + records).filter { $0.binding.workspaceId == workspaceId }.map { $0.binding.cloudProjectId }).union(sourceBindings.filter { $0.workspaceId == workspaceId }.map(\.cloudProjectId))
        var prefetched: [String: [Package]] = [:]
        for project in cloud where !knownCloud.contains(project.id) && (project.sourceKind == "imported" || project.headVersionId == nil) {
            guard UUID(uuidString: project.id) != nil else { throw ControllerCloudError.invalidResponse }
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            let actual: [Package]
            do { actual = try await packages(project.id) }
            catch ControllerCloudError.http(404) { continue }
            guard !actual.isEmpty else { continue }
            prefetched[project.id] = actual
            let dashboard = UUID().uuidString.lowercased()
            let record = Journal(binding: .init(accountId: accountId, workspaceId: workspaceId, localProjectId: dashboard,
                cloudProjectId: project.id, status: .linked), dashboardId: dashboard, outbound: false, creationName: project.name, creationPending: false)
            try save(record); records.append(record)
        }
        for var record in records where record.binding.status != .deleted && record.retiredForSource != true {
            if cloudProjectIds != nil && !cloudProjectIds!.contains(record.binding.cloudProjectId) && localDashboardIds?.contains(record.dashboardId) != true { continue }
            // A reset can have no upserts. Re-admission still requires fresh project metadata
            // from the current authoritative listing, followed by exact package metadata below.
            if record.binding.status == .unavailable && !cloud.contains(where: { $0.id == record.binding.cloudProjectId }) { continue }
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            if sourceBindings.contains(where: { $0.workspaceId == record.binding.workspaceId && $0.cloudProjectId == record.binding.cloudProjectId }) {
                // Keep any historical local content and identity journal, but never continue a
                // second import stream after the source owner has claimed this Cloud Screen.
                record.retiredForSource = true; try save(record); continue
            }
            let local = visible.filter { $0.dashboardId == record.dashboardId }
            if local.isEmpty && (record.outbound || record.hasLocalCopy) { continue }
            if record.creationPending {
                struct Created: Decodable, Sendable { let id: String }
                let name = record.creationName
                let body = try JSONSerialization.data(withJSONObject: ["projectId": record.binding.cloudProjectId,
                    "name": name, "sourceKind": "imported", "idempotencyKey": record.binding.cloudProjectId])
                let created = try await session.request("/controller/v1/workspaces/\(workspaceId)/projects", method: "POST", body: body, as: Created.self)
                guard created.id == record.binding.cloudProjectId else { throw ControllerCloudError.invalidResponse }
                record.creationPending = false; try save(record)
            }
            let remote: [Package]
            do {
                if let cached = prefetched[record.binding.cloudProjectId] { remote = cached }
                else { remote = try await packages(record.binding.cloudProjectId) }
            }
            catch ControllerCloudError.http(404) { record.binding.status = .deleted; try save(record); continue }
            if record.binding.status == .unavailable {
                guard !remote.isEmpty, cloud.contains(where: { $0.id == record.binding.cloudProjectId }) else { continue }
                record.binding.status = .linked; try save(record)
            }
            for item in local where !record.uploadedDigests.contains(item.digest) {
                try ControllerCloudAutomaticSyncAuthorization.requireConsent()
                let exported = try export(item, selected: selected)
                let archive = try ControllerCloudNativeArchive.encode(manifest: exported.0, files: exported.1)
                let hash = DeploymentDigest.sha256Hex(archive)
                record.pendingArchiveSha256 = hash; record.pendingPackageDigest = item.digest; try save(record)
                // Reconcile immutable identity before retrying an ambiguous import. Its short HTTP
                // idempotency window is never treated as permission to create another version.
                if !remote.contains(where: { $0.archiveSha256 == hash && $0.packageDigest == item.digest && $0.sourceVersionId == nil }) {
                    struct Imported: Decodable, Sendable { let id: String }
                    let body = try JSONSerialization.data(withJSONObject: ["sourceVersionId": NSNull(),
                        "idempotencyKey": "screen-sync-" + hash, "data": archive.base64EncodedString(),
                        "toolchain": ["name": "Screenpunk existing package", "version": "1"]])
                    _ = try await session.request(try prefix(record.binding.cloudProjectId) + "/packages/import", method: "POST", body: body, as: Imported.self)
                }
                try ControllerCloudAutomaticSyncAuthorization.requireConsent()
                record.uploadedDigests.insert(item.digest); record.pendingArchiveSha256 = nil; record.pendingPackageDigest = nil; try save(record)
            }
            for package in remote where record.imported[package.packageId] == nil && !record.uploadedDigests.contains(package.packageDigest) {
                // Persist the new local revision before any measured broker import can commit.
                let revision = UUID().uuidString.lowercased(); record.imported[package.packageId] = revision; try save(record)
            }
            // An interrupted import has its identity already journaled. Presence is determined
            // from exact immutable local revisions, never by name.
            for package in remote {
                guard let revision = record.imported[package.packageId], !visible.contains(where: { $0.dashboardId == record.dashboardId && $0.revision == revision }) else { continue }
                try await importPackage(package, dashboard: record.dashboardId, revision: revision, selected: selected, record: &record)
            }
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            record.binding.status = .synced; try save(record)
        }
    }
    private func export(_ item: WorkbenchWorkspacePackageSummary, selected: WorkbenchWorkspaceStatus) throws -> (DashboardManifest, [String: Data]) {
        let scratch = root.appendingPathComponent("package-transfer/sync-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        let result = try client.performAuthoring(method: .packageExport, params: ["schemaVersion": 1,
            "dashboardId": item.dashboardId, "revision": item.revision, "path": scratch.path,
            "expectedWorkspaceId": selected.workspaceId!, "expectedSelectionGeneration": selected.selectionGeneration!])
        guard result.packageExport?.digest == item.digest else { throw ControllerCloudError.invalidResponse }
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(contentsOf: scratch.appendingPathComponent("manifest.json")))
        var files: [String: Data] = [:]
        for file in manifest.files { files[file.path] = try Data(contentsOf: scratch.appendingPathComponent("files/" + file.path)) }
        return (manifest, files)
    }
    private func importPackage(_ package: Package, dashboard: String, revision: String, selected: WorkbenchWorkspaceStatus, record: inout Journal) async throws {
        var manifest = package.manifest; manifest.dashboardId = dashboard; manifest.revision = revision
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        try PackageValidator.validate(manifest)
        let digest = manifest.digest!
        // A committed exact revision is idempotent even if the last response was lost.
        if try client.listWorkspacePackages(in: selected).contains(where: { $0.dashboardId == dashboard && $0.revision == revision && $0.digest == digest }) {
            record.hasLocalCopy = true; record.uploadedDigests.insert(digest); try save(record); return
        }
        struct Chunk: Decodable, Sendable {
            let projectId: String; let packageId: String; let packageDigest: String
            let path: String; let sha256: String; let size: Int; let offset: Int
            let dataBase64: String; let nextOffset: Int?
        }
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        let began = try client.beginPackageImport(manifest: manifest, expectedDigest: digest,
            expectedWorkspaceId: localWorkspaceId, expectedSelectionGeneration: selected.selectionGeneration!)
        guard let upload = began.uploadId else { throw ControllerCloudError.invalidResponse }
        var committed = false
        defer { if !committed { try? client.abortPackageImport(uploadId: upload, expectedWorkspaceId: localWorkspaceId, expectedSelectionGeneration: selected.selectionGeneration!) } }
        for (index, file) in manifest.files.enumerated() {
            var offset = 0, bytes = Data()
            repeat {
                let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#")))!
                let chunk = try await session.request(try prefix(package.projectId) + "/packages/\(package.packageId)/file?path=\(encoded)&offset=\(offset)&length=65536", as: Chunk.self)
                guard chunk.projectId == package.projectId, chunk.packageId == package.packageId, chunk.packageDigest == package.packageDigest,
                      chunk.path == file.path, chunk.sha256 == file.sha256, chunk.size == file.bytes, chunk.offset == offset,
                      let data = Data(base64Encoded: chunk.dataBase64), data.count <= 65536,
                      offset + data.count <= file.bytes, (data.count > 0 || file.bytes == 0),
                      chunk.nextOffset == (offset + data.count == file.bytes ? nil : offset + data.count) else { throw ControllerCloudError.invalidResponse }
                try ControllerCloudAutomaticSyncAuthorization.requireConsent()
                _ = try client.sendPackageImportChunk(uploadId: upload, fileIndex: index, offset: offset, bytes: data,
                    expectedWorkspaceId: localWorkspaceId, expectedSelectionGeneration: selected.selectionGeneration!)
                bytes.append(data); offset += data.count
            } while offset < file.bytes
            guard DeploymentDigest.sha256Hex(bytes) == file.sha256 else { throw ControllerCloudError.invalidResponse }
        }
        try ControllerCloudAutomaticSyncAuthorization.requireConsent()
        _ = try client.commitPackageImport(uploadId: upload, expectedDigest: digest, expectedWorkspaceId: localWorkspaceId,
            expectedSelectionGeneration: selected.selectionGeneration!)
        committed = true
        record.hasLocalCopy = true; record.uploadedDigests.insert(digest); try save(record)
    }
}
private extension String {
    var sha256Scope: String { SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined() }
}
#endif
