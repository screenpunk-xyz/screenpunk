import Foundation
#if os(macOS)
import Darwin

struct WorkspaceNodeID: Equatable { let device: UInt64; let inode: UInt64; init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }; init(_ value: stat) { device = UInt64(value.st_dev); inode = value.st_ino } }

struct WorkspaceReadBudget {
    let deadline: TimeInterval
    let cancelled: () -> Bool
    func check() throws {
        guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else { throw WorkspaceError.unavailable }
    }
    func requireLocal(_ fd: Int32) throws {
        try check()
        var info = statfs()
        guard fstatfs(fd, &info) == 0, info.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw WorkspaceError.unavailable
        }
    }
}

/// Descriptor-anchored fixed-layout IO. All portable metadata writes are one-file atomic,
/// serialized by a retained lock inode; multi-file F3 transactions are a later integration gate.
final class WorkspaceFiles {
    let fd: Int32
    let path: String
    let identity: WorkspaceNodeID
    private let requiredPrivateRoot: Bool
    init(path: String, create: Bool = false, requiredPrivateRoot: Bool = true) throws {
        guard WorkspaceValidation.absolute(path) else { throw WorkspaceError.invalidPath }
        self.path = path; self.requiredPrivateRoot = requiredPrivateRoot
        let parts = path.split(separator: "/").map(String.init)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw WorkspaceError.unavailable }
        do {
            for (index, part) in parts.enumerated() {
                if create && index == parts.count - 1 {
                    guard mkdirat(current, part, 0o700) == 0 else { throw errno == EEXIST ? WorkspaceError.alreadyExists : WorkspaceError.unavailable }
                }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw errno == ENOENT ? WorkspaceError.unavailable : WorkspaceError.unsafeFile }
                close(current); current = next
            }
            var metadata = stat()
            guard fstat(current, &metadata) == 0, metadata.st_uid == geteuid(),
                  (requiredPrivateRoot ? metadata.st_mode & 0o7777 == 0o700 :
                      metadata.st_mode & 0o022 == 0 && metadata.st_mode & 0o7000 == 0)
            else { throw WorkspaceError.unsafeFile }
            fd = current; identity = WorkspaceNodeID(metadata)
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    func verifyRoot() throws {
        let fresh = try WorkspaceFiles(path: path, requiredPrivateRoot: requiredPrivateRoot)
        guard fresh.identity == identity else { throw WorkspaceError.unsafeFile }
    }
    func directory(_ parts: [String], create: Bool = false) throws -> Int32 {
        var current = dup(fd)
        guard current >= 0 else { throw WorkspaceError.unavailable }
        do {
            for part in parts {
                guard WorkspaceValidation.member(part), !part.contains("/") else { throw WorkspaceError.invalidPath }
                if create && mkdirat(current, part, 0o700) != 0 && errno != EEXIST { throw WorkspaceError.unavailable }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw WorkspaceError.unsafeFile }
                var metadata = stat()
                guard fstat(next, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0, metadata.st_mode & 0o7000 == 0 else { close(next); throw WorkspaceError.unsafeFile }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    func emptyDirectory(_ parts: [String]) throws -> Bool {
        let directoryFD = try directory(parts); defer { close(directoryFD) }
        let copy = dup(directoryFD)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(validatingUTF8: $0) }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name != "." && name != ".." { return false }
        }
        return true
    }
    func metadata(_ parent: Int32, _ name: String) throws -> stat {
        guard WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.invalidPath }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o022 == 0, info.st_mode & 0o7000 == 0, info.st_nlink == 1 else { throw WorkspaceError.unsafeFile }
        return info
    }
    func read(_ parent: Int32, _ name: String, maxBytes: Int = 8 * 1024 * 1024,
              readBudget: WorkspaceReadBudget? = nil) throws -> Data {
        try readBudget?.check()
        let before = try metadata(parent, name)
        guard before.st_size >= 0, before.st_size <= maxBytes else { throw WorkspaceError.limitExceeded }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw WorkspaceError.unsafeFile }
        defer { close(file) }
        try readBudget?.requireLocal(file)
        var opened = stat()
        guard fstat(file, &opened) == 0, WorkspaceNodeID(opened) == WorkspaceNodeID(before), opened.st_nlink == 1 else { throw WorkspaceError.unsafeFile }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try readBudget?.check()
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorkspaceError.unavailable }
            if count == 0 { break }
            guard result.count + count <= maxBytes else { throw WorkspaceError.limitExceeded }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard WorkspaceNodeID(try metadata(parent, name)) == WorkspaceNodeID(before) else { throw WorkspaceError.conflict }
        return result
    }
    func exists(_ parent: Int32, _ name: String) throws -> Bool {
        var s = stat()
        if fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw WorkspaceError.unsafeFile }
        return false
    }
    func write(_ parent: Int32, _ name: String, data: Data, expected: WorkspaceNodeID?) throws {
        guard data.count <= 8 * 1024 * 1024, WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.limitExceeded }
        let current = try exists(parent, name) ? WorkspaceNodeID(metadata(parent, name)) : nil
        guard current == expected else { throw WorkspaceError.conflict }
        let temp = ".screenpunk-" + UUID().uuidString.lowercased()
        let file = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw WorkspaceError.unavailable }
        defer { close(file); _ = unlinkat(parent, temp, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkspaceError.unavailable }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw WorkspaceError.unavailable }
        let again = try exists(parent, name) ? WorkspaceNodeID(metadata(parent, name)) : nil
        guard again == expected else { throw WorkspaceError.conflict }
        try verifyRoot()
        guard renameat(parent, temp, parent, name) == 0, fsync(parent) == 0 else { throw WorkspaceError.unavailable }
    }
    func locked<T>(readBudget: WorkspaceReadBudget? = nil, _ action: () throws -> T) throws -> T {
        try readBudget?.requireLocal(fd)
        let name = ".screenpunk.lock"
        let lock = openat(fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WorkspaceError.unsafeFile }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let before = try metadata(fd, name)
        guard before.st_mode & 0o7777 == 0o600 else { throw WorkspaceError.unsafeFile }
        var opened = stat()
        guard fstat(lock, &opened) == 0, WorkspaceNodeID(opened) == WorkspaceNodeID(before) else { throw WorkspaceError.unsafeFile }
        if let readBudget {
            while true {
                try readBudget.check()
                if flock(lock, LOCK_EX | LOCK_NB) == 0 { break }
                guard errno == EWOULDBLOCK || errno == EINTR else { throw WorkspaceError.unsafeFile }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } else {
            while flock(lock, LOCK_EX) != 0 {
                guard errno == EINTR else { throw WorkspaceError.unsafeFile }
            }
        }
        try readBudget?.check()
        try verifyRoot()
        guard WorkspaceNodeID(try metadata(fd, name)) == WorkspaceNodeID(before) else { throw WorkspaceError.conflict }
        return try action()
    }
}
#endif
