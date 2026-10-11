import Foundation
import Darwin

/// A local reminder of an admitted or uncertain GUI Apply. It is saved before
/// submission so a lost response or app restart cannot silently offer a new
/// plan for the same device. Broker operation/receipt state remains authority.
struct MacBrokerApplyJournal {
    enum Failure: Error, Equatable { case unsafePath, invalidRecord, conflict, io }
    private static let maximumBytes = 16 * 1024
    struct Record: Codable, Equatable {
        var workspaceId: String
        var selectionGeneration: Int
        var deviceId: String
        var planId: String
        var planHash: String
        var idempotencyKey: String
        var operationId: String?
        var phase: Phase
        enum Phase: String, Codable { case submitting, unknown, admitted, sending, received, active, failed, cancelled }
        var blocksNewApply: Bool {
            switch phase {
            case .submitting, .unknown, .admitted, .sending, .received: true
            case .active, .failed, .cancelled: false
            }
        }
    }

    let url: URL

    func load() throws -> Record? {
        guard let directory = try openDirectory(create: false) else { return nil }
        defer { Darwin.close(directory) }
        let file = openat(directory, try fileName(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        if file < 0 && errno == ELOOP { throw Failure.unsafePath }
        guard file >= 0 else { throw Failure.io }
        defer { Darwin.close(file) }
        try validateFile(file)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(file, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw Failure.io }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumBytes else { throw Failure.invalidRecord }
        }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    /// Reserve the one durable Apply slot before any broker submission. The
    /// lock is a stable inode, separate from the atomically replaced record.
    func begin(_ attempt: Record) throws {
        try withAdmissionLock {
            if let current = try load(), current.blocksNewApply { throw Failure.conflict }
            var submitting = attempt
            submitting.phase = .submitting
            submitting.operationId = nil
            try save(submitting)
        }
    }

    /// Only the process holding the exact previously observed record may
    /// advance it. A stale status response cannot replace another attempt.
    func transition(from expected: Record, to updated: Record) throws {
        guard expected.workspaceId == updated.workspaceId,
              expected.selectionGeneration == updated.selectionGeneration,
              expected.deviceId == updated.deviceId, expected.planId == updated.planId,
              expected.planHash == updated.planHash,
              expected.idempotencyKey == updated.idempotencyKey,
              expected.operationId == nil || expected.operationId == updated.operationId,
              expected.blocksNewApply || !updated.blocksNewApply else { throw Failure.conflict }
        try withAdmissionLock {
            guard try load() == expected else { throw Failure.conflict }
            try save(updated)
        }
    }

    private func withAdmissionLock<T>(_ body: () throws -> T) throws -> T {
        guard let directory = try openDirectory(create: true) else { throw Failure.io }
        defer { Darwin.close(directory) }
        let name = ".\(try fileName()).lock"
        let lock = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure.unsafePath }
        defer { Darwin.close(lock) }
        try validateFile(lock)
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.io }
        defer { _ = flock(lock, LOCK_UN) }
        return try body()
    }

    private func save(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumBytes else { throw Failure.invalidRecord }
        guard let directory = try openDirectory(create: true) else { throw Failure.io }
        defer { Darwin.close(directory) }
        let name = try fileName()
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_uid == geteuid(), existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  existing.st_nlink == 1 else { throw Failure.unsafePath }
        } else if errno != ENOENT { throw Failure.io }
        let temp = ".apply-\(UUID().uuidString.lowercased())"
        let file = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.io }
        defer { _ = unlinkat(directory, temp, 0) }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { throw Failure.io }
                    offset += written
                }
            }
            guard fsync(file) == 0 else { throw Failure.io }
        } catch {
            Darwin.close(file)
            throw error
        }
        Darwin.close(file)
        guard renameat(directory, temp, directory, name) == 0,
              fsync(directory) == 0 else { throw Failure.io }
    }

    private func fileName() throws -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw Failure.unsafePath
        }
        return name
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        let path = url.deletingLastPathComponent().path
        if create {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        var before = stat()
        if lstat(path, &before) != 0 {
            if !create && errno == ENOENT { return nil }
            throw Failure.io
        }
        guard before.st_uid == geteuid(), before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              before.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        let directory = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unsafePath }
        var after = stat()
        guard fstat(directory, &after) == 0, after.st_dev == before.st_dev,
              after.st_ino == before.st_ino else {
            Darwin.close(directory)
            throw Failure.unsafePath
        }
        return directory
    }

    private func validateFile(_ file: Int32) throws {
        var value = stat()
        guard fstat(file, &value) == 0, value.st_uid == geteuid(),
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_nlink == 1,
              value.st_mode & 0o077 == 0, value.st_size >= 0,
              value.st_size <= Self.maximumBytes else { throw Failure.unsafePath }
    }
}
