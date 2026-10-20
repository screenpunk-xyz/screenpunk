import Foundation
import ScreenpunkCore

/// Credentials are native-only; each approval binds a complete immutable manifest.
public final class DeviceCustomHTTPStore: @unchecked Sendable {
    public static let shared = DeviceCustomHTTPStore()
    static let storageService = "xyz.screenpunk.device.custom-http"
    static let storageKey = "connections-v1"
    private let store: any CredentialStore
    private let lock = NSLock()
    private struct Record: Codable {
        var installationID: UUID
        var dashboardID: String
        var digest: String
        var alias: String
        var declaration: CustomHTTPDeclaration
        var configuration: CustomHTTPConfiguration
    }
    public init(store: (any CredentialStore)? = nil) { self.store = store ?? KeychainCredentialStore(service: Self.storageService) }
    private func records() throws -> [Record] {
        guard let bytes = try store.secret(for: Self.storageKey) else { return [] }
        guard bytes.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        let result = try JSONDecoder().decode([Record].self, from: bytes)
        guard result.count <= 64 else { throw ConnectionFailure.sizeLimit }; return result
    }
    public func configuration(installationID: UUID, manifest: DashboardManifest, alias: String) throws -> CustomHTTPConfiguration? {
        lock.lock(); defer { lock.unlock() }
        return try records().first { $0.installationID == installationID && $0.dashboardID == manifest.dashboardId && $0.digest == manifest.digest && $0.alias == alias && $0.declaration == manifest.connections.first(where: { $0.alias == alias })?.customHTTP }?.configuration
    }
    public func hasSavedConnection(installationID: UUID, alias: String, declaration: CustomHTTPDeclaration) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try records().contains { $0.installationID == installationID && $0.alias == alias && $0.declaration.authentication == declaration.authentication && $0.declaration.headerName == declaration.headerName }
    }
    public func approveSaved(installationID: UUID, manifest: DashboardManifest, alias: String) throws {
        guard let d = manifest.connections.first(where: { $0.alias == alias })?.customHTTP else { throw ConnectionFailure.validationFailed }
        lock.lock()
        let config: CustomHTTPConfiguration?
        do { config = try records().last { $0.installationID == installationID && $0.alias == alias && $0.declaration.authentication == d.authentication && $0.declaration.headerName == d.headerName }?.configuration; lock.unlock() }
        catch { lock.unlock(); throw error }
        guard let config else { throw ConnectionFailure.permissionRequired }
        try approve(installationID: installationID, manifest: manifest, alias: alias, configuration: config)
    }
    public func approve(installationID: UUID, manifest: DashboardManifest, alias: String, configuration: CustomHTTPConfiguration) throws {
        try PackageValidator.validate(manifest)
        guard let digest = manifest.digest, digest.count == 64, let declaration = manifest.connections.first(where: { $0.alias == alias })?.customHTTP else { throw ConnectionFailure.validationFailed }
        _ = try configuration.grant(alias: alias, declaration: declaration)
        lock.lock(); defer { lock.unlock() }
        var saved = try records().filter { !($0.installationID == installationID && $0.dashboardID == manifest.dashboardId && $0.alias == alias) }
        guard saved.count < 64 else { throw ConnectionFailure.sizeLimit }
        saved.append(.init(installationID: installationID, dashboardID: manifest.dashboardId, digest: digest, alias: alias, declaration: declaration, configuration: configuration))
        let bytes = try JSONEncoder().encode(saved); guard bytes.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        try store.put(bytes, for: Self.storageKey)
    }
    public func revoke(installationID: UUID, dashboardID: String? = nil, alias: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let saved = try records().filter { !($0.installationID == installationID && (dashboardID == nil || $0.dashboardID == dashboardID) && (alias == nil || $0.alias == alias)) }
        if saved.isEmpty { try store.delete(Self.storageKey) }
        else { try store.put(JSONEncoder().encode(saved), for: Self.storageKey) }
    }
}
