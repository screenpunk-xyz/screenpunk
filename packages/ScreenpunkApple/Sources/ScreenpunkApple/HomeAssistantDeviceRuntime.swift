import Foundation
import ScreenpunkCore

/// One atomic Keychain record binds permissions and credentials to their paired owner.
public final class HomeAssistantDeviceVault: @unchecked Sendable {
    private let lock = NSLock()
    private let store: any CredentialStore
    private let account = "provisioning-v1"
    private let setsAccount = "screen-set-grants-v1"
    private let publicAccount = "public-read-grants-v1"
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
        try store.delete(setsAccount)
    }
    /// Staging adds a new generation without replacing grants referenced by committed device state.
    func stage(_ configurations: [HomeAssistantProvisioning], owner: String, generation: String) throws {
        for config in configurations { try config.validate() }
        lock.lock(); defer { lock.unlock() }
        var sets = try grantSets()
        sets[generation] = configurations.map { Record(owner: owner, configuration: $0, generation: UUID()) }
        try store.put(JSONEncoder().encode(sets), for: setsAccount)
    }
    func provisionInGeneration(_ configuration: HomeAssistantProvisioning, owner: String, generation: String) throws {
        try configuration.validate()
        lock.lock(); defer { lock.unlock() }
        var sets = try grantSets()
        var records = sets[generation] ?? []
        if let previous = records.first(where: { $0.configuration.provisioningId == configuration.provisioningId }) {
            guard previous.owner == owner, previous.configuration == configuration else { throw ConnectionFailure.validationFailed }
            return
        }
        records.removeAll { $0.configuration.dashboardId == configuration.dashboardId }
        records.append(Record(owner: owner, configuration: configuration, generation: UUID()))
        sets[generation] = records
        try store.put(JSONEncoder().encode(sets), for: setsAccount)
    }
    func removeGeneration(_ generation: String) throws {
        lock.lock(); defer { lock.unlock() }
        var sets = try grantSets(); sets.removeValue(forKey: generation)
        try store.put(JSONEncoder().encode(sets), for: setsAccount)
    }
    func retainGeneration(_ generation: String) throws {
        lock.lock(); defer { lock.unlock() }
        let sets = try grantSets()
        try store.put(JSONEncoder().encode(sets.filter { $0.key == generation }), for: setsAccount)
        try store.delete(account)
    }
    private struct PublicRecord: Codable { var owner: String; var configuration: PublicReadProvisioning }
    private func publicSets() throws -> [String: [PublicRecord]] {
        guard let data = try store.secret(for: publicAccount) else { return [:] }
        return try JSONDecoder().decode([String: [PublicRecord]].self, from: data)
    }
    func revokePublic() throws {
        lock.lock(); defer { lock.unlock() }
        try store.delete(publicAccount)
    }
    func stagePublic(_ configs: [PublicReadProvisioning], owner: String, generation: String) throws {
        for config in configs { try config.validate() }
        lock.lock(); defer { lock.unlock() }
        var sets = try publicSets(); sets[generation] = configs.map { PublicRecord(owner: owner, configuration: $0) }
        try store.put(JSONEncoder().encode(sets), for: publicAccount)
    }
    func publicConfiguration(owner: String, dashboardId: String, revision: String, generation: String) throws -> PublicReadProvisioning {
        lock.lock(); defer { lock.unlock() }
        guard let config = try publicSets()[generation]?.first(where: { $0.owner == owner && $0.configuration.dashboardId == dashboardId && $0.configuration.revision == revision })?.configuration else { throw ConnectionFailure.permissionRequired }
        try config.validate(); return config
    }
    func prunePublic(keeping generation: String? = nil, removing: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let sets = try publicSets().filter { (generation == nil || $0.key == generation) && $0.key != removing }
        try store.put(JSONEncoder().encode(sets), for: publicAccount)
    }
    func inventory(owner: String, screen: LANScreenSetEntry, grantSet: String?) throws -> [DeviceConnectionEntry] {
        var entries: [DeviceConnectionEntry] = []
        if let grantSet, let config = try? publicConfiguration(owner: owner, dashboardId: screen.dashboardId, revision: screen.revision, generation: grantSet) {
            entries += config.connections.compactMap { connection in
                guard let source = connection.publicHTTP else { return nil }
                return .init(id: connection.alias, screen: screen, name: connection.alias, kind: "Public data source",
                    origin: source.origin, authentication: "None", operations: source.operations.map { .init(name: $0.name, method: "GET", path: $0.path) }, publicConnection: connection)
            }
        }
        if let record = try? record(owner: owner, revision: screen.revision, grantSet: grantSet), record.configuration.dashboardId == screen.dashboardId {
            let config = record.configuration
            var operations = [DeviceConnectionOperation(name: "Fetch entity states", method: "GET", path: "/api/states")]
            if config.schemaVersion == 1 {
                operations += HomeAssistantProvisioning.services.sorted { $0.key < $1.key }.map { .init(name: $0.key, method: "POST", path: "/api/services/\($0.value.domain)/\($0.value.service)", write: true) }
            } else {
                operations += (config.serviceCalls ?? []).map { .init(name: "\($0.domain).\($0.service)", method: "POST", path: $0.entityIds.joined(separator: ", "), write: true) }
            }
            operations += (config.cameraEntities ?? []).map { .init(name: "View camera", method: "GET", path: $0) }
            entries.append(.init(id: config.connectionId, screen: screen, name: "Home Assistant", kind: "Service integration", origin: config.origin,
                authentication: "Access token", operations: operations, configurationVersion: record.generation.uuidString))
        }
        return entries
    }

    func update(_ update: DeviceHomeAssistantUpdate, owner: String, grantSet: String?) throws {
        guard !update.entries.isEmpty, update.entries.count <= 32 else { throw ConnectionFailure.validationFailed }
        lock.lock(); defer { lock.unlock() }
        var sets = try grantSets()
        var records: [Record]
        if let grantSet { records = sets[grantSet] ?? [] }
        else if let data = try store.secret(for: account) { records = [try JSONDecoder().decode(Record.self, from: data)] }
        else { throw ConnectionFailure.permissionRequired }
        var indices = Set<Int>()
        for entry in update.entries {
            guard let index = records.firstIndex(where: { $0.owner == owner && $0.configuration.dashboardId == entry.screen.dashboardId && $0.configuration.revision == entry.screen.revision && $0.configuration.connectionId == entry.id && $0.generation.uuidString == entry.configurationVersion }), indices.insert(index).inserted else { throw ConnectionFailure.permissionRequired }
            var config = records[index].configuration
            // Never forward an existing token to a different server without a new explicit token.
            if config.origin != update.origin && update.token == nil { throw ConnectionFailure.permissionRequired }
            config.origin = update.origin; config.allowInsecureHTTP = update.origin.hasPrefix("http://")
            if let token = update.token { config.token = token }
            config.provisioningId = UUID().uuidString
            try config.validate()
            records[index] = Record(owner: owner, configuration: config, generation: UUID())
        }
        if let grantSet { sets[grantSet] = records; try store.put(JSONEncoder().encode(sets), for: setsAccount) }
        else { try store.put(JSONEncoder().encode(records[0]), for: account) }
    }
    private func grantSets() throws -> [String: [Record]] {
        guard let data = try store.secret(for: setsAccount) else { return [:] }
        return try JSONDecoder().decode([String: [Record]].self, from: data)
    }
    func record(owner: String, revision: String, grantSet: String? = nil) throws -> Record {
        lock.lock(); defer { lock.unlock() }
        let record: Record
        if let grantSet {
            guard let found = try grantSets()[grantSet]?.first(where: { $0.owner == owner && $0.configuration.revision == revision }) else {
                throw ConnectionFailure.permissionRequired
            }
            record = found
        } else {
            guard let data = try store.secret(for: account) else { throw ConnectionFailure.permissionRequired }
            record = try JSONDecoder().decode(Record.self, from: data)
        }
        guard record.owner == owner, record.configuration.revision == revision else { throw ConnectionFailure.permissionRequired }
        try record.configuration.validate()
        return record
    }
}

/// Device-owned HTTP and authenticated WebSocket transport. Credentials never reach dashboard JavaScript.
public actor HomeAssistantDeviceRuntime: CameraStreamResolver {
    public struct Scope: Sendable, Equatable {
        public var owner: String
        public var revision: String
        public var dashboardId: String
        public var grantSet: String?
        public init(owner: String, revision: String, dashboardId: String, grantSet: String? = nil) {
            self.owner = owner; self.revision = revision; self.dashboardId = dashboardId; self.grantSet = grantSet
        }
    }
    private let vault: HomeAssistantDeviceVault
    private let scope: @Sendable () -> Scope?
    private let transport: any HTTPTransport
    private let resolver: any DestinationResolver
    private let webSocket: any WebSocketTransport
    private var liveSessions: [UUID: any WebSocketSession] = [:]
    private var cached: (generation: UUID, result: ConnectionHTTPResult)?
    private var inFlight = false
    private var pending: Task<HTTPTransportResponse, Error>?

    public func cancelPending() async {
        pending?.cancel(); cached = nil
        let sessions = Array(liveSessions.values); liveSessions.removeAll()
        for session in sessions { await session.close() }
    }

    public init(vault: HomeAssistantDeviceVault, scope: @escaping @Sendable () -> Scope?,
                transport: any HTTPTransport = HomeAssistantHTTPTransport(),
                resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(),
                webSocket: any WebSocketTransport = URLSessionWebSocketTransport()) {
        self.vault = vault; self.scope = scope; self.transport = transport; self.resolver = resolver; self.webSocket = webSocket
    }

    public func request(revision: String, alias: String, operation: String, parameters: [String: String]) async throws -> ConnectionHTTPResult {
        guard alias == "home", let current = scope(), current.revision == revision else { throw ConnectionFailure.permissionRequired }
        let record = try vault.record(owner: current.owner, revision: revision, grantSet: current.grantSet)
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
            if write && [400, 404, 422].contains(response.status) { throw ConnectionFailure.validationFailed }
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

    /// A snapshot always precedes live state changes, including after reconnect. The
    /// caller must use snapshots to refresh conditions without replaying navigation.
    public struct StateUpdate: Sendable {
        public var data: Data
        public var isSnapshot: Bool
    }

    public func subscribeStates(revision: String, alias: String = "home", operation: String = "stateChanged",
                                parameters: [String: String] = [:]) throws -> AsyncThrowingStream<StateUpdate, Error> {
        guard alias == "home", operation == "stateChanged", parameters.isEmpty,
              let current = scope(), current.revision == revision else { throw ConnectionFailure.permissionRequired }
        let record = try vault.record(owner: current.owner, revision: revision, grantSet: current.grantSet)
        guard record.configuration.dashboardId == current.dashboardId else { throw ConnectionFailure.permissionRequired }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do { try await self.streamStates(record: record, scope: current, continuation: continuation) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamStates(record: HomeAssistantDeviceVault.Record, scope current: Scope,
                              continuation: AsyncThrowingStream<StateUpdate, Error>.Continuation) async throws {
        let config = record.configuration
        // Reuse the provisioned origin, LAN consent, resolver and fixed-route policy.
        let grant = config.connectionGrant(path: "/api/websocket", write: false)
        let destination = try ConnectionPolicy.authorize(grant: grant, operationName: "request", parameters: [:],
            resolvedAddresses: resolver.addresses(for: ConnectionPolicy.originHost(config.origin)),
            binding: .init(authRef: "home-device", placement: .bearer))
        guard var url = URLComponents(url: destination.url, resolvingAgainstBaseURL: false) else { throw ConnectionFailure.validationFailed }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        guard let socketURL = url.url else { throw ConnectionFailure.validationFailed }
        let session = try await webSocket.connect(.init(url: socketURL, headers: [:], timeout: 10,
                                                        maxMessageBytes: ConnectionBounds.websocketMessageBytes))
        let id = UUID(); liveSessions[id] = session
        defer { liveSessions.removeValue(forKey: id); Task { await session.close() } }
        try await withTaskCancellationHandler(operation: {
            let greeting = try await receiveObject(session, record: record, scope: current)
            guard greeting["type"] as? String == "auth_required" else { throw ConnectionFailure.permissionRequired }
            try await sendObject(["type": "auth", "access_token": config.token], session: session)
            let authenticated = try await receiveObject(session, record: record, scope: current)
            guard authenticated["type"] as? String == "auth_ok" else { throw ConnectionFailure.permissionRequired }
            // Subscribe before snapshot; drop events until the snapshot result so an
            // old doorbell event cannot be replayed after a network interruption.
            try await sendObject(["id": 1, "type": "subscribe_events", "event_type": "state_changed"], session: session)
            try await sendObject(["id": 2, "type": "get_states"], session: session)
            var initialized = false
            while !Task.isCancelled {
                let message = try await receiveObject(session, record: record, scope: current)
                if message["type"] as? String == "result" {
                    guard message["success"] as? Bool == true else { throw ConnectionFailure.permissionRequired }
                    if message["id"] as? Int == 2 {
                        let data = try JSONSerialization.data(withJSONObject: message["result"] ?? [])
                        let filtered = try config.filterStates(data)
                        cached = (record.generation, .init(statusCode: 200, body: filtered, stale: false, fetchedAt: Date(), diagnostic: ""))
                        try yield(.init(data: filtered, isSnapshot: true), to: continuation); initialized = true
                    }
                } else if initialized, message["type"] as? String == "event", message["id"] as? Int == 1,
                          let event = message["event"] as? [String: Any], event["event_type"] as? String == "state_changed",
                          let data = event["data"] as? [String: Any] {
                    // Server user permissions remain authoritative, matching HTTP.
                    // Reject a malformed envelope that disagrees about its subject.
                    guard let entity = data["entity_id"] as? String,
                          ["new_state", "old_state"].allSatisfy({ key in
                              guard let state = data[key] as? [String: Any] else { return data[key] is NSNull }
                              return state["entity_id"] as? String == entity
                          }) else { continue }
                    try yield(.init(data: try JSONSerialization.data(withJSONObject: data), isSnapshot: false), to: continuation)
                }
            }
            throw CancellationError()
        }, onCancel: { Task { await session.close() } })
    }

    private func yield(_ value: StateUpdate, to continuation: AsyncThrowingStream<StateUpdate, Error>.Continuation) throws {
        if case .dropped = continuation.yield(value) { throw ConnectionFailure.sizeLimit }
    }

    private func receiveObject(_ session: any WebSocketSession, record: HomeAssistantDeviceVault.Record,
                               scope current: Scope) async throws -> [String: Any] {
        let data = try await session.receive()
        try Task.checkCancellation(); try requireCurrent(record, current)
        guard data.count <= ConnectionBounds.websocketMessageBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionFailure.validationFailed }
        return object
    }

    private func sendObject(_ object: [String: Any], session: any WebSocketSession) async throws {
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: object)
        try await session.sendText(String(decoding: data, as: UTF8.self))
    }

    public func resolveCamera(_ source: CameraSource, revision: String) async throws -> CameraStream {
        guard source.kind == "homeAssistant", source.connection == "home",
              let current = scope(), current.revision == revision else { throw ConnectionFailure.permissionRequired }
        let record = try vault.record(owner: current.owner, revision: revision, grantSet: current.grantSet)
        let config = record.configuration
        guard config.dashboardId == current.dashboardId, config.schemaVersion == 3,
              config.cameraEntities?.contains(source.entityId) == true else { throw ConnectionFailure.permissionRequired }
        _ = try ConnectionPolicy.authorize(grant: config.connectionGrant(path: "/api/websocket", write: false),
            operationName: "request", parameters: [:],
            resolvedAddresses: resolver.addresses(for: ConnectionPolicy.originHost(config.origin)),
            binding: .init(authRef: "home-device", placement: .bearer))
        let url = try await HomeAssistantCameraHandshake.resolve(origin: config.origin, token: config.token, entityId: source.entityId)
        try requireCurrent(record, current)
        return CameraStream(url: url, isAuthorized: { [weak self] in
            guard let self else { return false }
            return await self.cameraLeaseIsCurrent(record, current)
        })
    }
    private func cameraLeaseIsCurrent(_ record: HomeAssistantDeviceVault.Record, _ current: Scope) -> Bool {
        (try? requireCurrent(record, current)) != nil
    }

    private func requireCurrent(_ record: HomeAssistantDeviceVault.Record, _ expected: Scope) throws {
        guard scope() == expected, try vault.record(owner: expected.owner, revision: expected.revision, grantSet: expected.grantSet).generation == record.generation else {
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
        return HTTPTransportResponse(status: response.statusCode, body: data, headers: response.allHeaderFields.reduce(into: [:]) { result, item in
            if let key = item.key as? String, let value = item.value as? String { result[key.lowercased()] = value }
        })
    }
}
