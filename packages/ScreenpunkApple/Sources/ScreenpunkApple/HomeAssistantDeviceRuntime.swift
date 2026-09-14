import Foundation
import ScreenpunkCore

/// One atomic Keychain record binds permissions and credentials to their paired owner.
public final class HomeAssistantDeviceVault: @unchecked Sendable {
    private let lock = NSLock()
    private let store: any CredentialStore
    private let account = "provisioning-v1"
    public init(store: any CredentialStore = KeychainCredentialStore(service: "xyz.screenpunk.device.home-assistant")) {
        self.store = store
    }
    struct Record: Codable, Equatable {
        var owner: String
        var configuration: HomeAssistantProvisioning
        var generation: UUID
    }
    public func provision(_ configuration: HomeAssistantProvisioning, owner: String) throws {
        try configuration.validate()
        lock.lock(); defer { lock.unlock() }
        if let data = try store.secret(for: account), let existing = try? JSONDecoder().decode(Record.self, from: data),
           existing.owner == owner, existing.configuration.provisioningId == configuration.provisioningId {
            guard existing.configuration == configuration else { throw ConnectionFailure.validationFailed }
            return
        }
        let record = Record(owner: owner, configuration: configuration, generation: UUID())
        try store.put(JSONEncoder().encode(record), for: account)
    }
    public func revoke() throws {
        lock.lock(); defer { lock.unlock() }
        try store.delete(account)
    }
    func record(owner: String, revision: String) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        guard let data = try store.secret(for: account) else { throw ConnectionFailure.permissionRequired }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.owner == owner, record.configuration.revision == revision else { throw ConnectionFailure.permissionRequired }
        try record.configuration.validate()
        return record
    }
}

/// HTTP polling is the initial live-state transport. No commands are retried or queued.
public actor HomeAssistantDeviceRuntime {
    public struct Scope: Sendable, Equatable {
        public var owner: String
        public var revision: String
        public var dashboardId: String
        public init(owner: String, revision: String, dashboardId: String) { self.owner = owner; self.revision = revision; self.dashboardId = dashboardId }
    }
    private let vault: HomeAssistantDeviceVault
    private let scope: @Sendable () -> Scope?
    private let transport: any HTTPTransport
    private let resolver: any DestinationResolver
    private var cached: (generation: UUID, result: ConnectionHTTPResult)?
    private var inFlight = false
    private var pending: Task<HTTPTransportResponse, Error>?

    public func cancelPending() { pending?.cancel(); cached = nil }

    public init(vault: HomeAssistantDeviceVault, scope: @escaping @Sendable () -> Scope?,
                transport: any HTTPTransport = HomeAssistantHTTPTransport(),
                resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver()) {
        self.vault = vault; self.scope = scope; self.transport = transport; self.resolver = resolver
    }

    public func request(revision: String, alias: String, operation: String, parameters: [String: String]) async throws -> ConnectionHTTPResult {
        guard alias == "home", let current = scope(), current.revision == revision else { throw ConnectionFailure.permissionRequired }
        let record = try vault.record(owner: current.owner, revision: revision)
        let config = record.configuration
        guard config.dashboardId == current.dashboardId else { throw ConnectionFailure.permissionRequired }
        let authorized = try config.authorize(operation: operation, parameters: parameters)
        guard !inFlight else { throw ConnectionFailure.sizeLimit }
        inFlight = true
        defer { inFlight = false }
        let write = authorized.body != nil
        let grant = config.connectionGrant(path: authorized.path, write: write)
        let destination = try ConnectionPolicy.authorize(grant: grant, operationName: "request", parameters: [:],
            resolvedAddresses: resolver.addresses(for: ConnectionPolicy.originHost(config.origin)),
            binding: .init(authRef: "home-device", placement: .bearer))
        if write {
            guard let cached, cached.generation == record.generation, !cached.result.stale,
                  Date().timeIntervalSince(cached.result.fetchedAt) <= 45 else { throw ConnectionFailure.deviceOffline }
        }
        do {
            let transport = self.transport
            let requestTask = Task {
                try await transport.send(.init(url: destination.url, method: write ? "POST" : "GET",
                    headers: ["Authorization": "Bearer " + config.token], body: authorized.body, timeout: 10, maxBytes: 1024 * 1024))
            }
            pending = requestTask
            defer { pending = nil }
            let response = try await withTaskCancellationHandler(operation: { try await requestTask.value },
                                                                 onCancel: { requestTask.cancel() })
            try requireCurrent(record, current)
            if response.status == 401 || response.status == 403 {
                cached = nil
                throw ConnectionFailure.permissionRequired
            }
            guard (200...299).contains(response.status) else { throw ConnectionFailure.deviceOffline }
            guard response.body.count <= 1024 * 1024 else { throw ConnectionFailure.sizeLimit }
            // Service responses can include unrelated changed entities; never return them to the page.
            let body = write ? Data("null".utf8) : try config.filterStates(response.body)
            let result = ConnectionHTTPResult(statusCode: response.status, body: body, stale: false, fetchedAt: Date(), diagnostic: "")
            if !write { cached = (record.generation, result) }
            return result
        } catch {
            try requireCurrent(record, current)
            if !write, let previous = cached, previous.generation == record.generation,
               (error as? ConnectionFailure) != .permissionRequired {
                var result = previous.result
                result.stale = true
                cached = (record.generation, result)
                return result
            }
            if write, let previous = cached {
                var result = previous.result; result.stale = true
                cached = (previous.generation, result)
            }
            throw (error as? ConnectionFailure) ?? ConnectionFailure.deviceOffline
        }
    }

    private func requireCurrent(_ record: HomeAssistantDeviceVault.Record, _ expected: Scope) throws {
        guard scope() == expected, try vault.record(owner: expected.owner, revision: expected.revision).generation == record.generation else {
            cached = nil
            throw ConnectionFailure.permissionRequired
        }
    }
}

/// Bound response size while receiving, with normal TLS validation and no redirects.
public final class HomeAssistantHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: RedirectDenyingDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        var native = URLRequest(url: request.url, timeoutInterval: request.timeout)
        native.httpMethod = request.method; native.httpBody = request.body
        native.setValue("application/json", forHTTPHeaderField: "Content-Type")
        native.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in request.headers { native.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.bytes(for: native)
        guard let response = response as? HTTPURLResponse else { throw ConnectionFailure.deviceOffline }
        guard !(300...399).contains(response.statusCode) else { throw ConnectionFailure.deniedEgress }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < request.maxBytes else { throw ConnectionFailure.sizeLimit }
            data.append(byte)
        }
        return HTTPTransportResponse(status: response.statusCode, body: data)
    }
}
