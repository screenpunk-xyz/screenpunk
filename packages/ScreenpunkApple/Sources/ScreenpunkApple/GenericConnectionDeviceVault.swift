import Foundation
import ScreenpunkCore

/// One atomic Keychain record per device; permissions and credentials share an owner/dashboard/revision scope.
public final class GenericConnectionDeviceVault: @unchecked Sendable {
    public struct Scope: Equatable, Sendable {
        public var owner: String
        public var dashboardId: String
        public var revision: String
        public init(owner: String, dashboardId: String, revision: String) {
            self.owner = owner; self.dashboardId = dashboardId; self.revision = revision
        }
    }
    private struct Record: Codable, Equatable {
        var owner: String
        var configuration: ConnectionProvisioning
        var generation: UUID
    }
    private let lock = NSLock()
    private let store: any CredentialStore
    private let account = "approved-grants-v1"
    public init(store: any CredentialStore = KeychainCredentialStore(service: "xyz.screenpunk.device.connections")) {
        self.store = store
    }
    public func provision(_ configuration: ConnectionProvisioning, owner: String) throws {
        try configuration.validate()
        guard !owner.isEmpty else { throw ConnectionFailure.permissionRequired }
        lock.lock(); defer { lock.unlock() }
        var records = try load()
        if let existing = records.first(where: { $0.configuration.provisioningId == configuration.provisioningId }) {
            guard existing.owner == owner, existing.configuration == configuration else { throw ConnectionFailure.validationFailed }
            return
        }
        // A new owner may not inherit permissions. One approved revision per dashboard bounds retained secrets.
        records.removeAll { $0.owner != owner || $0.configuration.dashboardId == configuration.dashboardId }
        guard records.count < 32 else { throw ConnectionFailure.sizeLimit }
        records.append(.init(owner: owner, configuration: configuration, generation: UUID()))
        try store.put(JSONEncoder().encode(records), for: account)
    }
    func inventory(owner: String, screen: LANScreenSetEntry) throws -> [DeviceConnectionEntry] {
        lock.lock(); defer { lock.unlock() }
        return try load().filter { $0.owner == owner && $0.configuration.dashboardId == screen.dashboardId && $0.configuration.revision == screen.revision }.flatMap { record in
            record.configuration.entries.map { entry in
                DeviceConnectionEntry(id: entry.grant.id.uuidString, screen: screen, name: entry.grant.alias,
                    kind: "Custom connection", origin: entry.grant.origin, authentication: entry.binding.placement.rawValue,
                    operations: entry.grant.operations.map { .init(name: $0.name, method: $0.method.rawValue, path: $0.path, write: $0.write) })
            }
        }
    }
    public func revoke() throws {
        lock.lock(); defer { lock.unlock() }
        try store.delete(account)
    }
    private func load() throws -> [Record] {
        guard let data = try store.secret(for: account) else { return [] }
        return try JSONDecoder().decode([Record].self, from: data)
    }
    private func record(_ scope: Scope) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        guard let record = try load().first(where: { $0.owner == scope.owner && $0.configuration.dashboardId == scope.dashboardId && $0.configuration.revision == scope.revision }) else {
            throw ConnectionFailure.permissionRequired
        }
        try record.configuration.validate()
        return record
    }
    /// Recreated on package/approval change. Old actors fail closed even across in-flight I/O.
    public func makeRuntime(scope: Scope, currentScope: @escaping @Sendable () -> Scope?,
                            http: any HTTPTransport = URLSessionHTTPTransport(),
                            webSocket: any WebSocketTransport = URLSessionWebSocketTransport(),
                            resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver()) async throws -> ConnectionRuntime {
        let approved = try record(scope)
        let credentials = MemoryCredentialStore()
        for entry in approved.configuration.entries {
            if let secret = entry.secret { try credentials.put(secret, for: entry.grant.authRef) }
        }
        let runtime = ConnectionRuntime(dashboardId: scope.dashboardId, store: credentials, http: http, webSocket: webSocket, resolver: resolver,
            authorizeScope: { [weak self] in
                guard let self, currentScope() == scope,
                      try self.record(scope).generation == approved.generation else { throw ConnectionFailure.permissionRequired }
            })
        for entry in approved.configuration.entries { try await runtime.install(grant: entry.grant, binding: entry.binding) }
        return runtime
    }
}
