import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DeviceLocalFilesystemCleanupError: Error, Equatable {
    case invalidAuthorization, invalidPlan, unsupportedNode, changedDirectory, crossedMount, capacityExceeded
    case io(operation: String, code: Int32)
}

/// A fixed caller-supplied scope. Never construct it from journal-supplied paths.
public struct DeviceLocalFilesystemCleanupPlan: Sendable {
    public enum Mode: Equatable, Sendable { case directoryContents, namedFiles([String]) }
    public struct Root: Sendable {
        public let directory: URL
        public let mode: Mode
        public init(directory: URL, mode: Mode) { self.directory = directory; self.mode = mode }
    }
    public let anchor: URL
    public let roots: [Root]
    public let protectedRoots: [URL]
    public let maximumDepth: Int
    public let maximumEntries: Int
    /// Stable versioned metadata for a future reset scope digest, including cleanup semantics.
    public let canonicalMetadata: Data

    public init(anchor: URL, roots: [Root], protectedRoots: [URL], maximumDepth: Int = 32, maximumEntries: Int = 10_000) throws {
        func valid(_ url: URL) -> Bool {
            url.isFileURL && url.path.utf8.count <= 4096 && url.path.split(separator: "/").count <= 128 && url.path.hasPrefix("/") && url.path != "/" && !url.path.utf8.contains(0) &&
            !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) && !url.path.contains("//")
        }
        guard valid(anchor), !roots.isEmpty, roots.count <= 32, protectedRoots.count <= 32,
              (1...128).contains(maximumDepth), (1...1_000_000).contains(maximumEntries),
              roots.allSatisfy({ valid($0.directory) }), protectedRoots.allSatisfy(valid) else { throw DeviceLocalFilesystemCleanupError.invalidPlan }
        func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent + "/") }
        var metadataRoots: [[String: Any]] = []
        for (index, root) in roots.enumerated() {
            let path = root.directory.path
            guard path != anchor.path, contains(anchor.path, path),
                  !protectedRoots.contains(where: { contains(path, $0.path) || contains($0.path, path) }),
                  !roots[..<index].contains(where: { contains(path, $0.directory.path) || contains($0.directory.path, path) }) else { throw DeviceLocalFilesystemCleanupError.invalidPlan }
            switch root.mode {
            case .directoryContents: metadataRoots.append(["directory": path, "mode": "directoryContents"])
            case .namedFiles(let names):
                guard !names.isEmpty, names.count <= maximumEntries, Set(names).count == names.count,
                      names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0) && $0.utf8.count <= 255 }) else { throw DeviceLocalFilesystemCleanupError.invalidPlan }
                metadataRoots.append(["directory": path, "mode": "namedFiles", "names": names.sorted()])
            }
        }
        self.anchor = anchor; self.roots = roots.sorted { $0.directory.path < $1.directory.path }
        self.protectedRoots = protectedRoots.sorted { $0.path < $1.path }
        self.maximumDepth = maximumDepth; self.maximumEntries = maximumEntries
        canonicalMetadata = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "anchor": anchor.path,
            "roots": metadataRoots.sorted { ($0["directory"] as! String) < ($1["directory"] as! String) },
            "protectedRoots": protectedRoots.map(\.path).sorted(), "maximumDepth": maximumDepth, "maximumEntries": maximumEntries], options: [.sortedKeys])
    }
}

/// No-follow deletion beneath fixed roots; roots themselves are retained. All application writers
/// must already be suspended. Descriptor binding does not promise atomic inode-conditional unlink
/// against an arbitrary same-UID process concurrently renaming/replacing filesystem entries.
public final class DeviceLocalFilesystemCleanup {
    enum Boundary { case beforeInspect, afterOpen, beforeEnumerate, beforeUnlink, afterUnlink, beforeSync, afterSync }
    private let plan: DeviceLocalFilesystemCleanupPlan
    private let fixtureTraversalRoot: String?
    private let boundary: (Boundary, String) throws -> Void
    private let observedDevice: (String, dev_t) -> dev_t
    public init(plan: DeviceLocalFilesystemCleanupPlan) { self.plan = plan; fixtureTraversalRoot = nil; boundary = { _, _ in }; observedDevice = { _, device in device } }
    init(plan: DeviceLocalFilesystemCleanupPlan, fixtureTraversalRoot: String? = nil, observedDevice: @escaping (String, dev_t) -> dev_t = { _, device in device }, boundary: @escaping (Boundary, String) throws -> Void) {
        self.plan = plan; self.fixtureTraversalRoot = fixtureTraversalRoot; self.observedDevice = observedDevice; self.boundary = boundary
    }

    private func traversal(for path: String) throws -> DeviceFilesystemTraversal {
        if let root = fixtureTraversalRoot { return try .confined(path: path, systemHome: root, physicalHome: root) }
        return try .plan(for: path)
    }

    private final class Directory {
        let fd: Int32
        let path: String
        let parent: Directory?
        let name: String?
        let identity: stat
        init(fd: Int32, path: String, parent: Directory? = nil, name: String? = nil) throws {
            self.fd = fd; self.path = path; self.parent = parent; self.name = name
            var value = stat()
            guard fstat(fd, &value) == 0 else { let code = errno; close(fd); throw DeviceLocalFilesystemCleanupError.io(operation: "fstat", code: code) }
            identity = value
        }
        deinit { close(fd) }
    }
    private func identityKey(_ value: stat) -> String { "\(value.st_dev):\(value.st_ino)" }
    private func failure(_ operation: String) -> DeviceLocalFilesystemCleanupError { .io(operation: operation, code: errno) }
    private func verify(_ directory: Directory) throws {
        if directory.parent == nil {
            let current = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard current >= 0 else { throw failure("openTraversalRoot") }; defer { close(current) }
            var named = stat(), held = stat()
            guard fstat(current, &named) == 0, fstat(directory.fd, &held) == 0,
                  named.st_dev == directory.identity.st_dev, named.st_ino == directory.identity.st_ino,
                  held.st_dev == directory.identity.st_dev, held.st_ino == directory.identity.st_ino,
                  named.st_mode & S_IFMT == S_IFDIR else { throw DeviceLocalFilesystemCleanupError.changedDirectory }
        }
        if let parent = directory.parent, let name = directory.name {
            try verify(parent)
            var value = stat()
            guard fstatat(parent.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  value.st_dev == directory.identity.st_dev, value.st_ino == directory.identity.st_ino,
                  value.st_mode & S_IFMT == S_IFDIR else { throw DeviceLocalFilesystemCleanupError.changedDirectory }
        }
    }
    private func sync(_ directory: Directory) throws {
        try verify(directory); try boundary(.beforeSync, directory.path); try verify(directory)
        guard fsync(directory.fd) == 0 else { throw failure("fsync") }
        try boundary(.afterSync, directory.path); try verify(directory)
    }
    /// Missing components are successful only after syncing the nearest existing parent.
    private func descend(_ start: Directory, components: [String], device: dev_t? = nil, protected: Set<String> = []) throws -> Directory? {
        var current = start
        for name in components {
            try verify(current)
            let fd = openat(current.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            if fd < 0 {
                if errno == ENOENT { try sync(current); return nil }
                throw failure("openat")
            }
            let next = try Directory(fd: fd, path: current.path == "/" ? "/" + name : current.path + "/" + name, parent: current, name: name)
            if let device, observedDevice(next.path, next.identity.st_dev) != device { throw DeviceLocalFilesystemCleanupError.crossedMount }
            guard !protected.contains(identityKey(next.identity)) else { throw DeviceLocalFilesystemCleanupError.invalidPlan }
            try boundary(.afterOpen, next.path); try verify(next); current = next
        }
        return current
    }
    private func names(_ directory: Directory) throws -> [String] {
        try verify(directory); try boundary(.beforeEnumerate, directory.path); try verify(directory)
        let fd = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("openat") }
        guard let stream = fdopendir(fd) else { let error = failure("fdopendir"); close(fd); throw error }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw failure("readdir") }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(validatingUTF8: $0) }
            }
            guard let name else { throw DeviceLocalFilesystemCleanupError.unsupportedNode }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= plan.maximumEntries else { throw DeviceLocalFilesystemCleanupError.capacityExceeded }
        }
        return result.sorted()
    }
    private func authorized(_ step: (() throws -> Void) throws -> Void, operation: () throws -> Void) throws {
        var calls = 0
        var repeated = false
        var operationError: Error?
        try withoutActuallyEscaping(operation) { operation in
            try step {
                calls += 1
                guard calls == 1 else {
                    repeated = true
                    throw DeviceLocalFilesystemCleanupError.invalidAuthorization
                }
                do { try operation() }
                catch { operationError = error; throw error }
            }
        }
        guard calls == 1, !repeated else { throw DeviceLocalFilesystemCleanupError.invalidAuthorization }
        if let operationError { throw operationError }
    }
    private func remove(_ name: String, from directory: Directory, depth: Int, allowDirectory: Bool, entries: inout Int, device: dev_t, protected: Set<String>, step: (() throws -> Void) throws -> Void) throws {
        entries += 1
        guard entries <= plan.maximumEntries, depth <= plan.maximumDepth else { throw DeviceLocalFilesystemCleanupError.capacityExceeded }
        let path = directory.path + "/" + name
        try verify(directory); try boundary(.beforeInspect, path); try verify(directory)
        var value = stat()
        if fstatat(directory.fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { try sync(directory); return }; throw failure("fstatat")
        }
        guard observedDevice(path, value.st_dev) == device else { throw DeviceLocalFilesystemCleanupError.crossedMount }
        let type = value.st_mode & S_IFMT
        if type == S_IFDIR {
            guard allowDirectory else { throw DeviceLocalFilesystemCleanupError.unsupportedNode }
            guard let child = try descend(directory, components: [name], device: device, protected: protected), child.identity.st_ino == value.st_ino else { throw DeviceLocalFilesystemCleanupError.changedDirectory }
            for entry in try names(child) { try remove(entry, from: child, depth: depth + 1, allowDirectory: true, entries: &entries, device: device, protected: protected, step: step) }
            try sync(child); try verify(child)
            try boundary(.beforeUnlink, path); try verify(child)
            try authorized(step) { try verify(child); guard unlinkat(directory.fd, name, AT_REMOVEDIR) == 0 else { throw failure("unlinkat") } }
        } else {
            guard type == S_IFREG || type == S_IFLNK else { throw DeviceLocalFilesystemCleanupError.unsupportedNode }
            try boundary(.beforeUnlink, path); try verify(directory)
            var latest = stat()
            guard fstatat(directory.fd, name, &latest, AT_SYMLINK_NOFOLLOW) == 0,
                  latest.st_dev == value.st_dev, latest.st_ino == value.st_ino, latest.st_mode & S_IFMT == type else { throw DeviceLocalFilesystemCleanupError.changedDirectory }
            try authorized(step) {
                try verify(directory)
                var observed = stat()
                guard fstatat(directory.fd, name, &observed, AT_SYMLINK_NOFOLLOW) == 0, observed.st_dev == value.st_dev, observed.st_ino == value.st_ino, observed.st_mode & S_IFMT == type else { throw DeviceLocalFilesystemCleanupError.changedDirectory }
                guard unlinkat(directory.fd, name, 0) == 0 else { throw failure("unlinkat") }
            }
        }
        try boundary(.afterUnlink, path); try sync(directory)
    }
    public func execute() throws { try execute(withDestructiveStep: { try $0() }) }
    /// Enforces exactly one synchronous invocation and propagates operation failure even if the wrapper swallows it.
    public func execute(withDestructiveStep step: (() throws -> Void) throws -> Void) throws {
        let traversal: DeviceFilesystemTraversal
        do { traversal = try self.traversal(for: plan.anchor.path) } catch { throw DeviceLocalFilesystemCleanupError.changedDirectory }
        let fd = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("open") }
        let filesystem = try Directory(fd: fd, path: traversal.rootPath)
        // Protected paths must also have no symlinked ancestor; absence is allowed.
        var protected = Set<String>()
        for path in plan.protectedRoots {
            let protectedTraversal: DeviceFilesystemTraversal
            do { protectedTraversal = try self.traversal(for: path.path) } catch { throw DeviceLocalFilesystemCleanupError.changedDirectory }
            guard protectedTraversal.rootPath == traversal.rootPath else { throw DeviceLocalFilesystemCleanupError.changedDirectory }
            if let directory = try descend(filesystem, components: protectedTraversal.components) { protected.insert(identityKey(directory.identity)) }
        }
        guard let anchor = try descend(filesystem, components: traversal.components, protected: protected) else { return }
        var entries = 0
        for root in plan.roots {
            let relative = String(root.directory.path.dropFirst(plan.anchor.path.count + 1))
            guard let directory = try descend(anchor, components: relative.split(separator: "/").map(String.init), device: anchor.identity.st_dev, protected: protected) else { continue }
            switch root.mode {
            case .directoryContents:
                for name in try names(directory) { try remove(name, from: directory, depth: 1, allowDirectory: true, entries: &entries, device: anchor.identity.st_dev, protected: protected, step: step) }
            case .namedFiles(let names):
                for name in names.sorted() { try remove(name, from: directory, depth: 1, allowDirectory: false, entries: &entries, device: anchor.identity.st_dev, protected: protected, step: step) }
            }
            try sync(directory)
        }
    }
}
