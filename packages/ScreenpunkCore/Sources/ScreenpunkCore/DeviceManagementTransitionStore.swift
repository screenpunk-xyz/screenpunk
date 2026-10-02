import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local intent/revocation evidence only. Neither phase asserts any remote authority outcome.
public enum DeviceManagementTransitionPhase: String, Codable, Sendable { case intent, locallyFenced }

public struct DeviceManagementTransitionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let transitionID: UUID
    /// An opaque Keychain account reference, never a credential, provider token, or remote identifier.
    public let credentialReference: String
    public let phase: DeviceManagementTransitionPhase
    private enum CodingKeys: String, CodingKey { case schemaVersion, transitionID, credentialReference, phase }

    public init(transitionID: UUID, credentialReference: String, phase: DeviceManagementTransitionPhase = .intent) throws {
        guard !credentialReference.isEmpty, credentialReference.utf8.count <= 128,
              credentialReference.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw DeviceManagementTransitionStoreError.invalidRecord
        }
        schemaVersion = Self.currentSchemaVersion
        self.transitionID = transitionID
        self.credentialReference = credentialReference
        self.phase = phase
    }
    public func fenced() throws -> Self { try .init(transitionID: transitionID, credentialReference: credentialReference, phase: .locallyFenced) }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw DeviceManagementTransitionStoreError.unsupportedVersion(version) }
        let raw = try decoder.container(keyedBy: DeviceManagementRecordKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(["schemaVersion", "transitionID", "credentialReference", "phase"]) else {
            throw DeviceManagementTransitionStoreError.invalidRecord
        }
        try self.init(transitionID: values.decode(UUID.self, forKey: .transitionID),
                      credentialReference: values.decode(String.self, forKey: .credentialReference),
                      phase: values.decode(DeviceManagementTransitionPhase.self, forKey: .phase))
    }
}

private struct DeviceManagementRecordKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Journal evidence only: a fenced reference still requires external Keychain classification/quarantine.
public enum DeviceManagementLocalState: Equatable, Sendable {
    case blocked
    case legacyLocal
    case fenced(credentialReference: String)
}

public enum DeviceManagementTransitionIOOperation: String, Equatable, Sendable {
    case inspect, createDirectory, open, close, lock, read, write, syncFile, replace, syncDirectory, injectedBoundary
}
public enum DeviceManagementTransitionStoreError: Error, Equatable, Sendable {
    case invalidRecord, corrupt, unsupportedVersion(Int), recordTooLarge, transitionConflict, writeOutcomeUncertain
    case io(operation: DeviceManagementTransitionIOOperation, code: Int32)
}

enum DeviceManagementCommitBoundary: Sendable, Equatable {
    case afterTemporaryWrite, afterFileSync, beforeReplace, afterReplace, afterDirectorySync
}

/// Conservative one-record primitive: no deletion, rotation, unfencing, credential staging, or remote promotion.
/// Persist intent before any side effect; persist its fence before using it as local eligibility evidence.
/// A failed write has an uncertain outcome. Diagnostic readback alone never clears that uncertainty;
/// durably recommit the exact attempted record, or remain blocked. A restart reads the surviving committed bytes.
public final class DeviceManagementTransitionStore: @unchecked Sendable {
    public static let maximumRecordBytes = 4096
    public let directory: URL
    public var recordURL: URL { directory.appendingPathComponent("management-transition.json") }
    private let lock = NSLock()
    // Reconstructing a store in this process must not bypass a previous writer's uncertainty.
    private static let uncertaintyLock = NSLock()
    private static var uncertainWrites: [String: DeviceManagementTransitionRecord] = [:]
    private var uncertaintyKey: String { directory.resolvingSymlinksInPath().standardizedFileURL.path }
    private let boundary: @Sendable (DeviceManagementCommitBoundary) throws -> Void

    public convenience init(directory: URL) { self.init(directory: directory, boundary: { _ in }) }
    init(directory: URL, boundary: @escaping @Sendable (DeviceManagementCommitBoundary) throws -> Void) {
        self.directory = directory
        self.boundary = boundary
    }
    /// A sibling of the default DeviceStateStore root, so destructive legacy unlink cannot erase this record.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support.appendingPathComponent("xyz.screenpunk.management", isDirectory: true)
    }

    /// nil means confirmed ENOENT only; corruption, unsupported versions and IO are throwing blocked states.
    public func load() throws -> DeviceManagementTransitionRecord? {
        lock.lock(); defer { lock.unlock() }
        guard uncertainty() == nil else { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
        return try withDiskLock(create: false) {
            guard uncertainty() == nil else { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
            return try readRecord()
        }
    }
    /// This is inspection for reconciliation, never authorization after a write error.
    public func diagnosticReadback() throws -> DeviceManagementTransitionRecord? {
        lock.lock(); defer { lock.unlock() }
        return try withDiskLock(create: false) { try readRecord() }
    }
    public func localState(cloudCredentialsConfirmedEmpty: Bool) throws -> DeviceManagementLocalState {
        guard let record = try load() else { return cloudCredentialsConfirmedEmpty ? .legacyLocal : .blocked }
        switch record.phase {
        case .intent: return .blocked
        case .locallyFenced: return .fenced(credentialReference: record.credentialReference)
        }
    }

    public func save(_ record: DeviceManagementTransitionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        if let uncertainRecord = uncertainty(), uncertainRecord != record { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw DeviceManagementTransitionStoreError.recordTooLarge }
        do {
            try withDiskLock(create: true) {
                if let uncertainRecord = uncertainty(), uncertainRecord != record { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
                if let previous = try readRecord() {
                    guard previous.transitionID == record.transitionID, previous.credentialReference == record.credentialReference,
                          previous.phase != .locallyFenced || record.phase == .locallyFenced else {
                        throw DeviceManagementTransitionStoreError.transitionConflict
                    }
                } else {
                    // Every transition begins as intent, even when credential staging never finishes.
                    guard record.phase == .intent else { throw DeviceManagementTransitionStoreError.transitionConflict }
                }
                markUncertainty(record)
                try commit(data)
                markUncertainty(nil)
            }
        } catch {
            // Validation/read errors did not replace a record. IO errors remain conservatively uncertain.
            if case .transitionConflict = error as? DeviceManagementTransitionStoreError { throw error }
            if case .corrupt = error as? DeviceManagementTransitionStoreError { throw error }
            if case .unsupportedVersion = error as? DeviceManagementTransitionStoreError { throw error }
            if case .recordTooLarge = error as? DeviceManagementTransitionStoreError { throw error }
            if case .writeOutcomeUncertain = error as? DeviceManagementTransitionStoreError { throw error }
            markUncertainty(record)
            throw error
        }
    }

    private func uncertainty() -> DeviceManagementTransitionRecord? {
        Self.uncertaintyLock.lock(); defer { Self.uncertaintyLock.unlock() }
        return Self.uncertainWrites[uncertaintyKey]
    }
    private func markUncertainty(_ record: DeviceManagementTransitionRecord?) {
        Self.uncertaintyLock.lock(); defer { Self.uncertaintyLock.unlock() }
        Self.uncertainWrites[uncertaintyKey] = record
    }

    private func fail(_ operation: DeviceManagementTransitionIOOperation) -> DeviceManagementTransitionStoreError {
        .io(operation: operation, code: errno)
    }
    private func inspectDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw DeviceManagementTransitionStoreError.io(operation: .inspect, code: ENOTDIR) }
            return true
        }
        if errno == ENOENT { return false }
        throw fail(.inspect)
    }
    private func ensureDirectory(_ url: URL) throws {
        if try inspectDirectory(url) { return }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw DeviceManagementTransitionStoreError.io(operation: .createDirectory, code: ENOENT) }
        try ensureDirectory(parent)
        if mkdir(url.path, 0o700) != 0 {
            guard errno == EEXIST, try inspectDirectory(url) else { throw fail(.createDirectory) }
        }
        try syncDirectory(parent)
    }
    private func withDiskLock<T>(create: Bool, _ operation: () throws -> T) throws -> T {
        if create { try ensureDirectory(directory) }
        else if try !inspectDirectory(directory) { return try operation() }
        let descriptor = open(directory.appendingPathComponent("management-transition.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw fail(.open) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fail(.inspect) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw DeviceManagementTransitionStoreError.io(operation: .inspect, code: EINVAL) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw fail(.lock) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func readRecord() throws -> DeviceManagementTransitionRecord? {
        let descriptor = open(recordURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw fail(.open)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fail(.inspect) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw DeviceManagementTransitionStoreError.io(operation: .inspect, code: EINVAL) }
        guard info.st_size <= Self.maximumRecordBytes else { throw DeviceManagementTransitionStoreError.recordTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw fail(.read) }
            if count == 0 { break }
            guard data.count + count <= Self.maximumRecordBytes else { throw DeviceManagementTransitionStoreError.recordTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return try JSONDecoder().decode(DeviceManagementTransitionRecord.self, from: data) }
        catch let error as DeviceManagementTransitionStoreError {
            if case .unsupportedVersion = error { throw error }
            throw DeviceManagementTransitionStoreError.corrupt
        } catch { throw DeviceManagementTransitionStoreError.corrupt }
    }
    private func hit(_ point: DeviceManagementCommitBoundary) throws {
        do { try boundary(point) }
        catch { throw DeviceManagementTransitionStoreError.io(operation: .injectedBoundary, code: EIO) }
    }
    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw fail(.open) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw fail(.syncDirectory) }
    }
    private func commit(_ data: Data) throws {
        let temporary = directory.appendingPathComponent("management-transition.tmp-\(UUID().uuidString)")
        var descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw fail(.open) }
        defer { if descriptor >= 0 { close(descriptor) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw fail(.write) }
                guard count > 0 else { throw DeviceManagementTransitionStoreError.io(operation: .write, code: EIO) }
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
