import Foundation
import Darwin
@_spi(NativeFilesystem) import ScreenpunkCore

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
    private let scope: DeviceLocalResetScope?
    private let store: DeviceLocalResetStore
    public init(scope: DeviceLocalResetScope, store: DeviceLocalResetStore) {
        self.scope = (try? scope.validateResetStoreDirectory(store.directory)) != nil ? scope : nil
        self.store = store
    }
    private init(scope: DeviceLocalResetScope?, store: DeviceLocalResetStore) { self.scope = scope; self.store = store }
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
