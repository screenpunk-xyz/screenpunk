import Foundation
import Darwin
import ScreenpunkCore

/// Only the final system-derived Application Support directory may be created. The
/// owner serializes this operation before namespace inspection; no managed files,
/// recursive parents, identifiers or migration are created here.
public final class DeviceProductionSupportAnchorSetup: @unchecked Sendable {
    enum Failure: Error, Equatable { case invalidLocation, changedNode, uncertain, io(Int32) }
    enum Boundary: Equatable { case beforeCreate, afterCreate, beforeChildSync, afterChildSync, beforeParentSync, afterParentSync }
    private enum Location { case production, fixture(URL) }
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t, mode: mode_t, uid: uid_t, gid: gid_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; mode = value.st_mode; uid = value.st_uid; gid = value.st_gid }
    }
    private final class Binding {
        let names: [String], descriptors: [Int32], identities: [Identity]
        let child: Int32, childIdentity: Identity
        let created: Bool
        init(names: [String], descriptors: [Int32], identities: [Identity], child: Int32, childIdentity: Identity, created: Bool) {
            self.names = names; self.descriptors = descriptors; self.identities = identities
            self.child = child; self.childIdentity = childIdentity; self.created = created
        }
        deinit { close(child); for fd in descriptors.reversed() { close(fd) } }
    }
    private enum State { case idle, pending(Binding), ready(Binding), blocked }
    private let location: Location
    private let boundary: (Boundary) throws -> Void
    private var state: State = .idle
    private init(_ location: Location, boundary: @escaping (Boundary) throws -> Void = { _ in }) { self.location = location; self.boundary = boundary }
    public static func production() -> DeviceProductionSupportAnchorSetup { .init(.production) }
    /// A synthetic missing-final fixture, never a production locator override.
    public static func fixture(existingPhysicalParent: URL) throws -> DeviceProductionSupportAnchorSetup {
        let checked = try DeviceNativeManagedRootLocator.existingPhysicalAnchor(existingPhysicalParent)
        return .init(.fixture(checked.anchorURL))
    }
    static func fixture(existingPhysicalParent: URL, boundary: @escaping (Boundary) throws -> Void) throws -> DeviceProductionSupportAnchorSetup {
        let checked = try DeviceNativeManagedRootLocator.existingPhysicalAnchor(existingPhysicalParent)
        return .init(.fixture(checked.anchorURL), boundary: boundary)
    }
    var allowsNamespaceInspection: Bool {
        switch state { case .idle, .ready: return true; case .pending, .blocked: return false }
    }
    func validateForInspection() throws {
        switch state {
        case .idle: return // Explicit fixture inspection performs no setup.
        case .ready(let binding): try validateOrBlock(binding)
        case .pending: throw Failure.uncertain
        case .blocked: throw Failure.changedNode
        }
    }
    /// Internal: call only under the owning authority, never across await. Pending
    /// setup retains its exact open nodes; visible creation alone is not success.
    func prepare() throws {
        switch state {
        case .blocked: throw Failure.changedNode
        case .ready(let binding): try validateOrBlock(binding); return
        case .pending(let binding): try synchronize(binding); return
        case .idle: break
        }
        let parent: URL
        switch location {
        case .fixture(let fixed): parent = fixed
        case .production:
            let supplied = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            guard supplied.lastPathComponent == "Application Support" else { state = .blocked; throw Failure.invalidLocation }
            // Alias resolution is restricted to the system-derived parent locator.
            guard let raw = realpath(supplied.deletingLastPathComponent().path, nil) else { throw Failure.io(errno) }
            defer { free(raw) }
            guard strnlen(raw, 4097) <= 4096 else { state = .blocked; throw Failure.invalidLocation }
            parent = URL(fileURLWithPath: String(cString: raw), isDirectory: true)
        }
        var descriptors: [Int32] = [], identities: [Identity] = []
        var transferred = false
        defer { if !transferred { for fd in descriptors.reversed() { close(fd) } } }
        do {
            let names = parent.path.split(separator: "/").map(String.init)
            guard names.count <= 64, parent.path.utf8.count <= 4096 else { throw Failure.invalidLocation }
            let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw Failure.io(errno) }; descriptors.append(root); identities.append(try identity(root))
            for name in names {
                let fd = try openDirectory(descriptors.last!, name: name)
                descriptors.append(fd); identities.append(try identity(fd))
            }
            let fd = descriptors.last!
            var named = stat()
            let found = fstatat(fd, "Application Support", &named, AT_SYMLINK_NOFOLLOW)
            let created: Bool
            if found == 0 {
                guard named.st_mode & S_IFMT == S_IFDIR else { throw Failure.changedNode }
                created = false
            } else {
                guard errno == ENOENT else { throw Failure.io(errno) }
                // EEXIST after observation is a race, never an adoption path.
                try boundary(.beforeCreate)
                try validateParents(names: names, descriptors: descriptors, identities: identities)
                guard mkdirat(fd, "Application Support", 0o700) == 0 else { throw Failure.io(errno) }
                created = true
            }
            // Capture the created descriptor/inode before any injected post-create
            // failure. If capture itself fails, refuse unidentifiable own debris.
            let child: Int32
            do { child = try openDirectory(fd, name: "Application Support") }
            catch { state = .blocked; throw error }
            let childIdentity: Identity
            do { childIdentity = try identity(child) } catch { close(child); state = .blocked; throw error }
            let binding = Binding(names: names, descriptors: descriptors, identities: identities, child: child, childIdentity: childIdentity, created: created)
            transferred = true
            state = created ? .pending(binding) : .ready(binding)
            try validateOrBlock(binding)
            if created { try boundary(.afterCreate); try synchronize(binding) }
        } catch {
            if case .idle = state { state = .blocked }
            throw error
        }
    }
    private func synchronize(_ binding: Binding) throws {
        try validateOrBlock(binding)
        guard binding.created else { throw Failure.uncertain }
        try boundary(.beforeChildSync)
        guard fsync(binding.child) == 0 else { throw Failure.io(errno) }
        try boundary(.afterChildSync)
        try validateOrBlock(binding)
        try boundary(.beforeParentSync)
        guard fsync(binding.descriptors.last!) == 0 else { throw Failure.io(errno) }
        try boundary(.afterParentSync)
        try validateOrBlock(binding)
        state = .ready(binding)
    }
    private func validateOrBlock(_ binding: Binding) throws {
        do {
            try validateParents(names: binding.names, descriptors: binding.descriptors, identities: binding.identities)
            var child = stat()
            guard fstatat(binding.descriptors.last!, "Application Support", &child, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(child) == binding.childIdentity, try identity(binding.child) == binding.childIdentity else { throw Failure.changedNode }
        } catch { state = .blocked; throw error }
    }
    private func validateParents(names: [String], descriptors: [Int32], identities: [Identity]) throws {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.io(errno) }; defer { close(root) }
        guard try identity(root) == identities[0] else { throw Failure.changedNode }
        for index in descriptors.indices {
            guard try identity(descriptors[index]) == identities[index] else { throw Failure.changedNode }
            if index > 0 {
                var named = stat()
                guard fstatat(descriptors[index - 1], names[index - 1], &named, AT_SYMLINK_NOFOLLOW) == 0, Identity(named) == identities[index] else { throw Failure.changedNode }
            }
        }
    }
    private func identity(_ fd: Int32) throws -> Identity {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw Failure.io(errno) }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw Failure.changedNode }
        return .init(value)
    }
    private func openDirectory(_ parent: Int32, name: String) throws -> Int32 {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io(errno) }
        guard named.st_mode & S_IFMT == S_IFDIR else { throw Failure.changedNode }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io(errno) }
        do { guard try identity(fd) == Identity(named) else { throw Failure.changedNode }; return fd }
        catch { close(fd); throw error }
    }
}
