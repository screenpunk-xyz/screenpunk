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

public struct DeviceManagementTransitionEntry: Codable, Equatable, Sendable {
    public let transitionID: UUID
    public let phase: DeviceManagementTransitionPhase
    public init(transitionID: UUID, phase: DeviceManagementTransitionPhase) { self.transitionID = transitionID; self.phase = phase }
    private enum CodingKeys: String, CodingKey { case transitionID, phase }
    public init(from decoder: Decoder) throws {
        try validateManagementKeys(decoder, ["transitionID", "phase"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(transitionID: try values.decode(UUID.self, forKey: .transitionID), phase: try values.decode(DeviceManagementTransitionPhase.self, forKey: .phase))
    }
}

public struct DeviceManagementCredentialBinding: Codable, Equatable, Sendable {
    public let credentialGenerationID: UUID
    public let transitionID: UUID
    public let credentialReference: String
    public init(credentialGenerationID: UUID, transitionID: UUID, credentialReference: String) throws {
        _ = try DeviceManagementTransitionRecord(transitionID: transitionID, credentialReference: credentialReference)
        self.credentialGenerationID = credentialGenerationID; self.transitionID = transitionID; self.credentialReference = credentialReference
    }
    private enum CodingKeys: String, CodingKey { case credentialGenerationID, transitionID, credentialReference }
    public init(from decoder: Decoder) throws {
        try validateManagementKeys(decoder, ["credentialGenerationID", "transitionID", "credentialReference"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(credentialGenerationID: values.decode(UUID.self, forKey: .credentialGenerationID), transitionID: values.decode(UUID.self, forKey: .transitionID), credentialReference: values.decode(String.self, forKey: .credentialReference))
    }
}

/// Append-only local evidence. Credential generations are storage bindings, not remote rotation outcomes.
/// Future remote operation request IDs must remain distinct from these authority transition IDs.
public struct DeviceManagementTransitionHistory: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumTransitions = 64
    public static let maximumCredentials = 128
    public let schemaVersion: Int
    public let transitions: [DeviceManagementTransitionEntry]
    public let credentials: [DeviceManagementCredentialBinding]
    public init(transitions: [DeviceManagementTransitionEntry], credentials: [DeviceManagementCredentialBinding]) throws {
        guard transitions.count <= Self.maximumTransitions, credentials.count <= Self.maximumCredentials else { throw DeviceManagementTransitionStoreError.capacityExceeded }
        guard !transitions.isEmpty, !credentials.isEmpty,
              Set(transitions.map(\.transitionID)).count == transitions.count,
              Set(credentials.map(\.credentialGenerationID)).count == credentials.count,
              Set(credentials.map(\.credentialReference)).count == credentials.count,
              Set(credentials.map(\.credentialGenerationID)).isDisjoint(with: Set(transitions.map(\.transitionID))),
              transitions.dropLast().allSatisfy({ $0.phase == .locallyFenced }),
              credentials.allSatisfy({ binding in transitions.contains { $0.transitionID == binding.transitionID } }),
              transitions.allSatisfy({ entry in credentials.contains { $0.transitionID == entry.transitionID } }) else { throw DeviceManagementTransitionStoreError.invalidRecord }
        for binding in credentials { _ = try DeviceManagementCredentialBinding(credentialGenerationID: binding.credentialGenerationID, transitionID: binding.transitionID, credentialReference: binding.credentialReference) }
        schemaVersion = Self.currentSchemaVersion; self.transitions = transitions; self.credentials = credentials
    }
    public static func intent(transitionID: UUID, credentialGenerationID: UUID, credentialReference: String) throws -> Self {
        try .init(transitions: [.init(transitionID: transitionID, phase: .intent)], credentials: [.init(credentialGenerationID: credentialGenerationID, transitionID: transitionID, credentialReference: credentialReference)])
    }
    public func appendingIntent(transitionID: UUID, credentialGenerationID: UUID, credentialReference: String) throws -> Self {
        guard transitions.last?.phase == .locallyFenced else { throw DeviceManagementTransitionStoreError.transitionConflict }
        return try .init(transitions: transitions + [.init(transitionID: transitionID, phase: .intent)], credentials: credentials + [.init(credentialGenerationID: credentialGenerationID, transitionID: transitionID, credentialReference: credentialReference)])
    }
    public func appendingCredential(credentialGenerationID: UUID, credentialReference: String) throws -> Self {
        guard let current = transitions.last, current.phase == .intent else { throw DeviceManagementTransitionStoreError.transitionConflict }
        return try .init(transitions: transitions, credentials: credentials + [.init(credentialGenerationID: credentialGenerationID, transitionID: current.transitionID, credentialReference: credentialReference)])
    }
    public func fenced() throws -> Self {
        guard let current = transitions.last else { throw DeviceManagementTransitionStoreError.invalidRecord }
        return try .init(transitions: Array(transitions.dropLast()) + [.init(transitionID: current.transitionID, phase: .locallyFenced)], credentials: credentials)
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, transitions, credentials }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        if version == 1 {
            let legacy = try DeviceManagementTransitionRecord(from: decoder)
            // Fixed local migration namespace transform: deterministic, bijective, and distinct from authority ID.
            var bytes = legacy.transitionID.uuid; bytes.0 ^= 0xA7; bytes.15 ^= 0x5D
            try self.init(transitions: [.init(transitionID: legacy.transitionID, phase: legacy.phase)], credentials: [.init(credentialGenerationID: UUID(uuid: bytes), transitionID: legacy.transitionID, credentialReference: legacy.credentialReference)])
            return
        }
        guard version == Self.currentSchemaVersion else { throw DeviceManagementTransitionStoreError.unsupportedVersion(version) }
        let raw = try decoder.container(keyedBy: DeviceManagementRecordKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(["schemaVersion", "transitions", "credentials"]) else { throw DeviceManagementTransitionStoreError.invalidRecord }
        try self.init(transitions: values.decode([DeviceManagementTransitionEntry].self, forKey: .transitions), credentials: values.decode([DeviceManagementCredentialBinding].self, forKey: .credentials))
    }
    fileprivate func permitsSuccessor(_ next: Self) -> Bool {
        if self == next { return true }
        if let fenced = try? fenced(), fenced == next { return true }
        guard next.credentials.count >= credentials.count, Array(next.credentials.prefix(credentials.count)) == credentials else { return false }
        if transitions == next.transitions, transitions.last?.phase == .intent {
            return next.credentials.dropFirst(credentials.count).allSatisfy { $0.transitionID == transitions.last!.transitionID }
        }
        guard transitions.allSatisfy({ $0.phase == .locallyFenced }), next.transitions.count == transitions.count + 1,
              Array(next.transitions.prefix(transitions.count)) == transitions, next.transitions.last?.phase == .intent,
              next.credentials.count == credentials.count + 1 else { return false }
        return next.credentials.last?.transitionID == next.transitions.last?.transitionID
    }
}

private func validateManagementKeys(_ decoder: Decoder, _ keys: Set<String>) throws {
    let raw = try decoder.container(keyedBy: DeviceManagementRecordKey.self)
    guard Set(raw.allKeys.map(\.stringValue)) == keys else { throw DeviceManagementTransitionStoreError.invalidRecord }
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
    case fenced(credentialReferences: [String])
}

public enum DeviceManagementTransitionIOOperation: String, Equatable, Sendable {
    case inspect, createDirectory, open, close, lock, read, write, syncFile, replace, syncDirectory, injectedBoundary
}
public enum DeviceManagementTransitionStoreError: Error, Equatable, Sendable {
    case invalidRecord, capacityExceeded, corrupt, unsupportedVersion(Int), recordTooLarge, transitionConflict, writeOutcomeUncertain
    case io(operation: DeviceManagementTransitionIOOperation, code: Int32)
}

enum DeviceManagementCommitBoundary: Sendable, Equatable {
    case afterTemporaryWrite, afterFileSync, beforeReplace, afterReplace, afterDirectorySync
}

/// Append-only bounded history: no deletion, unfencing, credential staging, or remote promotion.
/// Persist intent before any side effect; persist its fence before using it as local eligibility evidence.
/// A failed write has an uncertain outcome. Diagnostic readback alone never clears that uncertainty;
/// durably recommit the exact attempted record, or remain blocked. A restart reads the surviving committed bytes.
public final class DeviceManagementTransitionStore: @unchecked Sendable {
    public static let maximumRecordBytes = 65536
    public let directory: URL
    public var recordURL: URL { directory.appendingPathComponent("management-transition.json") }
    private let lock = NSLock()
    // Reconstructing a store in this process must not bypass a previous writer's uncertainty.
    private static let uncertaintyLock = NSLock()
    private static var uncertainWrites: [String: DeviceManagementTransitionHistory] = [:]
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
    public func load() throws -> DeviceManagementTransitionHistory? {
        lock.lock(); defer { lock.unlock() }
        guard uncertainty() == nil else { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
        return try withDiskLock(create: false) {
            guard uncertainty() == nil else { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
            return try readRecord()
        }
    }
    /// This is inspection for reconciliation, never authorization after a write error.
    public func diagnosticReadback() throws -> DeviceManagementTransitionHistory? {
        lock.lock(); defer { lock.unlock() }
        return try withDiskLock(create: false) { try readRecord() }
    }
    public func localState(cloudCredentialsConfirmedEmpty: Bool) throws -> DeviceManagementLocalState {
        guard let record = try load() else { return cloudCredentialsConfirmedEmpty ? .legacyLocal : .blocked }
        return record.transitions.allSatisfy { $0.phase == .locallyFenced }
            ? .fenced(credentialReferences: record.credentials.map(\.credentialReference)) : .blocked
    }

    public func save(_ record: DeviceManagementTransitionHistory) throws {
        lock.lock(); defer { lock.unlock() }
        if let uncertainRecord = uncertainty(), uncertainRecord != record { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw DeviceManagementTransitionStoreError.recordTooLarge }
        do {
            try withDiskLock(create: true) {
                if let uncertainRecord = uncertainty(), uncertainRecord != record { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
                if let previous = try readRecord() {
                    guard previous.permitsSuccessor(record) else {
                        throw DeviceManagementTransitionStoreError.transitionConflict
                    }
                } else {
                    // Every transition begins as intent, even when credential staging never finishes.
                    guard record.transitions.count == 1, record.credentials.count == 1, record.transitions.first?.phase == .intent else { throw DeviceManagementTransitionStoreError.transitionConflict }
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

    private func uncertainty() -> DeviceManagementTransitionHistory? {
        Self.uncertaintyLock.lock(); defer { Self.uncertaintyLock.unlock() }
        return Self.uncertainWrites[uncertaintyKey]
    }
    private func markUncertainty(_ record: DeviceManagementTransitionHistory?) {
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
    private func readRecord() throws -> DeviceManagementTransitionHistory? {
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
        do { return try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: data) }
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
