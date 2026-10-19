import Foundation
@_spi(NativeFilesystem) import ScreenpunkCore
import Darwin

/// Descriptor-bound preference replacement. Cooperating processes share the fixed flock;
/// this does not exclude an arbitrary same-UID external writer.
final class ScreenPreferenceAtomicWriter {
    static let archiveName = "preferences-v1.json"
    static let pendingName = "preferences-v1.pending"
    static let lockName = "preferences.lock"
    static let maximumBytes = 4 * 1024 * 1024
    enum Failure: Error, Equatable { case unsafeBinding, conflict, writeOutcomeUncertain; case io(operation: String, code: Int32) }
    enum Boundary: CaseIterable { case afterRootCreation, afterLockCreation, beforePendingRemoval, afterPendingRemoval, afterTemporaryCreation, afterProtection, afterPartialWrite, afterTemporaryWrite, afterFileSync, beforeReplace, afterReplace, afterDirectorySync }
    struct Identity: Equatable { let device: dev_t; let inode: ino_t; init(_ value: stat) { device = value.st_dev; inode = value.st_ino } }
    struct Snapshot: Equatable { let data: Data?; let identity: Identity? }
    fileprivate final class FileBinding {
        let descriptor: Int32
        init(duplicating descriptor: Int32) throws {
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw Failure.io(operation: "retainBinding", code: errno) }
            self.descriptor = duplicate
        }
        deinit { close(descriptor) }
    }
    final class Attempt {
        let root: Identity, lock: Identity
        let baseline: Snapshot
        let bytes: Data
        var pending: Identity?
        var installed: Snapshot?
        // Retained descriptors prevent inode reuse from masquerading as an original binding.
        private let directory: Directory
        private let lockBinding: FileBinding
        private let baselineBinding: FileBinding?
        fileprivate var pendingBinding: FileBinding?
        fileprivate var installedBinding: FileBinding?
        fileprivate init(directory: Directory, lock: Identity, lockDescriptor: Int32, baseline: Snapshot, baselineDescriptor: Int32?, bytes: Data) throws {
            self.directory = directory; root = directory.identity; self.lock = lock; self.baseline = baseline; self.bytes = bytes
            lockBinding = try .init(duplicating: lockDescriptor)
            baselineBinding = try baselineDescriptor.map { try FileBinding(duplicating: $0) }
        }
    }
    fileprivate final class Directory {
        let descriptor: Int32, identity: Identity, parent: Directory?, name: String?
        let traversalRootPath: String?
        init(_ descriptor: Int32, parent: Directory? = nil, name: String? = nil, traversalRootPath: String? = nil) throws {
            self.descriptor = descriptor; self.parent = parent; self.name = name; self.traversalRootPath = traversalRootPath
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { let code = errno; close(descriptor); throw Failure.io(operation: "fstat", code: code) }
            identity = .init(value)
        }
        deinit { close(descriptor) }
        func verify() throws {
            if let traversalRootPath {
                let current = Darwin.open(traversalRootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard current >= 0 else { throw Failure.unsafeBinding }
                defer { close(current) }
                var named = stat(), held = stat()
                guard fstat(current, &named) == 0, fstat(descriptor, &held) == 0,
                      Identity(named) == identity, Identity(held) == identity else { throw Failure.unsafeBinding }
            }
            if let parent, let name {
                try parent.verify()
                var value = stat()
                guard fstatat(parent.descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                      Identity(value) == identity, value.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeBinding }
            }
        }
        var path: String { parent.map { ($0.path == "/" ? "" : $0.path) + "/" + (name ?? "") } ?? (traversalRootPath ?? "/") }
        func sync() throws {
            try verify()
            guard fsync(descriptor) == 0 else { throw Failure.io(operation: "syncDirectory", code: errno) }
            try verify()
        }
    }
    private final class Setup {
        let lock = NSRecursiveLock()
        var active = false
        var outstanding: [Directory] = []
    }
    private static let setupLock = NSLock()
    private static var setups: [String: Setup] = [:]
    private static func setup(for path: String) -> Setup {
        setupLock.lock(); defer { setupLock.unlock() }
        if let existing = setups[path] { return existing }
        let value = Setup(); setups[path] = value; return value
    }
    let root: URL
    private let boundary: (Boundary) throws -> Void
    private let directorySyncObserved: (String) -> Void
    private let writeCall: (Int32, UnsafeRawPointer?, Int) -> Int
    init(root: URL, boundary: @escaping (Boundary) throws -> Void = { _ in },
         directorySyncObserved: @escaping (String) -> Void = { _ in },
         writeCall: @escaping (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) }) {
        self.root = Self.canonicalRoot(root); self.boundary = boundary; self.writeCall = writeCall; self.directorySyncObserved = directorySyncObserved
    }
    static func protectionReadbackMatches(_ observed: String?, required: String, simulator: Bool) -> Bool {
        observed.map { $0 == required } ?? simulator
    }
    static func canonicalRoot(_ root: URL) -> URL {
        guard root.isFileURL else { return root }
        var path = root.standardizedFileURL.path
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || path.hasPrefix(alias + "/") { path = target + path.dropFirst(alias.count) }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private func failure(_ operation: String) -> Failure { .io(operation: operation, code: errno) }
    private func validFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1
    }
    func withSession<T>(_ operation: (Session) throws -> T) throws -> T {
        guard root.isFileURL, root.path != "/", !root.path.utf8.contains(0) else { throw Failure.unsafeBinding }
        let setup = Self.setup(for: root.path)
        let directory: Directory = try {
            setup.lock.lock(); defer { setup.lock.unlock() }
            guard !setup.active else { throw Failure.unsafeBinding }
            setup.active = true; defer { setup.active = false }
            func finishOutstanding() throws {
                while let created = setup.outstanding.first {
                    try created.verify()
                    directorySyncObserved(created.path); try created.sync()
                    if let parent = created.parent {
                        directorySyncObserved(parent.path); try parent.sync()
                    }
                    setup.outstanding.removeFirst()
                }
            }
            try finishOutstanding()
            let traversal: DeviceFilesystemTraversal
            do { traversal = try .plan(for: root.path) } catch { throw Failure.unsafeBinding }
            let descriptor = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw failure("openRoot") }
            var directory = try Directory(descriptor, traversalRootPath: traversal.rootPath)
            for component in traversal.components {
                try directory.verify()
                var created = false
                var child = openat(directory.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                if child < 0, errno == ENOENT {
                    if mkdirat(directory.descriptor, component, 0o700) == 0 { created = true }
                    else if errno != EEXIST { throw failure("mkdirat") }
                    child = openat(directory.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                }
                guard child >= 0 else { throw failure("openDirectory") }
                let next = try Directory(child, parent: directory, name: component)
                if created {
                    // Retain the exact descriptor binding before a post-create failure.
                    setup.outstanding.append(next)
                    try boundary(.afterRootCreation)
                    try finishOutstanding()
                }
                directory = next
            }
            return directory
        }()
        try directory.verify()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var rootURL = root; try rootURL.setResourceValues(values)
        try directory.verify()
        let lock = openat(directory.descriptor, Self.lockName, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw failure("openLock") }
        defer { close(lock) }
        var lockStat = stat()
        guard fstat(lock, &lockStat) == 0, validFile(lockStat) else { throw Failure.unsafeBinding }
        guard flock(lock, LOCK_EX) == 0 else { throw failure("flock") }
        defer { flock(lock, LOCK_UN) }
        guard fchmod(lock, 0o600) == 0, fsync(lock) == 0 else { throw failure("syncLock") }
        try boundary(.afterLockCreation)
        directorySyncObserved(directory.path); try directory.sync()
        let session = Session(writer: self, directory: directory, lock: Identity(lockStat), lockDescriptor: lock)
        defer { session.invalidate() }
        try session.verifyLock()
        return try operation(session)
    }
    final class Session {
        private let writer: ScreenPreferenceAtomicWriter
        private let directory: Directory
        private let lock: Identity
        private let lockDescriptor: Int32
        private var active = true
        fileprivate func invalidate() { active = false }
        fileprivate init(writer: ScreenPreferenceAtomicWriter, directory: Directory, lock: Identity, lockDescriptor: Int32) { self.writer = writer; self.directory = directory; self.lock = lock; self.lockDescriptor = lockDescriptor }
        fileprivate func verifyLock() throws {
            guard active else { throw Failure.unsafeBinding }
            try directory.verify()
            var value = stat()
            guard fstatat(directory.descriptor, ScreenPreferenceAtomicWriter.lockName, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  writer.validFile(value), Identity(value) == lock else { throw Failure.unsafeBinding }
        }
        func read() throws -> Snapshot {
            try verifyLock()
            let descriptor = openat(directory.descriptor, ScreenPreferenceAtomicWriter.archiveName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if descriptor < 0 {
                guard errno == ENOENT else { throw writer.failure("openArchive") }
                return .init(data: nil, identity: nil)
            }
            defer { close(descriptor) }
            var value = stat()
            guard fstat(descriptor, &value) == 0, writer.validFile(value), value.st_size >= 0,
                  value.st_size <= ScreenPreferenceAtomicWriter.maximumBytes else { throw Failure.unsafeBinding }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw writer.failure("readArchive") }
                if count == 0 { break }
                guard data.count + count <= ScreenPreferenceAtomicWriter.maximumBytes else { throw Failure.unsafeBinding }
                data.append(contentsOf: buffer.prefix(count))
            }
            var latest = stat()
            guard fstatat(directory.descriptor, ScreenPreferenceAtomicWriter.archiveName, &latest, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(latest) == Identity(value), writer.validFile(latest), latest.st_size == data.count else { throw Failure.unsafeBinding }
            return .init(data: data, identity: .init(value))
        }
        func attempt(bytes: Data, baseline: Snapshot) throws -> Attempt {
            var descriptor: Int32?
            defer { if let descriptor { close(descriptor) } }
            if let expected = baseline.identity {
                let opened = openat(directory.descriptor, ScreenPreferenceAtomicWriter.archiveName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard opened >= 0 else { throw writer.failure("retainArchive") }
                descriptor = opened
                var value = stat()
                guard fstat(opened, &value) == 0, writer.validFile(value), Identity(value) == expected else { throw Failure.conflict }
            }
            return try .init(directory: directory, lock: lock, lockDescriptor: lockDescriptor, baseline: baseline, baselineDescriptor: descriptor, bytes: bytes)
        }
        func commit(_ attempt: Attempt) throws {
            try verifyLock()
            guard attempt.root == directory.identity, attempt.lock == lock,
                  attempt.bytes.count <= ScreenPreferenceAtomicWriter.maximumBytes else { throw Failure.conflict }
            let current = try read()
            guard current == attempt.baseline || current == attempt.installed else { throw Failure.conflict }
            var pendingStat = stat()
            if fstatat(directory.descriptor, ScreenPreferenceAtomicWriter.pendingName, &pendingStat, AT_SYMLINK_NOFOLLOW) == 0 {
                guard writer.validFile(pendingStat), pendingStat.st_mode & 0o777 == 0o600,
                      attempt.pending == nil || attempt.pending == Identity(pendingStat) else { throw Failure.unsafeBinding }
                try writer.boundary(.beforePendingRemoval)
                guard unlinkat(directory.descriptor, ScreenPreferenceAtomicWriter.pendingName, 0) == 0 else { throw writer.failure("removePending") }
                try writer.boundary(.afterPendingRemoval)
                try directory.sync()
                attempt.pending = nil; attempt.pendingBinding = nil
            } else if errno != ENOENT { throw writer.failure("inspectPending") }
            try verifyLock()
            var descriptor = openat(directory.descriptor, ScreenPreferenceAtomicWriter.pendingName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw writer.failure("createPending") }
            defer { if descriptor >= 0 { close(descriptor) } }
            var temporary = stat()
            guard fstat(descriptor, &temporary) == 0, writer.validFile(temporary) else { throw Failure.unsafeBinding }
            attempt.pending = Identity(temporary)
            attempt.pendingBinding = try FileBinding(duplicating: descriptor)
            try writer.boundary(.afterTemporaryCreation)
            guard fchmod(descriptor, 0o600) == 0 else { throw writer.failure("chmodPending") }
            func verifyTemporary(size: Int? = nil) throws {
                try verifyLock()
                var value = stat()
                guard fstatat(directory.descriptor, ScreenPreferenceAtomicWriter.pendingName, &value, AT_SYMLINK_NOFOLLOW) == 0,
                      writer.validFile(value), Identity(value) == attempt.pending, (size.map { value.st_size == off_t($0) } ?? true) else { throw Failure.unsafeBinding }
            }
            try verifyTemporary(size: 0)
            #if os(iOS)
            // Public Foundation policy, applied and verified while the file is still empty.
            let path = writer.root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName).path
            let protection = FileProtectionType.completeUntilFirstUserAuthentication
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: path)
            try verifyTemporary(size: 0)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let observedProtection = (attributes[.protectionKey] as? FileProtectionType)
                ?? (attributes[.protectionKey] as? String).map(FileProtectionType.init(rawValue:))
            #if targetEnvironment(simulator)
            // Simulator may omit protection metadata after successful assignment. This is
            // an observability accommodation, not physical-device protection qualification.
            let simulator = true
            #else
            let simulator = false
            #endif
            guard ScreenPreferenceAtomicWriter.protectionReadbackMatches(observedProtection?.rawValue, required: protection.rawValue, simulator: simulator) else { throw Failure.unsafeBinding }
            #endif
            try verifyTemporary(size: 0)
            try writer.boundary(.afterProtection)
            try attempt.bytes.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = writer.writeCall(descriptor, bytes.baseAddress!.advanced(by: written), min(16_384, bytes.count - written))
                    if count < 0 { if errno == EINTR { continue }; throw writer.failure("writePending") }
                    guard count > 0 else { throw Failure.io(operation: "writePending", code: EIO) }
                    written += count
                    try writer.boundary(.afterPartialWrite)
                }
            }
            try writer.boundary(.afterTemporaryWrite)
            try verifyTemporary(size: attempt.bytes.count)
            guard fsync(descriptor) == 0 else { throw writer.failure("syncPending") }
            try writer.boundary(.afterFileSync)
            let closed = close(descriptor); descriptor = -1
            guard closed == 0 else { throw writer.failure("closePending") }
            try writer.boundary(.beforeReplace)
            try verifyTemporary(size: attempt.bytes.count)
            let beforeReplace = try read()
            guard beforeReplace == attempt.baseline || beforeReplace == attempt.installed else { throw Failure.conflict }
            guard renameat(directory.descriptor, ScreenPreferenceAtomicWriter.pendingName, directory.descriptor, ScreenPreferenceAtomicWriter.archiveName) == 0 else { throw writer.failure("replaceArchive") }
            attempt.installed = .init(data: attempt.bytes, identity: attempt.pending)
            attempt.installedBinding = attempt.pendingBinding
            attempt.pending = nil; attempt.pendingBinding = nil
            try writer.boundary(.afterReplace)
            try directory.sync()
            guard try read() == attempt.installed else { throw Failure.conflict }
            try writer.boundary(.afterDirectorySync)
        }
    }
}
