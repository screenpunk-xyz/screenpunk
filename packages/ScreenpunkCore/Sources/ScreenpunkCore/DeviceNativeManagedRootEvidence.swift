import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DeviceNativeManagedRootFailure: Error, Equatable {
    case invalidLocator, unavailable(Int32), changedAnchor, changedNamespace
}

/// Fixed namespace under an existing physical anchor; not a store binding or
/// permission to initialize, migrate, delete or adopt managed files.
public struct DeviceNativeManagedRootLocator: Sendable {
    public static let namespaceName = "xyz.screenpunk.native-managed"
    public static let futureChildNames = ["packages", "grants", "structural", "provisioning"]
    public static let maximumPathBytes = 4096
    public static let maximumComponents = 64
    fileprivate let path: String
    fileprivate let components: [String]
    public var anchorURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var namespaceURL: URL { anchorURL.appendingPathComponent(Self.namespaceName, isDirectory: true) }
    private init(path: String, components: [String]) { self.path = path; self.components = components }

    /// Explicit caller paths are never silently standardized or realpath-rewritten.
    public static func existingPhysicalAnchor(_ url: URL) throws -> Self {
        let path = try boundedPath(url)
        guard let resolved = realpath(path, nil) else { throw DeviceNativeManagedRootFailure.unavailable(errno) }
        defer { free(resolved) }
        let count = strnlen(resolved, maximumPathBytes + 1)
        guard count <= maximumPathBytes else { throw DeviceNativeManagedRootFailure.invalidLocator }
        let physical = String(cString: resolved)
        guard path.utf8.elementsEqual(physical.utf8) else { throw DeviceNativeManagedRootFailure.invalidLocator }
        return .init(path: path, components: path.split(separator: "/").map(String.init))
    }
    fileprivate static func boundedPath(_ url: URL) throws -> String {
        // Bound the URL spelling before URLComponents/path decoding allocations.
        guard url.isFileURL, url.baseURL == nil,
            url.absoluteString.utf8.prefix(16_385).count <= 16_384,
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
            (c.host == nil || c.host == ""), c.user == nil, c.password == nil, c.port == nil,
            c.query == nil, c.fragment == nil,
            let raw = c.percentEncodedPath.removingPercentEncoding,
            raw.utf8.prefix(maximumPathBytes + 1).count <= maximumPathBytes,
            !raw.utf8.contains(0) else { throw DeviceNativeManagedRootFailure.invalidLocator }
        // Foundation directory URLs may include one trailing slash. It is not a
        // path-component alias; repeated separators and dot components are refused.
        let path = raw.hasSuffix("/") && raw != "/" ? String(raw.dropLast()) : raw
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path != "/", !path.contains("//"),
            !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            parts.count - 1 <= maximumComponents,
            path.utf8.count + 1 + namespaceName.utf8.count <= maximumPathBytes else {
            throw DeviceNativeManagedRootFailure.invalidLocator
        }
        return path
    }
}

/// Genuine descriptor observation only, privately constructed. Equality includes
/// exact path/name bytes and every checked ancestor identity. It acknowledges no
/// durability or future absence; re-observe at each gate under the owner's lock.
public struct DeviceManagedNamespaceEvidence: Equatable, Sendable {
    public enum Classification: Equatable, Sendable { case confirmedAbsent, managedPresent }
    public let classification: Classification
    /// Exact descriptor-checked location only; this is not permission to create it.
    public var namespaceURL: URL { URL(fileURLWithPath: String(decoding: path, as: UTF8.self), isDirectory: true).appendingPathComponent(String(decoding: name, as: UTF8.self), isDirectory: true) }
    public func hasSameCheckedAnchor(as other: Self) -> Bool {
        path == other.path && name == other.name && ancestors == other.ancestors
    }
    fileprivate let path: Data
    fileprivate let name: Data
    fileprivate let ancestors: [ManagedDirectoryIdentity]
    fileprivate let namespace: ManagedDirectoryIdentity?
    fileprivate init(locator: DeviceNativeManagedRootLocator, ancestors: [ManagedDirectoryIdentity], namespace: ManagedDirectoryIdentity?) {
        classification = namespace == nil ? .confirmedAbsent : .managedPresent
        path = Data(locator.path.utf8); name = Data(DeviceNativeManagedRootLocator.namespaceName.utf8)
        self.ancestors = ancestors; self.namespace = namespace
    }
}

/// Noncreating, concrete inspector. Only namespace ENOENT below a fully checked
/// existing physical anchor yields absence. Any namespace object, including a
/// dangling symlink, empty directory or orphan, yields managedPresent.
///
/// Cooperating writers must use the same Apple authority serialization. The
/// owner must retain initial evidence and sticky managed/error highwater: a
/// previously present namespace disappearing is never a fresh legacy absence.
/// This is an inode/descriptor observation, not hostile same-UID or antirollback
/// protection, a retained FD lease, or permission for filesystem effects.
public struct DeviceManagedNamespaceInspector: Sendable {
    private enum Location: Sendable { case production, fixture(DeviceNativeManagedRootLocator) }
    private let location: Location
    private init(_ location: Location) { self.location = location }
    public static func production() -> Self { .init(.production) }
    public static func fixture(existingPhysicalAnchor: URL) throws -> Self {
        .init(.fixture(try .existingPhysicalAnchor(existingPhysicalAnchor)))
    }
    public func inspect() throws -> DeviceManagedNamespaceEvidence {
        let locator: DeviceNativeManagedRootLocator
        switch location {
        case .fixture(let fixed): locator = fixed
        case .production:
            let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let path = try DeviceNativeManagedRootLocator.boundedPath(url)
            // Only the system-provided support locator may resolve platform aliases
            // (e.g. /var -> /private/var). Explicit fixture locators cannot do so.
            guard let physical = realpath(path, nil) else { throw DeviceNativeManagedRootFailure.unavailable(errno) }
            defer { free(physical) }
            guard strnlen(physical, DeviceNativeManagedRootLocator.maximumPathBytes + 1) <= DeviceNativeManagedRootLocator.maximumPathBytes else {
                throw DeviceNativeManagedRootFailure.invalidLocator
            }
            locator = try .existingPhysicalAnchor(URL(fileURLWithPath: String(cString: physical), isDirectory: true))
        }
        return try observe(locator)
    }
    private func observe(_ locator: DeviceNativeManagedRootLocator) throws -> DeviceManagedNamespaceEvidence {
        var descriptors: [Int32] = []
        defer { for fd in descriptors.reversed() { close(fd) } }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard root >= 0 else { throw DeviceNativeManagedRootFailure.unavailable(errno) }; descriptors.append(root)
        var identities = [try identity(root)], current = root
        for name in locator.components {
            var named = stat()
            guard fstatat(current, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw DeviceNativeManagedRootFailure.unavailable(errno) }
            guard named.st_mode & S_IFMT == S_IFDIR else { throw DeviceNativeManagedRootFailure.changedAnchor }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard next >= 0 else { throw DeviceNativeManagedRootFailure.unavailable(errno) }; descriptors.append(next)
            let observed = try identity(next)
            guard observed == ManagedDirectoryIdentity(named) else { throw DeviceNativeManagedRootFailure.changedAnchor }
            identities.append(observed); current = next
        }
        let first = try namespace(current)
        // Check every held FD and every parent/name link after namespace lookup.
        // A detached old anchor cannot return absence simply because its FD lives.
        let freshRoot = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard freshRoot >= 0 else { throw DeviceNativeManagedRootFailure.unavailable(errno) }
        defer { close(freshRoot) }
        guard try identity(freshRoot) == identities[0] else { throw DeviceNativeManagedRootFailure.changedAnchor }
        for i in descriptors.indices {
            guard try identity(descriptors[i]) == identities[i] else { throw DeviceNativeManagedRootFailure.changedAnchor }
            if i > 0 {
                var named = stat()
                guard fstatat(descriptors[i - 1], locator.components[i - 1], &named, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw DeviceNativeManagedRootFailure.unavailable(errno)
                }
                guard ManagedDirectoryIdentity(named) == identities[i] else { throw DeviceNativeManagedRootFailure.changedAnchor }
            }
        }
        guard try namespace(current) == first else { throw DeviceNativeManagedRootFailure.changedNamespace }
        return .init(locator: locator, ancestors: identities, namespace: first)
    }
    private func identity(_ fd: Int32) throws -> ManagedDirectoryIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw DeviceNativeManagedRootFailure.unavailable(errno) }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw DeviceNativeManagedRootFailure.changedAnchor }
        return ManagedDirectoryIdentity(value)
    }
    private func namespace(_ fd: Int32) throws -> ManagedDirectoryIdentity? {
        var value = stat()
        if fstatat(fd, DeviceNativeManagedRootLocator.namespaceName, &value, AT_SYMLINK_NOFOLLOW) == 0 { return ManagedDirectoryIdentity(value) }
        let code = errno
        guard code == ENOENT else { throw DeviceNativeManagedRootFailure.unavailable(code) }
        return nil
    }
}

fileprivate struct ManagedDirectoryIdentity: Equatable, Sendable {
    let device: UInt64, inode: UInt64, mode: UInt32, uid: UInt32, gid: UInt32
    init(_ value: stat) {
        device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(truncatingIfNeeded: value.st_ino)
        mode = UInt32(truncatingIfNeeded: value.st_mode); uid = UInt32(truncatingIfNeeded: value.st_uid); gid = UInt32(truncatingIfNeeded: value.st_gid)
    }
}
