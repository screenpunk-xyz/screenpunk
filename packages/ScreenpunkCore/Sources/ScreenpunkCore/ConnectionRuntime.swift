import Foundation

/// Device-local connection runtime. The Mac is not a required proxy.
public actor ConnectionRuntime {
    public static let macIsRuntimeProxy = false

    private var grants: [String: ConnectionGrant] = [:]
    private var bindings: [String: ConnectionAuthBinding] = [:]
    private let store: any CredentialStore
    private let http: any HTTPTransport
    private let webSocket: any WebSocketTransport
    private let resolver: any DestinationResolver
    private var dashboardStore: DashboardStore
    private var subscriptions: [String: SubscriptionRecord] = [:]
    private var subscriptionAttempts: [String: UUID] = [:]
    /// Bumped by `clearCredentials`. Work that was in flight across an unlink
    /// must not write to the store or register sockets when it resumes.
    private var epoch = 0
    private let clock: any PairingClock
    private let httpBounds: HTTPAdapterBounds
    private let authorizeScope: @Sendable () throws -> Void

    public init(
        dashboardId: String,
        store: any CredentialStore,
        http: any HTTPTransport,
        webSocket: any WebSocketTransport,
        resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(),
        clock: any PairingClock = SystemClock(),
        httpBounds: HTTPAdapterBounds = .production,
        authorizeScope: @escaping @Sendable () throws -> Void = {}
    ) {
        self.store = store
        self.http = http
        self.webSocket = webSocket
        self.resolver = resolver
        self.dashboardStore = DashboardStore(dashboardId: dashboardId)
        self.clock = clock
        self.httpBounds = httpBounds
        self.authorizeScope = authorizeScope
    }

    public func install(grant: ConnectionGrant, binding: ConnectionAuthBinding) throws {
        try ConnectionGrantValidator.validate(grant)
        guard binding.authRef == grant.authRef else {
            throw ConnectionFailure.validationFailed
        }
        grants[grant.alias] = grant
        bindings[grant.alias] = binding
    }

    /// Event polling may only invoke approved side-effect-free GET operations.
    public func requestRead(alias: String, operation: String, parameters: [String: String]) async throws -> ConnectionHTTPResult {
        let context = try context(alias: alias)
        guard let spec = context.grant.operations.first(where: { $0.name == operation }),
              spec.kind == .http, spec.method == .GET, !spec.write, spec.idempotent else {
            throw ConnectionFailure.permissionRequired
        }
        return try await request(alias: alias, operation: operation, parameters: parameters)
    }

    public func request(
        alias: String,
        operation: String,
        parameters: [String: String]
    ) async throws -> ConnectionHTTPResult {
        let prepared = try prepareHTTP(alias: alias, operation: operation, parameters: parameters)
        let startedIn = epoch
        do {
            let response = try await http.send(prepared.request)
            try authorizeScope()
            guard startedIn == epoch else {
                throw ConnectionFailure.permissionRequired
            }
            if (300...399).contains(response.status) {
                throw ConnectionFailure.deniedEgress
            }
            if response.body.count > prepared.request.maxBytes {
                throw ConnectionFailure.sizeLimit
            }
            guard (200...299).contains(response.status) else {
                throw UpstreamStatusFailure(status: response.status)
            }
            let json = String(decoding: response.body, as: UTF8.self)
            if prepared.write == false {
                try dashboardStore.rememberRead(
                    cacheKey: prepared.cacheKey,
                    json: json,
                    fetchedAt: clock.now
                )
            }
            return ConnectionHTTPResult(
                statusCode: response.status,
                body: response.body,
                stale: false,
                fetchedAt: clock.now,
                diagnostic: ConnectionRedaction.diagnostic(
                    operation: operation,
                    status: response.status,
                    origin: prepared.origin,
                    lan: prepared.lan,
                    at: clock.now
                )
            )
        } catch {
            try authorizeScope()
            guard startedIn == epoch else {
                throw ConnectionFailure.permissionRequired
            }
            // Only an upstream 4xx/5xx carries a status into the stale result; a
            // transport failure, refused redirect, or oversized body reports 0.
            let upstreamStatus = (error as? UpstreamStatusFailure)?.status ?? 0
            if prepared.write == false, let cached = dashboardStore.cachedRead(cacheKey: prepared.cacheKey) {
                _ = dashboardStore.markStale(cacheKey: prepared.cacheKey)
                return ConnectionHTTPResult(
                    statusCode: upstreamStatus,
                    body: Data(cached.valueJSON.utf8),
                    stale: true,
                    fetchedAt: cached.fetchedAt,
                    diagnostic: ConnectionRedaction.diagnostic(
                        operation: operation,
                        status: upstreamStatus,
                        origin: prepared.origin,
                        lan: prepared.lan,
                        at: clock.now
                    )
                )
            }
            if let failure = error as? ConnectionFailure {
                throw failure
            }
            throw ConnectionFailure.deviceOffline
        }
    }

    public func subscribe(
        alias: String,
        operation: String,
        parameters: [String: String],
        consumer: String = "dashboard"
    ) async throws -> SubscriptionID {
        var prepared = try prepareWebSocket(alias: alias, operation: operation, parameters: parameters)
        guard consumer.utf8.count <= 8192 else { throw ConnectionFailure.sizeLimit }
        if consumer != "dashboard" { prepared.cacheKey = consumer + "\u{1f}" + prepared.cacheKey }
        let keys = Set(subscriptions.keys).union(subscriptionAttempts.keys)
        guard keys.contains(prepared.cacheKey) || keys.count < 64 else { throw ConnectionFailure.sizeLimit }
        let startedIn = epoch
        let attempt = UUID()
        subscriptionAttempts[prepared.cacheKey] = attempt
        defer {
            if subscriptionAttempts[prepared.cacheKey] == attempt {
                subscriptionAttempts.removeValue(forKey: prepared.cacheKey)
            }
        }
        if let existing = subscriptions.removeValue(forKey: prepared.cacheKey) {
            await existing.session.close()
        }
        guard startedIn == epoch, subscriptionAttempts[prepared.cacheKey] == attempt else {
            throw ConnectionFailure.permissionRequired
        }
        try authorizeScope()
        let session = try await webSocket.connect(prepared.request)
        do { try authorizeScope() } catch { await session.close(); throw error }
        guard startedIn == epoch, subscriptionAttempts[prepared.cacheKey] == attempt else {
            await session.close()
            throw ConnectionFailure.permissionRequired
        }
        let id = SubscriptionID(UUID().uuidString)
        subscriptions[prepared.cacheKey] = SubscriptionRecord(
            id: id,
            key: prepared.cacheKey,
            session: session,
            origin: prepared.origin,
            lan: prepared.lan,
            operation: operation
        )
        return id
    }

    public func receive(id: SubscriptionID) async throws -> Data {
        try authorizeScope()
        guard let record = subscriptions.values.first(where: { $0.id == id }) else {
            throw ConnectionFailure.permissionRequired
        }
        let data = try await record.session.receive()
        try authorizeScope()
        guard subscriptions[record.key]?.id == id else {
            // Unsubscribed, replaced, or unlinked while the read was pending.
            throw ConnectionFailure.permissionRequired
        }
        if data.count > ConnectionBounds.websocketMessageBytes {
            throw ConnectionFailure.sizeLimit
        }
        try dashboardStore.rememberRead(
            cacheKey: record.key,
            json: String(decoding: data, as: UTF8.self),
            fetchedAt: clock.now
        )
        return data
    }

    public func unsubscribe(id: SubscriptionID) async {
        guard let match = subscriptions.first(where: { $0.value.id == id }) else { return }
        subscriptions.removeValue(forKey: match.key)
        await match.value.session.close()
    }

    public func lastRead(alias: String, operation: String, parameters: [String: String]) -> CacheRecord? {
        guard (try? authorizeScope()) != nil else { return nil }
        return dashboardStore.cachedRead(
            cacheKey: DashboardStore.cacheKey(
                alias: alias,
                operation: operation,
                parametersJSON: ConnectionPolicy.canonicalParameters(parameters)
            )
        )
    }

    /// Unlink: no further request can be built, every open socket is closed,
    /// cached reads and saved state are gone, and stored secrets are deleted.
    /// In-memory state is dropped before the first suspension point so work that
    /// resumes mid-unlink observes the cleared runtime.
    public func clearCredentials() async throws {
        epoch += 1
        grants.removeAll()
        bindings.removeAll()
        let open = subscriptions.values.map(\.session)
        subscriptions.removeAll()
        subscriptionAttempts.removeAll()
        dashboardStore.clear()
        let deletion = Result { try store.deleteAll() }
        for session in open {
            await session.close()
        }
        try deletion.get()
    }

    private struct UpstreamStatusFailure: Error {
        var status: Int
    }

    private struct PreparedHTTP {
        var request: AuthorizedHTTPRequest
        var cacheKey: String
        var write: Bool
        var origin: String
        var lan: Bool
    }

    private struct PreparedWebSocket {
        var request: AuthorizedWebSocketRequest
        var cacheKey: String
        var origin: String
        var lan: Bool
    }

    private struct SubscriptionRecord {
        var id: SubscriptionID
        var key: String
        var session: any WebSocketSession
        var origin: String
        var lan: Bool
        var operation: String
    }

    private func prepareHTTP(
        alias: String,
        operation: String,
        parameters: [String: String]
    ) throws -> PreparedHTTP {
        let context = try context(alias: alias)
        guard context.grant.transport == .http else { throw ConnectionFailure.permissionRequired }
        let host = try ConnectionPolicy.originHost(context.grant.origin)
        let resolved = try resolver.addresses(for: host)
        let destination = try ConnectionPolicy.authorize(
            grant: context.grant,
            operationName: operation,
            parameters: parameters,
            resolvedAddresses: resolved,
            binding: context.binding
        )
        var headers: [String: String] = [:]
        var url = destination.url
        try ConnectionAuth.apply(
            binding: context.binding,
            secret: try store.secret(for: context.grant.authRef),
            headers: &headers,
            url: &url
        )
        let body: Data?
        if destination.method == "GET" || destination.method == "DELETE" {
            url = try ConnectionPolicy.mergeQueryParameters(url: url, parameters: destination.queryParameters)
            body = nil
        } else {
            body = try ConnectionPolicy.jsonBody(parameters)
        }
        let operationSpec = context.grant.operations.first { $0.name == operation }!
        return PreparedHTTP(
            request: AuthorizedHTTPRequest(
                url: url,
                method: destination.method,
                headers: headers,
                body: body,
                timeout: httpBounds.timeoutSeconds,
                maxBytes: httpBounds.maxResponseBytes
            ),
            cacheKey: DashboardStore.cacheKey(
                alias: alias,
                operation: operation,
                parametersJSON: ConnectionPolicy.canonicalParameters(parameters)
            ),
            write: operationSpec.write,
            origin: context.grant.origin,
            lan: context.grant.lan
        )
    }

    private func prepareWebSocket(
        alias: String,
        operation: String,
        parameters: [String: String]
    ) throws -> PreparedWebSocket {
        let context = try context(alias: alias)
        guard context.grant.transport == .ws else { throw ConnectionFailure.permissionRequired }
        let host = try ConnectionPolicy.originHost(context.grant.origin)
        let resolved = try resolver.addresses(for: host)
        let destination = try ConnectionPolicy.authorize(
            grant: context.grant,
            operationName: operation,
            parameters: parameters,
            resolvedAddresses: resolved,
            binding: context.binding
        )
        var headers: [String: String] = [:]
        var url = destination.url
        try ConnectionAuth.apply(
            binding: context.binding,
            secret: try store.secret(for: context.grant.authRef),
            headers: &headers,
            url: &url
        )
        url = try ConnectionPolicy.mergeQueryParameters(url: url, parameters: destination.queryParameters)
        return PreparedWebSocket(
            request: AuthorizedWebSocketRequest(
                url: url,
                headers: headers,
                timeout: httpBounds.timeoutSeconds,
                maxMessageBytes: ConnectionBounds.websocketMessageBytes
            ),
            cacheKey: DashboardStore.cacheKey(
                alias: alias,
                operation: operation,
                parametersJSON: ConnectionPolicy.canonicalParameters(parameters)
            ),
            origin: context.grant.origin,
            lan: context.grant.lan
        )
    }

    private func context(alias: String) throws -> (grant: ConnectionGrant, binding: ConnectionAuthBinding) {
        try authorizeScope()
        guard let grant = grants[alias], let binding = bindings[alias] else {
            throw ConnectionFailure.permissionRequired
        }
        return (grant, binding)
    }
}

public struct SystemClock: PairingClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedResolver: DestinationResolver, Sendable {
    public var addresses: [String]
    public init(_ addresses: [String]) { self.addresses = addresses }
    public func addresses(for host: String) throws -> [String] { addresses }
}
