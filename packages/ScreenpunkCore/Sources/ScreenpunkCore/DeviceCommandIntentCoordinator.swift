import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared device intent fence. This journal records accepted intent before mutation;
/// it does not grant installation authority or substitute for a content commit receipt.
public final class DeviceCommandIntentCoordinator: @unchecked Sendable {
    public enum Failure: Error { case needsReview, corruptJournal, conflictingOperation, persistence }
    public struct Checkpoint: Equatable, Sendable { fileprivate let generation: UUID }
    private struct Deployment: Codable { let key: String; let digest: String; var intentGeneration: UUID? = nil }
    private struct Record: Codable {
        let operationID: UUID; let generation: UUID
        var deployments: [Deployment]? = nil
        var committedFence: UUID? = nil
        var committedInventoryGeneration: UUID? = nil
    }
    private let root: URL
    private let lock = NSLock()
    public init(root: URL) { self.root = root }
    private struct RootBinding: Codable, Equatable { let device: UInt64; let inode: UInt64 }
    private var pinnedRoot: RootBinding?
    private var url: URL { root.appendingPathComponent("command-intent.json") }
    private func withRoot<T>(create: Bool, body: (Int32) throws -> T) throws -> T {
        if create && !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { if !create && errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }; throw Failure.persistence }
        defer { close(fd) }
        var actual = stat(), named = stat()
        guard fstat(fd, &actual) == 0, lstat(root.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
            named.st_dev == actual.st_dev, named.st_ino == actual.st_ino else { throw Failure.persistence }
        let identity = RootBinding(device: UInt64(actual.st_dev), inode: UInt64(actual.st_ino))
        guard pinnedRoot == nil || pinnedRoot == identity else { throw Failure.corruptJournal }
        let bindingFD = openat(fd, "command-root.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if bindingFD >= 0 {
            defer { close(bindingFD) }
            var info = stat(); guard fstat(bindingFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_size >= 0, info.st_size <= 8192 else { throw Failure.corruptJournal }
            let handle = FileHandle(fileDescriptor: bindingFD, closeOnDealloc: false)
            let bytes = try handle.read(upToCount: 8193) ?? Data()
            guard try JSONDecoder().decode(RootBinding.self, from: bytes) == identity else { throw Failure.corruptJournal }
        } else {
            guard errno == ENOENT, try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw Failure.corruptJournal }
            guard create else { throw CocoaError(.fileReadNoSuchFile) }
            try writeExact(fd, name: "command-root.json", bytes: JSONEncoder().encode(identity))
        }
        pinnedRoot = identity
        let result = try body(fd)
        guard lstat(root.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
            named.st_dev == actual.st_dev, named.st_ino == actual.st_ino else { throw Failure.persistence }
        return result
    }
    private func writeExact(_ parent: Int32, name: String, bytes: Data) throws {
        let staging = name + ".stage-" + UUID().uuidString.lowercased()
        let fd = openat(parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.persistence }
        defer { close(fd); _ = unlinkat(parent, staging, 0) }
        let count = bytes.withUnsafeBytes { pointer in
            #if canImport(Darwin)
            Darwin.write(fd, pointer.baseAddress, pointer.count)
            #else
            Glibc.write(fd, pointer.baseAddress, pointer.count)
            #endif
        }
        guard count == bytes.count, fsync(fd) == 0, renameat(parent, staging, parent, name) == 0, fsync(parent) == 0 else { throw Failure.persistence }
    }
    private func load() throws -> Record? {
        do {
            let bytes = try withRoot(create: false) { parent -> Data in
                let fd = openat(parent, "command-intent.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }; throw Failure.corruptJournal }
                defer { close(fd) }
                var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_size >= 0, info.st_size <= 8 * 1024 * 1024 else { throw Failure.corruptJournal }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let bytes = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
                var named = stat(); guard fstatat(parent, "command-intent.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
                    named.st_mode & S_IFMT == S_IFREG, info.st_dev == named.st_dev, info.st_ino == named.st_ino else { throw Failure.corruptJournal }
                return bytes
            }
            guard bytes.count <= 8 * 1024 * 1024 else { throw Failure.corruptJournal }
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            let deployments = record.deployments ?? []
            guard deployments.count <= 4096,
                  Set(deployments.map(\.key)).count == deployments.count,
                  deployments.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 1024 && $0.digest.utf8.count == 64 }) else { throw Failure.corruptJournal }
            return record
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        catch { throw Failure.corruptJournal }
    }
    public func checkpoint() throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        if let record = try load() { return .init(generation: record.generation) }
        // Persist genesis so process restart cannot manufacture a matching empty lifetime.
        let record = Record(operationID: UUID(), generation: UUID())
        try save(record); return .init(generation: record.generation)
    }
    /// Caller already holds the shared device authority. Latest accepted explicit
    /// intent advances the fence even when its subsequent content commit fails.
    public func acceptLocalIntent(operationID: UUID = UUID()) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = try load()
        if previous?.operationID == operationID { throw Failure.conflictingOperation }
        try save(.init(operationID: operationID, generation: UUID(), deployments: previous?.deployments))
    }
    /// Retains accepted deployment identities across selection/removal and process restart.
    /// A previous deployment cannot silently resurrect content after explicit removal.
    /// Live-current retries are answered by the LAN content receipt before this call.
    public func acceptLocalDeployment(key: String, digest: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !key.isEmpty, key.utf8.count <= 1024, digest.utf8.count == 64 else { throw Failure.conflictingOperation }
        let previous = try load()
        var deployments = previous?.deployments ?? []
        if let existing = deployments.first(where: { $0.key == key }) {
            guard existing.digest == digest else { throw Failure.conflictingOperation }
            throw Failure.needsReview
        }
        // Never evict dedup history to reopen old commands. Exhaustion requires review.
        guard deployments.count < 4096 else { throw Failure.needsReview }
        deployments.append(.init(key: key, digest: digest))
        try save(.init(operationID: UUID(), generation: UUID(), deployments: deployments))
    }
    /// The fixed Cloud owner calls this only for the original authenticated Cloud
    /// operation. A transport retry keeps its first fence and never becomes newer.
    public func acceptCloudDeployment(operationID: UUID, key: String, digest: String) throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        guard key.hasPrefix("cloud:"), key.utf8.count <= 1024, digest.utf8.count == 64 else { throw Failure.conflictingOperation }
        let previous = try load()
        var deployments = previous?.deployments ?? []
        if let existing = deployments.first(where: { $0.key == key }) {
            guard existing.digest == digest else { throw Failure.conflictingOperation }
            guard let originalGeneration = existing.intentGeneration, previous?.generation == originalGeneration,
                previous?.operationID == operationID else { throw Failure.needsReview }
            return .init(generation: originalGeneration)
        }
        guard deployments.count < 4096 else { throw Failure.needsReview }
        let generation = UUID()
        deployments.append(.init(key: key, digest: digest, intentGeneration: generation))
        try save(.init(operationID: operationID, generation: generation, deployments: deployments))
        return .init(generation: generation)
    }
    /// Read-only receipt lookup. A known accepted identity is not permission to
    /// replay; the caller must also prove the exact durable content receipt.
    public func knownDeployment(key: String, digest: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !key.isEmpty, key.utf8.count <= 1024, digest.utf8.count == 64 else { throw Failure.conflictingOperation }
        guard let existing = try load()?.deployments?.first(where: { $0.key == key }) else { return false }
        guard existing.digest == digest else { throw Failure.conflictingOperation }
        return true
    }
    public func requireUnchanged(_ checkpoint: Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard try load()?.generation == checkpoint.generation else { throw Failure.needsReview }
    }
    /// Only the fixed owner of a genuine completed inventory CAS records this association.
    public func recordCommittedInventory(checkpoint: Checkpoint, generationID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try load(), record.generation == checkpoint.generation else { throw Failure.needsReview }
        record.committedFence = checkpoint.generation
        record.committedInventoryGeneration = generationID
        try save(record)
    }
    /// Background recipes cannot capture the newest fence while its explicit command is pending.
    public func automationCheckpoint(baseGenerationID: UUID) throws -> Checkpoint {
        lock.lock(); defer { lock.unlock() }
        guard let record = try load(), record.committedFence == record.generation,
            record.committedInventoryGeneration == baseGenerationID else { throw Failure.needsReview }
        return .init(generation: record.generation)
    }
    private func save(_ record: Record) throws {
        try withRoot(create: true) { parent in
            try writeExact(parent, name: "command-intent.json", bytes: JSONEncoder().encode(record))
        }
    }
}
