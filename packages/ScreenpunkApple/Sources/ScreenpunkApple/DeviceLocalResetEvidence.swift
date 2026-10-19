import Foundation
import Darwin
@_spi(NativeFilesystem) @_spi(NativeInstallation) import ScreenpunkCore

/// Configured bindings only; no paths or service names come from a reset record.
public struct DeviceLocalResetScope: Sendable {
    public struct CredentialItem: Codable, Hashable, Sendable {
        public let service: String
        public let account: String
        public init(service: String, account: String) { self.service = service; self.account = account }
    }
    public enum Failure: Error { case invalidPath, symlink, overlap, invalidCredentialBinding }
    static var allowedCredentialItems: [CredentialItem] {
        [.init(service: GoogleCalendarDeviceService.storageService, account: GoogleCalendarDeviceService.storageKey),
         .init(service: GenericConnectionDeviceVault.storageService, account: GenericConnectionDeviceVault.storageKey)] +
        HomeAssistantDeviceVault.storageKeys.map { .init(service: HomeAssistantDeviceVault.storageService, account: $0) }
    }
    public let deviceRoot: URL
    public let preferencesRoot: URL
    public let credentialItems: [CredentialItem]
    private let protectedDirectories: [URL]
    public let digest: String
    public init(deviceRoot: URL, preferencesRoot: URL, managementDirectory: URL, resetDirectory: URL,
                credentialItems: [CredentialItem]) throws {
        let device = try Self.canonical(deviceRoot), preferences = try Self.canonical(preferencesRoot)
        let protected = try [Self.canonical(managementDirectory), Self.canonical(resetDirectory)]
        let roots = [device, preferences]
        for root in roots {
            guard root.path != "/", !protected.contains(where: { Self.overlap(root, $0) }) else { throw Failure.overlap }
        }
        guard !Self.overlap(device, preferences), !Self.overlap(protected[0], protected[1]) else { throw Failure.overlap }
        guard Set(credentialItems).isSubset(of: Set(Self.allowedCredentialItems)),
              Set(credentialItems).count == credentialItems.count,
              credentialItems.allSatisfy({ !$0.service.isEmpty && !$0.account.isEmpty && $0.service != CloudInstallationCredentialStore.service && !$0.service.contains("\0") && !$0.account.contains("\0") }) else { throw Failure.invalidCredentialBinding }
        let items = credentialItems.sorted { ($0.service, $0.account) < ($1.service, $1.account) }
        struct Binding: Encodable { let version: Int; let device: String; let preferences: String; let management: String; let reset: String; let items: [CredentialItem] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(Binding(version: 1, device: device.path, preferences: preferences.path, management: protected[0].path, reset: protected[1].path, items: items))))
        self.deviceRoot = device; self.preferencesRoot = preferences; self.credentialItems = items; self.protectedDirectories = protected
    }
    /// Explicit opt-in only. Existing initializer/production binding remains v1.
    init(v2 base: Self, cleanupMetadata: Data) throws {
        deviceRoot = base.deviceRoot; preferencesRoot = base.preferencesRoot
        protectedDirectories = base.protectedDirectories; credentialItems = base.credentialItems
        struct Binding: Encodable { let version: Int; let baseDigest: String; let cleanupMetadata: Data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(Binding(version: 2, baseDigest: base.digest, cleanupMetadata: cleanupMetadata))))
    }
    init(v3 base: Self, cleanupMetadata: Data) throws {
        deviceRoot = base.deviceRoot; preferencesRoot = base.preferencesRoot
        protectedDirectories = base.protectedDirectories; credentialItems = base.credentialItems
        struct Binding: Encodable { let version: Int; let baseDigest: String; let cleanupMetadata: Data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(Binding(version: 3, baseDigest: base.digest, cleanupMetadata: cleanupMetadata))))
    }
    /// A v4 scope is explicit and binds the immutable original owned-resource
    /// manifest. Existing v1-v3 digests and pending records remain unchanged.
    init(v4 base: Self, cleanupMetadata: Data, manifest: DeviceFactoryResetManifest) throws {
        deviceRoot = base.deviceRoot; preferencesRoot = base.preferencesRoot
        protectedDirectories = base.protectedDirectories
        credentialItems = Array(Set(base.credentialItems + manifest.credentials.map { .init(service: $0.service, account: $0.account) })).sorted { ($0.service, $0.account) < ($1.service, $1.account) }
        struct Binding: Encodable { let version: Int; let baseDigest: String; let cleanupMetadata: Data; let manifestDigest: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = PeerPin.hex(PeerPin.sha256(try encoder.encode(Binding(version: 4, baseDigest: base.digest,
            cleanupMetadata: cleanupMetadata, manifestDigest: manifest.digest))))
    }
    var managementDirectory: URL { protectedDirectories[0] }
    var resetDirectory: URL { protectedDirectories[1] }
    func validateResetStoreDirectory(_ directory: URL) throws {
        guard try Self.canonical(directory) == resetDirectory else { throw Failure.invalidPath }
    }
    func validateCurrentPaths() throws {
        for directory in [deviceRoot, preferencesRoot] + protectedDirectories {
            guard try Self.canonical(directory) == directory else { throw Failure.invalidPath }
        }
    }
    private static func overlap(_ a: URL, _ b: URL) -> Bool {
        a.path == b.path || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/")
    }
    internal static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw Failure.invalidPath }
        var path = url.standardizedFileURL.path
        // Trusted macOS aliases only; arbitrary user-controlled symlinks remain rejected.
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || path.hasPrefix(alias + "/") { path = target + path.dropFirst(alias.count) }
        }
        let traversal: DeviceFilesystemTraversal
        do { traversal = try .plan(for: path) } catch { throw Failure.invalidPath }
        var current = URL(fileURLWithPath: traversal.rootPath, isDirectory: true)
        var root = stat()
        guard lstat(current.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidPath }
        for component in traversal.components {
            current.appendPathComponent(String(component), isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw Failure.symlink }
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Failure.invalidPath }
            } else if errno != ENOENT { throw Failure.invalidPath }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

public protocol DeviceLocalResetEvidence {
    var scopeDigest: String { get throws }
    func load() throws -> DeviceLocalResetRecord?
    func save(_ record: DeviceLocalResetRecord) throws
    func beginNewReset(_ record: DeviceLocalResetRecord) throws
}

/// No cleanup/deletion capability. Invalid configuration fails closed on every read.
public final class DeviceLocalResetEvidenceAdapter: DeviceLocalResetEvidence {
    private var scope: DeviceLocalResetScope?
    private let factoryBaseScope: DeviceLocalResetScope?
    private let store: DeviceLocalResetStore
    public init(scope: DeviceLocalResetScope, store: DeviceLocalResetStore) {
        self.scope = (try? scope.validateResetStoreDirectory(store.directory)) != nil ? scope : nil
        factoryBaseScope = self.scope
        self.store = store
    }
    private init(scope: DeviceLocalResetScope?, store: DeviceLocalResetStore) { self.scope = scope; factoryBaseScope = scope; self.store = store }
    init(owned scope: DeviceLocalResetScope, base: DeviceLocalResetScope, store: DeviceLocalResetStore) {
        self.scope = scope; factoryBaseScope = base; self.store = store
    }
    func factoryResetBase() throws -> DeviceLocalResetScope {
        guard let factoryBaseScope else { throw DeviceLocalResetScope.Failure.invalidPath }
        return factoryBaseScope
    }
    func adoptOwnedScope(_ value: DeviceLocalResetScope) throws {
        try value.validateResetStoreDirectory(store.directory)
        if let record = try store.load(), record.phase == .pending, record.scopeDigest != value.digest {
            throw DeviceLocalResetStoreError.transitionConflict
        }
        scope = value
    }
    var resetStore: DeviceLocalResetStore { store }

    public static func production() -> DeviceLocalResetEvidenceAdapter {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Exact current adapter item bindings; TLS and GoogleTV/ADB are excluded.
        let items = DeviceLocalResetScope.allowedCredentialItems
        let directory = DeviceLocalResetStore.defaultDirectory()
        let scope = try? DeviceLocalResetScope(deviceRoot: DeviceStateStore.defaultRoot(), preferencesRoot: support.appendingPathComponent("xyz.screenpunk.preferences"), managementDirectory: DeviceManagementTransitionStore.defaultDirectory(), resetDirectory: directory, credentialItems: items)
        return .init(scope: scope, store: .init(directory: directory))
    }
    public var scopeDigest: String { get throws { guard let scope else { throw DeviceLocalResetScope.Failure.invalidPath }; try scope.validateCurrentPaths(); try scope.validateResetStoreDirectory(store.directory); return scope.digest } }
    public func load() throws -> DeviceLocalResetRecord? { _ = try scopeDigest; return try store.load() }
    public func save(_ record: DeviceLocalResetRecord) throws { guard record.scopeDigest == (try scopeDigest) else { throw DeviceLocalResetStoreError.transitionConflict }; try store.save(record) }
    public func beginNewReset(_ record: DeviceLocalResetRecord) throws { guard record.scopeDigest == (try scopeDigest) else { throw DeviceLocalResetStoreError.transitionConflict }; try store.beginNewReset(record) }
}

/// Persisted outside erased roots. No secrets are contained in this manifest;
/// credential persistent references identify only already qualified exact items.
struct DeviceFactoryResetManifest: Codable {
    struct Root: Codable, Equatable {
        let rootID: UUID; let path: String; let device: UInt64; let inode: UInt64
    }
    struct Credential: Codable, Equatable {
        let service: String; let account: String; let persistentReference: Data; let byteCount: Int; let valueSHA256: String
    }
    let schemaVersion: Int
    let resetID: UUID
    let originalInstallationID: UUID
    let roots: [Root]
    let credentials: [Credential]
    let containers: [Root]
    let baseScopeDigest: String
    var canonicalBytes: Data { get throws { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) } }
    var digest: String { get throws { PeerPin.hex(PeerPin.sha256(try canonicalBytes)) } }
    init(evidence: DeviceOwnedInstallationResetResources, resetID: UUID, installationID: UUID,
        baseScopeDigest: String, additionalRoots: [Root], additionalCredentials: [Credential], containers: [Root]) throws {
        guard evidence.installationID == installationID else { throw DeviceLocalResetScope.Failure.invalidPath }
        schemaVersion = 4; self.resetID = resetID; originalInstallationID = installationID; self.baseScopeDigest = baseScopeDigest
        let allRoots = evidence.roots.map { Root(rootID: $0.rootID, path: $0.path, device: $0.device, inode: $0.inode) } + additionalRoots
        guard allRoots.count <= 1024, Set(allRoots.map(\.rootID)).count == allRoots.count,
            Set(allRoots.map(\.path)).count == allRoots.count else { throw DeviceLocalResetScope.Failure.overlap }
        roots = allRoots.sorted { $0.path < $1.path }
        self.containers = containers.sorted { $0.path.count > $1.path.count }
        var exact: [String: Credential] = [:]
        for item in evidence.credentials.map({ Credential(service: $0.service, account: $0.account,
            persistentReference: $0.persistentReference, byteCount: $0.byteCount, valueSHA256: $0.valueSHA256) }) + additionalCredentials {
            guard !item.service.isEmpty, !item.account.isEmpty, !item.service.contains("\0"), !item.account.contains("\0"),
                !item.persistentReference.isEmpty, item.persistentReference.count <= 4096, item.byteCount > 0, item.valueSHA256.count == 64, item.valueSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw DeviceLocalResetScope.Failure.invalidCredentialBinding
            }
            let key = item.service + "\0" + item.account
            if let previous = exact[key], previous != item { throw DeviceLocalResetScope.Failure.invalidCredentialBinding }
            exact[key] = item
        }
        guard exact.count <= 32768, baseScopeDigest.count == 64 else { throw DeviceLocalResetScope.Failure.invalidCredentialBinding }
        credentials = exact.values.sorted { ($0.service, $0.account) < ($1.service, $1.account) }
    }
    func validateStructure() throws {
        let allRoots = roots + containers
        guard schemaVersion == 4, roots.count <= 1024, containers.count <= 1024,
            Set(allRoots.map(\.rootID)).count == allRoots.count,
            Set(allRoots.map(\.path)).count == allRoots.count,
            baseScopeDigest.count == 64, baseScopeDigest.allSatisfy({ $0.isHexDigit }),
            credentials.count <= 32768 else { throw DeviceLocalResetScope.Failure.invalidPath }
        for root in allRoots {
            guard root.path.first == "/", !root.path.contains("\0"), root.path != "/",
                root.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                root.inode > 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
        }
        var identities = Set<String>(); var references = Set<Data>()
        for item in credentials {
            guard !item.service.isEmpty, !item.account.isEmpty, !item.service.contains("\0"), !item.account.contains("\0"),
                !item.persistentReference.isEmpty, item.persistentReference.count <= 4096, item.byteCount > 0, item.valueSHA256.count == 64, item.valueSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                identities.insert(item.service + "\0" + item.account).inserted,
                references.insert(item.persistentReference).inserted else { throw DeviceLocalResetScope.Failure.invalidCredentialBinding }
        }
    }
    static func cleanupMetadata(plan: DeviceLocalFilesystemCleanupPlan, containers: [DeviceLocalFilesystemCleanupPlan]) throws -> Data {
        struct Metadata: Encodable { let main: Data; let containers: [Data] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Metadata(main: plan.canonicalMetadata, containers: containers.map(\.canonicalMetadata)))
    }
    func validateContainerMembership() throws {
        for container in containers {
            let traversal = try DeviceFilesystemTraversal.plan(for: container.path)
            var fd = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
            var absent = false
            for component in traversal.components {
                let child = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 {
                    let missing = errno == ENOENT
                    close(fd)
                    if missing { absent = true; break }
                    throw DeviceLocalResetScope.Failure.invalidPath
                }
                close(fd); fd = child
            }
            if absent { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, UInt64(info.st_dev) == container.device, UInt64(info.st_ino) == container.inode else { throw DeviceLocalResetScope.Failure.invalidPath }
            let members = (roots + containers).filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == container.path }
            let allowed = Dictionary(uniqueKeysWithValues: members.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
            guard let listing = fdopendir(dup(fd)) else { throw DeviceLocalResetScope.Failure.invalidPath }
            defer { closedir(listing) }
            while let record = readdir(listing) {
                let name = withUnsafePointer(to: record.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                guard let original = allowed[name] else { throw DeviceLocalResetScope.Failure.overlap }
                var child = stat()
                guard fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) == 0, child.st_mode & S_IFMT == S_IFDIR,
                    UInt64(child.st_dev) == original.device, UInt64(child.st_ino) == original.inode else { throw DeviceLocalResetScope.Failure.invalidPath }
            }
        }
    }

}

/// Immutable, exact-name sidecar. Recovery chooses the UUID from the reset
/// journal; it never discovers a scope by enumerating directories or services.
struct DeviceFactoryResetManifestStore {
    let directory: URL
    private let maximumBytes = 8 * 1024 * 1024
    private func name(_ id: UUID) -> String { "owned-reset-" + id.uuidString.lowercased() + ".json" }
    private func withDirectory<T>(create: Bool, _ operation: (Int32) throws -> T) throws -> T {
        let canonical = try DeviceLocalResetScope.canonical(directory)
        let traversal = try DeviceFilesystemTraversal.plan(for: canonical.path)
        var descriptor = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
        defer { close(descriptor) }
        for (index, component) in traversal.components.enumerated() {
            let part = String(component)
            var child = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT, create, index == traversal.components.count - 1 {
                guard mkdirat(descriptor, part, 0o700) == 0 || errno == EEXIST else { throw DeviceLocalResetScope.Failure.invalidPath }
                child = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
            close(descriptor); descriptor = child
        }
        return try operation(descriptor)
    }
    func load(resetID: UUID) throws -> DeviceFactoryResetManifest? {
        try withDirectory(create: false) { directoryFD in
            let fd = openat(directoryFD, name(resetID), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT { return nil }
            guard fd >= 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                info.st_size > 0, info.st_size <= maximumBytes else { throw DeviceLocalResetScope.Failure.invalidPath }
            var bytes = Data(count: Int(info.st_size))
            let count = bytes.withUnsafeMutableBytes { buffer in read(fd, buffer.baseAddress, buffer.count) }
            guard count == bytes.count else { throw DeviceLocalResetScope.Failure.invalidPath }
            let manifest = try JSONDecoder().decode(DeviceFactoryResetManifest.self, from: bytes)
            try manifest.validateStructure()
            guard manifest.schemaVersion == 4, manifest.resetID == resetID,
                try manifest.canonicalBytes == bytes else { throw DeviceLocalResetScope.Failure.invalidPath }
            return manifest
        }
    }
    func save(_ manifest: DeviceFactoryResetManifest) throws {
        try manifest.validateStructure()
        let bytes = try manifest.canonicalBytes
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw DeviceLocalResetScope.Failure.invalidPath }
        try withDirectory(create: true) { directoryFD in
            let temporary = ".owned-reset-" + UUID().uuidString.lowercased()
            let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
            defer { close(fd); _ = unlinkat(directoryFD, temporary, 0) }
            let count = bytes.withUnsafeBytes { buffer in write(fd, buffer.baseAddress, buffer.count) }
            guard count == bytes.count, fsync(fd) == 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
            if renameatx_np(directoryFD, temporary, directoryFD, name(manifest.resetID), UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST, let original = try load(resetID: manifest.resetID),
                    try original.canonicalBytes == bytes else { throw DeviceLocalResetScope.Failure.invalidPath }
            }
            guard fsync(directoryFD) == 0 else { throw DeviceLocalResetScope.Failure.invalidPath }
        }
    }
}
