import Foundation
import ScreenpunkCore

/// Device-entered approval for one installation and immutable screen package.
/// Cloud packages carry declarations only. They never supply this record or token.
public final class DeviceCloudHomeAssistantStore: @unchecked Sendable {
    public static let shared = DeviceCloudHomeAssistantStore()
    static let storageService = "xyz.screenpunk.device.cloud-home-assistant"
    static let storageKey = "approved-packages-v1"
    private let store: any CredentialStore
    private let lock = NSLock()
    private struct Record: Codable {
        let installationID: UUID
        let manifestDigest: String
        let configuration: HomeAssistantProvisioning
    }
    public init(store: (any CredentialStore)? = nil) { self.store = store ?? KeychainCredentialStore(service: Self.storageService) }
    private func records() throws -> [Record] {
        guard let data = try store.secret(for: Self.storageKey) else { return [] }
        guard data.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        let records = try JSONDecoder().decode([Record].self, from: data)
        guard records.count <= 64 else { throw ConnectionFailure.sizeLimit }
        return records
    }
    public func configuration(installationID: UUID, manifest: DashboardManifest) throws -> HomeAssistantProvisioning? {
        lock.lock(); defer { lock.unlock() }
        guard let digest = manifest.digest else { return nil }
        let matching = try records().filter { $0.installationID == installationID && $0.manifestDigest == digest &&
            $0.configuration.dashboardId == manifest.dashboardId && $0.configuration.revision == manifest.revision }
        guard matching.count <= 1 else { throw ConnectionFailure.validationFailed }
        return matching.first?.configuration
    }
    public func hasSavedConnection(installationID: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try records().contains { $0.installationID == installationID }
    }
    public func approveSaved(installationID: UUID, manifest: DashboardManifest) throws {
        lock.lock()
        let saved: HomeAssistantProvisioning?
        do { saved = try records().last(where: { $0.installationID == installationID })?.configuration; lock.unlock() }
        catch { lock.unlock(); throw error }
        guard let saved else { throw ConnectionFailure.permissionRequired }
        try approve(installationID: installationID, manifest: manifest, origin: saved.origin, token: saved.token, allowInsecureHTTP: saved.allowInsecureHTTP)
    }
    /// Called by native Settings after the person reviews the exact declared permissions.
    public func approve(installationID: UUID, manifest: DashboardManifest, origin: String, token: String, allowInsecureHTTP: Bool) throws {
        try PackageValidator.validate(manifest)
        guard let digest = manifest.digest, digest.count == 64,
            let declaration = manifest.connections.first(where: { $0.alias == "home" && $0.publicHTTP == nil }) else { throw ConnectionFailure.validationFailed }
        var configuration = HomeAssistantProvisioning(schemaVersion: 3, dashboardId: manifest.dashboardId,
            connectionId: UUID().uuidString, provisioningId: UUID().uuidString, revision: manifest.revision,
            origin: origin, allowInsecureHTTP: allowInsecureHTTP, token: token)
        configuration.serviceCalls = declaration.serviceCalls ?? []
        configuration.cameraEntities = declaration.cameraEntities ?? []
        try configuration.validate()
        guard allowInsecureHTTP || URL(string: origin)?.scheme?.lowercased() == "https" else {
            throw ConnectionFailure.permissionRequired
        }
        lock.lock(); defer { lock.unlock() }
        var saved = try records().filter { !($0.installationID == installationID && $0.configuration.dashboardId == manifest.dashboardId) }
        guard saved.count < 64 else { throw ConnectionFailure.sizeLimit }
        saved.append(.init(installationID: installationID, manifestDigest: digest, configuration: configuration))
        let bytes = try JSONEncoder().encode(saved)
        guard bytes.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        try store.put(bytes, for: Self.storageKey)
    }
    public func revoke(installationID: UUID, dashboardID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let saved = try records().filter { !($0.installationID == installationID && (dashboardID == nil || $0.configuration.dashboardId == dashboardID)) }
        if saved.isEmpty { try store.delete(Self.storageKey) }
        else { try store.put(JSONEncoder().encode(saved), for: Self.storageKey) }
    }
}
