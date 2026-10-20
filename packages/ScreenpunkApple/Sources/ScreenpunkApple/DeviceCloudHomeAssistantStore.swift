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
    public struct SavedConnection: Codable, Sendable, Equatable {
        public var origin: String
        public var token: String
        public var allowInsecureHTTP: Bool
    }
    private struct State: Codable {
        var records: [Record] = []
        var connections: [String: SavedConnection] = [:]
    }
    private func state() throws -> State {
        guard let data = try store.secret(for: Self.storageKey) else { return State() }
        guard data.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        let decoder = JSONDecoder()
        let value: State
        if let legacy = try? decoder.decode([Record].self, from: data) { value = State(records: legacy) }
        else { value = try decoder.decode(State.self, from: data) }
        guard value.records.count <= 64, value.connections.count <= 64 else { throw ConnectionFailure.sizeLimit }
        return value
    }
    private func persist(_ value: State) throws {
        if value.records.isEmpty && value.connections.isEmpty { try store.delete(Self.storageKey); return }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
        try store.put(data, for: Self.storageKey)
    }
    private func records() throws -> [Record] { try state().records }
    public func savedConnection(installationID: UUID) throws -> SavedConnection? {
        lock.lock(); defer { lock.unlock() }
        let value = try state()
        if let connection = value.connections[installationID.uuidString] { return connection }
        guard let legacy = value.records.last(where: { $0.installationID == installationID })?.configuration else { return nil }
        return SavedConnection(origin: legacy.origin, token: legacy.token, allowInsecureHTTP: legacy.allowInsecureHTTP)
    }
    /// Saving device credentials does not approve any new screen or screen version.
    public func saveConnection(installationID: UUID, origin: String, token: String, allowInsecureHTTP: Bool) throws {
        let candidate = HomeAssistantProvisioning(dashboardId: "connection", connectionId: "connection", provisioningId: "connection", revision: "connection", origin: origin, allowInsecureHTTP: allowInsecureHTTP, token: token)
        try candidate.validate()
        guard allowInsecureHTTP || URL(string: origin)?.scheme?.lowercased() == "https" else { throw ConnectionFailure.permissionRequired }
        lock.lock(); defer { lock.unlock() }
        var value = try state()
        guard value.connections[installationID.uuidString] != nil || value.connections.count < 64 else { throw ConnectionFailure.sizeLimit }
        value.connections[installationID.uuidString] = SavedConnection(origin: origin, token: token, allowInsecureHTTP: allowInsecureHTTP)
        value.records = value.records.map { record in
            guard record.installationID == installationID else { return record }
            var configuration = record.configuration
            configuration.origin = origin; configuration.token = token; configuration.allowInsecureHTTP = allowInsecureHTTP
            configuration.connectionId = UUID().uuidString; configuration.provisioningId = UUID().uuidString
            return Record(installationID: record.installationID, manifestDigest: record.manifestDigest, configuration: configuration)
        }
        try persist(value)
    }
    public func configuration(installationID: UUID, manifest: DashboardManifest) throws -> HomeAssistantProvisioning? {
        lock.lock(); defer { lock.unlock() }
        guard let digest = manifest.digest else { return nil }
        let matching = try records().filter { $0.installationID == installationID && $0.manifestDigest == digest &&
            $0.configuration.dashboardId == manifest.dashboardId && $0.configuration.revision == manifest.revision }
        guard matching.count <= 1 else { throw ConnectionFailure.validationFailed }
        return matching.first?.configuration
    }
    public func hasSavedConnection(installationID: UUID) throws -> Bool { try savedConnection(installationID: installationID) != nil }
    public func approveSaved(installationID: UUID, manifest: DashboardManifest) throws {
        guard let saved = try savedConnection(installationID: installationID) else { throw ConnectionFailure.permissionRequired }
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
        var value = try state()
        var saved = value.records.filter { !($0.installationID == installationID && $0.configuration.dashboardId == manifest.dashboardId) }
        guard saved.count < 64 else { throw ConnectionFailure.sizeLimit }
        saved.append(.init(installationID: installationID, manifestDigest: digest, configuration: configuration))
        value.records = saved
        try persist(value)
    }
    public func revoke(installationID: UUID, dashboardID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var value = try state()
        if dashboardID != nil, value.connections[installationID.uuidString] == nil,
           let legacy = value.records.last(where: { $0.installationID == installationID })?.configuration {
            guard value.connections.count < 64 else { throw ConnectionFailure.sizeLimit }
            value.connections[installationID.uuidString] = SavedConnection(origin: legacy.origin, token: legacy.token, allowInsecureHTTP: legacy.allowInsecureHTTP)
        }
        value.records.removeAll { $0.installationID == installationID && (dashboardID == nil || $0.configuration.dashboardId == dashboardID) }
        if dashboardID == nil { value.connections.removeValue(forKey: installationID.uuidString) }
        try persist(value)
    }
}
