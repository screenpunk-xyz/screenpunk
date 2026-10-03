import Foundation
#if os(macOS)
import Darwin

struct WorkbenchFileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    init(_ s: stat) { device = s.st_dev; inode = s.st_ino }
}
struct WorkbenchRuntimeLocator: Codable, Equatable {
    let apiVersion: String
    let instanceId: String
    let socketFile: String
    let tokenFile: String
    init(instanceId: String) {
        apiVersion = "1.0"; self.instanceId = instanceId; socketFile = "broker.sock"; tokenFile = "broker.token"
    }
}
final class WorkbenchRuntimeDirectory {
    let fd: Int32
    let environment: WorkbenchBrokerEnvironment
    let identity: WorkbenchFileIdentity
    init(environment: WorkbenchBrokerEnvironment, create: Bool) throws {
        self.environment = environment
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        let components = environment.runtimeDirectory.path.split(separator: "/").map(String.init)
        do {
            for (i, name) in components.enumerated() {
                if create && i == components.count - 1 {
                    if mkdirat(current, name, 0o700) != 0 && errno != EEXIST { throw WorkbenchIPCError(.insecureRuntime) }
                }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw WorkbenchIPCError(create ? .insecureRuntime : .unavailable) }
                close(current); current = next
            }
            var s = stat()
            guard fstat(current, &s) == 0, s.st_uid == environment.ownerUID,
                  s.st_mode & 0o7777 == 0o700 else { throw WorkbenchIPCError(.insecureRuntime) }
            identity = WorkbenchFileIdentity(s); fd = current
        } catch { close(current); throw error }
    }
    deinit { close(fd) }
    func revalidatePath() throws {
        let fresh = try WorkbenchRuntimeDirectory(environment: environment, create: false)
        guard identity == fresh.identity else { throw WorkbenchIPCError(.insecureRuntime) }
    }
    func identity(of name: String, socket: Bool = false) throws -> WorkbenchFileIdentity {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
              s.st_uid == environment.ownerUID, s.st_mode & 0o7777 == 0o600,
              s.st_mode & mode_t(S_IFMT) == mode_t(socket ? S_IFSOCK : S_IFREG),
              s.st_nlink == 1 else { throw WorkbenchIPCError(.insecureRuntime) }
        return WorkbenchFileIdentity(s)
    }
    func lock() throws -> Int32 {
        let lock = openat(fd, "broker.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        do {
            var s = stat()
            guard fstat(lock, &s) == 0, s.st_uid == environment.ownerUID,
                  s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_mode & 0o7777 == 0o600,
                  s.st_nlink == 1, try identity(of: "broker.lock") == WorkbenchFileIdentity(s)
            else { throw WorkbenchIPCError(.insecureRuntime) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WorkbenchIPCError(.alreadyRunning) }
            return lock
        } catch { close(lock); throw error }
    }
    /// Only startup/failed-start cleanup under the retained exclusive lock may use this policy.
    /// bind creates 0777 masked by any inherited umask; publication subsequently requires 0600.
    /// This never changes the strict policy used by clients, regular files or published cleanup.
    func unpublishedSocketIdentity() throws -> WorkbenchFileIdentity {
        var s = stat()
        guard fstatat(fd, "broker.sock", &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        return try Self.validateUnpublishedSocket(s, ownerUID: environment.ownerUID)
    }
    static func validateUnpublishedSocket(_ s: stat, ownerUID: UInt32) throws -> WorkbenchFileIdentity {
        guard s.st_uid == ownerUID, s.st_nlink == 1,
              s.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              s.st_mode & 0o7000 == 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        return WorkbenchFileIdentity(s)
    }
    func removeUnpublishedSocket(matching expected: WorkbenchFileIdentity) throws {
        guard try unpublishedSocketIdentity() == expected else { throw WorkbenchIPCError(.insecureRuntime) }
        guard unlinkat(fd, "broker.sock", 0) == 0 else { throw WorkbenchIPCError(.insecureRuntime) }
    }
    func removeStaleInstance() throws {
        // Caller holds the exclusive kernel lock in this verified private directory. Validate
        // every fixed stale member first so an unsafe socket preserves otherwise valid records.
        var stale: [(String, WorkbenchFileIdentity, Bool)] = []
        for (name, socket) in [("broker.locator.json", false), ("broker.local-token", false),
                               ("broker.token", false), ("broker.sock", true)] {
            var s = stat()
            if fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw WorkbenchIPCError(.insecureRuntime) }; continue
            }
            let id = try socket ? unpublishedSocketIdentity() : identity(of: name)
            stale.append((name, id, socket))
        }
        for (name, id, socket) in stale {
            if socket { try removeUnpublishedSocket(matching: id) }
            else { try remove(name, matching: id) }
        }
    }
    func create(_ name: String, bytes: Data) throws -> WorkbenchFileIdentity {
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        defer { close(file) }
        var offset = 0
        try bytes.withUnsafeBytes { buffer in
            while offset < bytes.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkbenchIPCError(.unavailable) }; offset += count
            }
        }
        guard fsync(file) == 0 else { throw WorkbenchIPCError(.unavailable) }
        return try identity(of: name)
    }
    func read(_ name: String, maxBytes: Int) throws -> Data {
        let expected = try identity(of: name)
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
        defer { close(file) }
        var s = stat()
        guard fstat(file, &s) == 0, WorkbenchFileIdentity(s) == expected, s.st_nlink == 1,
              s.st_size >= 0, s.st_size <= maxBytes else { throw WorkbenchIPCError(.insecureRuntime) }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: min(4096, maxBytes + 1))
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorkbenchIPCError(.insecureRuntime) }
            if count == 0 { break }
            guard result.count + count <= maxBytes else { throw WorkbenchIPCError(.insecureRuntime) }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard try identity(of: name) == expected else { throw WorkbenchIPCError(.insecureRuntime) }
        return result
    }
    func locator() throws -> WorkbenchRuntimeLocator {
        let data = try read("broker.locator.json", maxBytes: 4096)
        let object = try WorkbenchWireJSON.object(data)
        guard Set(object.keys) == ["apiVersion", "instanceId", "socketFile", "tokenFile"],
              object["apiVersion"] as? String == "1.0", object["socketFile"] as? String == "broker.sock",
              object["tokenFile"] as? String == "broker.token", let instance = object["instanceId"] as? String,
              UUID(uuidString: instance) != nil else { throw WorkbenchIPCError(.insecureRuntime) }
        return WorkbenchRuntimeLocator(instanceId: instance)
    }
    func remove(_ name: String, matching expected: WorkbenchFileIdentity, socket: Bool = false) throws {
        guard try identity(of: name, socket: socket) == expected else { throw WorkbenchIPCError(.insecureRuntime) }
        guard unlinkat(fd, name, 0) == 0 else { throw WorkbenchIPCError(.insecureRuntime) }
    }
}
#endif
