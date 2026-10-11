import Foundation
#if os(macOS)

public struct ControllerCloudSourceSnapshot: Codable, Sendable, Equatable {
    public let revision: String
    public let files: [String: Data]
    public init(revision: String, files: [String: Data]) { self.revision = revision; self.files = files }
    public func validate() throws {
        guard files.count <= 2_000, files.values.reduce(0, {$0 + $1.count}) <= 25 * 1024 * 1024 else { throw ControllerCloudError.sourceLimitExceeded }
        var paths = WorkspacePathCollisionDetector()
        for (path, data) in files {
            guard data.count <= 5 * 1024 * 1024 else { throw ControllerCloudError.sourceLimitExceeded }
            guard WorkspaceValidation.member(path), !ControllerCloudSourcePolicy.excludes(path) else { throw ControllerCloudError.invalidSource }
            try paths.insert(path)
        }
    }
}
public protocol ControllerCloudProjectRemote: Sendable {
    /// nil means deleted/unavailable; never recreate without an explicit new-project action.
    func read(workspaceId: String, projectId: String) async throws -> ControllerCloudSourceSnapshot?
    /// Atomic source replacement with server-side immutable revision CAS and idempotency.
    func write(workspaceId: String, projectId: String, baseRevision: String?, files: [String: Data], idempotencyKey: String) async throws -> ControllerCloudSourceSnapshot
}
public protocol ControllerCloudProjectLocal: Sendable {
    func read(projectId: String) async throws -> ControllerCloudSourceSnapshot
    /// Must compare the expected local revision and atomically replace included files.
    func replace(projectId: String, expectedRevision: String, snapshot: ControllerCloudSourceSnapshot) async throws
}
public enum ControllerCloudSyncStatus: String, Codable, Sendable { case linked, synced, uploading, downloading, conflict, deleted }
public enum ControllerCloudConflictChoice: Sendable { case local, remote }
public struct ControllerCloudProjectBinding: Codable, Sendable, Equatable {
    public let accountId: String
    public let workspaceId: String
    public let localProjectId: String
    public let cloudProjectId: String
    public var localRevision: String?
    public var cloudRevision: String?
    public var status: ControllerCloudSyncStatus
}
private struct ControllerCloudSyncJournal: Codable {
    var binding: ControllerCloudProjectBinding
    var pendingUpload: ControllerCloudSourceSnapshot?
    var pendingDownload: ControllerCloudSourceSnapshot?
    var expectedLocalRevision: String?
    var idempotencyKey: String?
    var conflictLocal: ControllerCloudSourceSnapshot?
    var conflictRemote: ControllerCloudSourceSnapshot?
}
/// Persistent per-project journals contain both conflicting revisions before replacing anything.
/// This service never builds, publishes, selects screens, or activates devices.
public actor ControllerCloudProjectSync {
    private let root: URL
    private let remote: any ControllerCloudProjectRemote
    private let local: any ControllerCloudProjectLocal
    private var busy = Set<String>()
    public init(root: URL, remote: any ControllerCloudProjectRemote, local: any ControllerCloudProjectLocal) throws {
        self.root = root; self.remote = remote; self.local = local
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func url(_ id: String) throws -> URL {
        guard WorkspaceValidation.id(id) else { throw ControllerCloudError.invalidSource }
        return root.appendingPathComponent(id + ".json")
    }
    private func read(_ id: String) throws -> ControllerCloudSyncJournal {
        try JSONDecoder().decode(ControllerCloudSyncJournal.self, from: Data(contentsOf: url(id)))
    }
    private func save(_ journal: ControllerCloudSyncJournal) throws {
        let target = try url(journal.binding.localProjectId)
        try JSONEncoder().encode(journal).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    public func bindings(accountId: String) throws -> [ControllerCloudProjectBinding] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {$0.pathExtension == "json"}.map {
            try JSONDecoder().decode(ControllerCloudSyncJournal.self, from: Data(contentsOf: $0)).binding
        }.filter {$0.accountId == accountId}.sorted {$0.localProjectId < $1.localProjectId}
    }
    public func status(localProjectId: String) throws -> ControllerCloudProjectBinding { try read(localProjectId).binding }
    public func statusIfPresent(localProjectId: String) throws -> ControllerCloudProjectBinding? {
        guard FileManager.default.fileExists(atPath: try url(localProjectId).path) else { return nil }
        return try read(localProjectId).binding // Corruption is not permission to create or retarget a project.
    }
    public func link(accountId: String, workspaceId: String, localProjectId: String, cloudProjectId: String) throws {
        guard !busy.contains(localProjectId), !accountId.isEmpty, !workspaceId.isEmpty, !cloudProjectId.isEmpty else { throw ControllerCloudError.conflict }
        if FileManager.default.fileExists(atPath: try url(localProjectId).path) { throw ControllerCloudError.conflict }
        try save(.init(binding: .init(accountId: accountId, workspaceId: workspaceId, localProjectId: localProjectId, cloudProjectId: cloudProjectId, status: .linked)))
    }
    public func unlink(localProjectId: String) throws {
        guard !busy.contains(localProjectId) else { throw ControllerCloudError.conflict }
        // Keep recoverable drafts and interrupted writes. Unlinking detaches the journal rather than erasing evidence.
        let source = try url(localProjectId)
        let retained = root.appendingPathComponent(localProjectId + "-unlinked-" + UUID().uuidString + ".draft")
        try FileManager.default.moveItem(at: source, to: retained)
    }
    public func sync(accountId: String, localProjectId: String) async throws -> ControllerCloudProjectBinding {
        guard busy.insert(localProjectId).inserted else { throw ControllerCloudError.conflict }
        defer { busy.remove(localProjectId) }
        var journal = try read(localProjectId)
        guard journal.binding.accountId == accountId else { throw ControllerCloudError.accountMismatch }
        if journal.binding.status == .deleted { throw ControllerCloudError.deletedProject }
        if journal.binding.status == .conflict { return journal.binding }
        if let upload = journal.pendingUpload { return try await uploadPending(&journal, snapshot: upload) }
        if let download = journal.pendingDownload { return try await downloadPending(&journal, snapshot: download) }
        let current = try await local.read(projectId: localProjectId); try current.validate()
        guard let head = try await remote.read(workspaceId: journal.binding.workspaceId, projectId: journal.binding.cloudProjectId) else {
            journal.binding.status = .deleted; journal.conflictLocal = current; try save(journal); return journal.binding
        }
        try head.validate()
        if head.revision.isEmpty && head.files.isEmpty {
            journal.binding.cloudRevision = ""; journal.pendingUpload = current; journal.idempotencyKey = UUID().uuidString
            journal.binding.status = .uploading; try save(journal)
            return try await uploadPending(&journal, snapshot: current)
        }
        if current.files == head.files { journal.binding.localRevision = current.revision; journal.binding.cloudRevision = head.revision; journal.binding.status = .synced; try save(journal); return journal.binding }
        let localChanged = journal.binding.localRevision == nil || journal.binding.localRevision != current.revision
        let remoteChanged = journal.binding.cloudRevision == nil || journal.binding.cloudRevision != head.revision
        if localChanged && remoteChanged {
            journal.conflictLocal = current; journal.conflictRemote = head; journal.binding.status = .conflict; try save(journal); return journal.binding
        }
        if localChanged {
            journal.pendingUpload = current; journal.idempotencyKey = UUID().uuidString
            journal.binding.status = .uploading; try save(journal)
            return try await uploadPending(&journal, snapshot: current)
        }
        journal.pendingDownload = head; journal.expectedLocalRevision = current.revision
        journal.binding.status = .downloading; try save(journal)
        return try await downloadPending(&journal, snapshot: head)
    }
    public func resolve(accountId: String, localProjectId: String, choice: ControllerCloudConflictChoice) async throws -> ControllerCloudProjectBinding {
        guard busy.insert(localProjectId).inserted else { throw ControllerCloudError.conflict }
        defer { busy.remove(localProjectId) }
        var journal = try read(localProjectId)
        guard journal.binding.accountId == accountId else { throw ControllerCloudError.accountMismatch }
        guard journal.binding.status == .conflict, let localDraft = journal.conflictLocal, let remoteDraft = journal.conflictRemote else { throw ControllerCloudError.conflict }
        let current = try await local.read(projectId: localProjectId)
        guard current.revision == localDraft.revision else { throw ControllerCloudError.conflict }
        // Review authorization is tied to both exact snapshots.
        guard let head = try await remote.read(workspaceId: journal.binding.workspaceId, projectId: journal.binding.cloudProjectId), head.revision == remoteDraft.revision else { throw ControllerCloudError.conflict }
        if choice == .local {
            journal.binding.cloudRevision = head.revision; journal.pendingUpload = localDraft; journal.idempotencyKey = UUID().uuidString; journal.binding.status = .uploading; try save(journal)
            return try await uploadPending(&journal, snapshot: localDraft)
        }
        journal.pendingDownload = remoteDraft; journal.expectedLocalRevision = current.revision; journal.binding.status = .downloading; try save(journal)
        return try await downloadPending(&journal, snapshot: remoteDraft)
    }
    private func uploadPending(_ journal: inout ControllerCloudSyncJournal, snapshot: ControllerCloudSourceSnapshot) async throws -> ControllerCloudProjectBinding {
        guard let storedBase = journal.binding.cloudRevision, let key = journal.idempotencyKey else { throw ControllerCloudError.conflict }
        let base: String? = storedBase.isEmpty ? nil : storedBase
        let result: ControllerCloudSourceSnapshot
        do {
            result = try await remote.write(workspaceId: journal.binding.workspaceId, projectId: journal.binding.cloudProjectId, baseRevision: base, files: snapshot.files, idempotencyKey: key)
        } catch {
            if error as? ControllerCloudError == .http(404) {
                // Confirmed deletion is terminal. Retain the original pending draft and
                // latest local work for recovery; never recreate the remote implicitly.
                journal.conflictLocal = try await local.read(projectId: journal.binding.localProjectId)
                journal.binding.status = .deleted; try save(journal); return journal.binding
            }
            if let cloudError = error as? ControllerCloudError, cloudError == .conflict || cloudError == .http(409) {
                journal.conflictLocal = try await local.read(projectId: journal.binding.localProjectId)
                journal.conflictRemote = try await remote.read(workspaceId: journal.binding.workspaceId, projectId: journal.binding.cloudProjectId)
                journal.pendingUpload = nil; journal.idempotencyKey = nil
                journal.binding.status = journal.conflictRemote == nil ? .deleted : .conflict
                try save(journal); return journal.binding
            }
            throw error
        }
        try result.validate(); guard result.files == snapshot.files else { throw ControllerCloudError.invalidResponse }
        let latestLocal = try await local.read(projectId: journal.binding.localProjectId)
        journal.binding.localRevision = snapshot.revision; journal.binding.cloudRevision = result.revision
        journal.binding.status = latestLocal.revision == snapshot.revision ? .synced : .linked
        journal.pendingUpload = nil; journal.idempotencyKey = nil; try save(journal); return journal.binding
    }
    private func downloadPending(_ journal: inout ControllerCloudSyncJournal, snapshot: ControllerCloudSourceSnapshot) async throws -> ControllerCloudProjectBinding {
        guard let expected = journal.expectedLocalRevision else { throw ControllerCloudError.conflict }
        let current = try await local.read(projectId: journal.binding.localProjectId)
        if current.files != snapshot.files {
            guard current.revision == expected else {
                journal.conflictLocal = current; journal.conflictRemote = snapshot
                journal.pendingDownload = nil; journal.expectedLocalRevision = nil; journal.binding.status = .conflict
                try save(journal); return journal.binding
            }
            try await local.replace(projectId: journal.binding.localProjectId, expectedRevision: expected, snapshot: snapshot)
        }
        let applied = try await local.read(projectId: journal.binding.localProjectId)
        guard applied.files == snapshot.files else { throw ControllerCloudError.invalidResponse }
        journal.binding.localRevision = applied.revision; journal.binding.cloudRevision = snapshot.revision; journal.binding.status = .synced
        journal.pendingDownload = nil; journal.expectedLocalRevision = nil; try save(journal); return journal.binding
    }
}
#endif
