import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local cleanup bookkeeping only. Neither phase changes Cloud authority or remote cleanup evidence.
public enum DeviceLocalResetPhase: String, Codable, Sendable { case pending, completed }

public struct DeviceLocalResetRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let resetID: UUID
    /// Lowercase SHA-256-shaped opaque scope binding. No paths or credentials are stored here.
    public let scopeDigest: String
    public let phase: DeviceLocalResetPhase
    private enum CodingKeys: String, CodingKey { case schemaVersion, resetID, scopeDigest, phase }

    public init(resetID: UUID, scopeDigest: String, phase: DeviceLocalResetPhase = .pending) throws {
        guard scopeDigest.utf8.count == 64,
              scopeDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DeviceLocalResetStoreError.invalidRecord
        }
        schemaVersion = Self.currentSchemaVersion
        self.resetID = resetID; self.scopeDigest = scopeDigest; self.phase = phase
    }
    public func completed() throws -> Self { try .init(resetID: resetID, scopeDigest: scopeDigest, phase: .completed) }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw DeviceLocalResetStoreError.unsupportedVersion(version) }
        let raw = try decoder.container(keyedBy: DeviceLocalResetKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(["schemaVersion", "resetID", "scopeDigest", "phase"]) else {
            throw DeviceLocalResetStoreError.invalidRecord
        }
        try self.init(resetID: values.decode(UUID.self, forKey: .resetID),
                      scopeDigest: values.decode(String.self, forKey: .scopeDigest),
                      phase: values.decode(DeviceLocalResetPhase.self, forKey: .phase))
    }
    fileprivate func permitsSuccessor(_ next: Self, beginsNewReset: Bool) -> Bool {
        if self == next { return true }
        if phase == .pending {
            return next.resetID == resetID && next.scopeDigest == scopeDigest && next.phase == .completed
        }
        return beginsNewReset && next.phase == .pending && next.resetID != resetID
    }
}
private struct DeviceLocalResetKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public enum DeviceLocalResetIOOperation: String, Equatable, Sendable {
    case inspect, createDirectory, open, close, lock, read, write, syncFile, replace, syncDirectory, injectedBoundary
}
public enum DeviceLocalResetStoreError: Error, Equatable, Sendable {
    case invalidRecord, corrupt, unsupportedVersion(Int), recordTooLarge, transitionConflict, writeOutcomeUncertain
    case io(operation: DeviceLocalResetIOOperation, code: Int32)
}

enum DeviceLocalResetCommitBoundary: Sendable, Equatable {
    case afterTemporaryWrite, afterFileSync, beforeReplace, afterReplace, afterDirectorySync
}

/// Durable Local reset bookkeeping only; this store performs no cleanup and grants no authority.
/// A pending record must block management and runtime execution in future callers.
/// Completion is a caller assertion of finished Local cleanup, never a Cloud outcome.
/// No deletion API exists. Keep a completed marker until a new explicitly requested reset.
/// A write error blocks load even in a reconstructed store in this process. Diagnostic readback
/// does not clear it: durably retry the exact record through the same save/begin method.
/// This single-record store enforces ID distinction from the current record, not all history;
/// callers generate fresh UUIDs. It is not persistent rollback protection against external writers.
public final class DeviceLocalResetStore: @unchecked Sendable {
    public static let maximumRecordBytes = 4096
    public let directory: URL
    public var recordURL: URL { directory.appendingPathComponent("local-reset.json") }
    private let lock = NSLock()
    // Reconstructing a store in this process must not bypass a previous writer's uncertainty.
    private static let uncertaintyLock = NSLock()
    private struct Attempt: Equatable {
        let record: DeviceLocalResetRecord
        let beginsNewReset: Bool
    }
    private static var uncertainWrites: [String: Attempt] = [:]
    private var uncertaintyKey: String { directory.resolvingSymlinksInPath().standardizedFileURL.path }
    private let boundary: @Sendable (DeviceLocalResetCommitBoundary) throws -> Void

    public convenience init(directory: URL) { self.init(directory: directory, boundary: { _ in }) }
    init(directory: URL, boundary: @escaping @Sendable (DeviceLocalResetCommitBoundary) throws -> Void) {
        self.directory = directory
        self.boundary = boundary
    }
    /// A sibling of the default device and management roots. Future cleanup must separately
    /// reject configured erase roots that overlap this directory; arbitrary ancestor erasure is not guarded here.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support.appendingPathComponent("xyz.screenpunk.local-reset", isDirectory: true)
    }

    /// nil means confirmed ENOENT only; corruption, unsupported versions and IO are throwing blocked states.
    public func load() throws -> DeviceLocalResetRecord? {
        lock.lock(); defer { lock.unlock() }
        guard uncertainty() == nil else { throw DeviceLocalResetStoreError.writeOutcomeUncertain }
        return try withDiskLock(create: false) {
            guard uncertainty() == nil else { throw DeviceLocalResetStoreError.writeOutcomeUncertain }
            return try readRecord()
        }
    }
    /// This is inspection for reconciliation, never authorization after a write error.
    public func diagnosticReadback() throws -> DeviceLocalResetRecord? {
        lock.lock(); defer { lock.unlock() }
        return try withDiskLock(create: false) { try readRecord() }
    }
    /// Creates initial pending, retries exact records, or completes the same pending binding.
    /// It cannot replace an existing completed marker with another reset.
    public func save(_ record: DeviceLocalResetRecord) throws {
        try persistRecord(record, beginsNewReset: false)
    }

    /// Only an explicit new request may replace completion with a different-ID pending record.
    /// The scope digest is opaque here; future callers must compare it with their configured scope.
    public func beginNewReset(_ record: DeviceLocalResetRecord) throws {
        guard record.phase == .pending else { throw DeviceLocalResetStoreError.transitionConflict }
        try persistRecord(record, beginsNewReset: true)
    }

    private func persistRecord(_ record: DeviceLocalResetRecord, beginsNewReset: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let attempt = Attempt(record: record, beginsNewReset: beginsNewReset)
        if let uncertainAttempt = uncertainty(), uncertainAttempt != attempt { throw DeviceLocalResetStoreError.writeOutcomeUncertain }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw DeviceLocalResetStoreError.recordTooLarge }
        do {
            try withDiskLock(create: true) {
                if let uncertainAttempt = uncertainty(), uncertainAttempt != attempt { throw DeviceLocalResetStoreError.writeOutcomeUncertain }
                if let previous = try readRecord() {
                    guard previous.permitsSuccessor(record, beginsNewReset: beginsNewReset) else {
                        throw DeviceLocalResetStoreError.transitionConflict
                    }
                } else {
                    // No cleanup completion can be introduced without prior durable intent.
                    guard record.phase == .pending else { throw DeviceLocalResetStoreError.transitionConflict }
                }
                markUncertainty(attempt)
                try commit(data)
                markUncertainty(nil)
            }
        } catch {
            // Validation/read errors did not replace a record. IO errors remain conservatively uncertain.
            if case .transitionConflict = error as? DeviceLocalResetStoreError { throw error }
            if case .corrupt = error as? DeviceLocalResetStoreError { throw error }
            if case .unsupportedVersion = error as? DeviceLocalResetStoreError { throw error }
            if case .recordTooLarge = error as? DeviceLocalResetStoreError { throw error }
            if case .writeOutcomeUncertain = error as? DeviceLocalResetStoreError { throw error }
            markUncertainty(attempt)
            throw error
        }
    }

    private func uncertainty() -> Attempt? {
        Self.uncertaintyLock.lock(); defer { Self.uncertaintyLock.unlock() }
        return Self.uncertainWrites[uncertaintyKey]
    }
    private func markUncertainty(_ attempt: Attempt?) {
        Self.uncertaintyLock.lock(); defer { Self.uncertaintyLock.unlock() }
        Self.uncertainWrites[uncertaintyKey] = attempt
    }

    private func fail(_ operation: DeviceLocalResetIOOperation) -> DeviceLocalResetStoreError {
        .io(operation: operation, code: errno)
    }
    private func inspectDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw DeviceLocalResetStoreError.io(operation: .inspect, code: ENOTDIR) }
            return true
        }
        if errno == ENOENT { return false }
        throw fail(.inspect)
    }
    private func ensureDirectory(_ url: URL) throws {
        if try inspectDirectory(url) { return }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw DeviceLocalResetStoreError.io(operation: .createDirectory, code: ENOENT) }
        try ensureDirectory(parent)
        if mkdir(url.path, 0o700) != 0 {
            guard errno == EEXIST, try inspectDirectory(url) else { throw fail(.createDirectory) }
        }
        try syncDirectory(parent)
    }
    private func withDiskLock<T>(create: Bool, _ operation: () throws -> T) throws -> T {
        if create { try ensureDirectory(directory) }
        else if try !inspectDirectory(directory) { return try operation() }
        let descriptor = open(directory.appendingPathComponent("local-reset.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw fail(.open) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fail(.inspect) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw DeviceLocalResetStoreError.io(operation: .inspect, code: EINVAL) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw fail(.lock) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func readRecord() throws -> DeviceLocalResetRecord? {
        let descriptor = open(recordURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw fail(.open)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fail(.inspect) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw DeviceLocalResetStoreError.io(operation: .inspect, code: EINVAL) }
        guard info.st_size <= Self.maximumRecordBytes else { throw DeviceLocalResetStoreError.recordTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw fail(.read) }
            if count == 0 { break }
            guard data.count + count <= Self.maximumRecordBytes else { throw DeviceLocalResetStoreError.recordTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return try JSONDecoder().decode(DeviceLocalResetRecord.self, from: data) }
        catch let error as DeviceLocalResetStoreError {
            if case .unsupportedVersion = error { throw error }
            throw DeviceLocalResetStoreError.corrupt
        } catch { throw DeviceLocalResetStoreError.corrupt }
    }
    private func hit(_ point: DeviceLocalResetCommitBoundary) throws {
        do { try boundary(point) }
        catch { throw DeviceLocalResetStoreError.io(operation: .injectedBoundary, code: EIO) }
    }
    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw fail(.open) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw fail(.syncDirectory) }
    }
    private func commit(_ data: Data) throws {
        let temporary = directory.appendingPathComponent("local-reset.tmp-\(UUID().uuidString)")
        var descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw fail(.open) }
        defer { if descriptor >= 0 { close(descriptor) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw fail(.write) }
                guard count > 0 else { throw DeviceLocalResetStoreError.io(operation: .write, code: EIO) }
                written += count
            }
        }
        try hit(.afterTemporaryWrite)
        guard fsync(descriptor) == 0 else { throw fail(.syncFile) }
        #if canImport(Darwin)
        // Ask supported Apple filesystems to flush drive caches too; ordinary fsync remains required.
        if fcntl(descriptor, F_FULLFSYNC) != 0 && errno != ENOTSUP && errno != EINVAL && errno != ENOTTY { throw fail(.syncFile) }
        #endif
        try hit(.afterFileSync)
        let closed = close(descriptor)
        descriptor = -1
        guard closed == 0 else { throw fail(.close) }
        try hit(.beforeReplace)
        guard rename(temporary.path, recordURL.path) == 0 else { throw fail(.replace) }
        try hit(.afterReplace)
        try syncDirectory(directory)
        try hit(.afterDirectorySync)
    }
}
