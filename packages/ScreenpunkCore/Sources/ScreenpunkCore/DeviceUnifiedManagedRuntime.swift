import Foundation

struct DeviceUnifiedPrivateRuntimeSeed {
    let hasGeneric: Bool
    let homeAssistant: HomeAssistantProvisioning?
    let publicReads: PublicReadProvisioning?
}
private final class CommonRuntimeAdmission: DeviceImmutableGenericAdmissionDriver, @unchecked Sendable {
    let validate: () throws -> Void
    init(validate: @escaping () throws -> Void) { self.validate = validate }
    func reserve(scope: DeviceImmutableGenericScope, validateResources: () throws -> Void,
        onCancel: @escaping @Sendable () -> Void) throws -> any DeviceImmutableGenericReservation {
        try validate(); try validateResources(); try validate()
        return CommonRuntimeReservation(validate: validate)
    }
}
private final class CommonRuntimeReservation: DeviceImmutableGenericReservation, @unchecked Sendable {
    let validate: () throws -> Void
    private let lock = NSLock()
    private var finished = false
    init(validate: @escaping () throws -> Void) { self.validate = validate }
    func check() throws { lock.lock(); let closed = finished; lock.unlock(); guard !closed else { throw ConnectionFailure.permissionRequired }; try Task.checkCancellation(); try validate() }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
@_spi(ManagedRender) public struct DeviceUnifiedRuntimeUpdate: Sendable {
    public let data: Data
    public let isSnapshot: Bool
}
/// An opaque runtime retains the original private grants. Package code can only invoke
/// declared operations; it cannot fetch credentials or retarget the source graph.
@_spi(ManagedRender) public final class DeviceUnifiedManagedRuntime: @unchecked Sendable {
    public let content: DeviceManagedStaticContent
    public let manifest: DashboardManifest
    public let publicReads: PublicReadProvisioning?
    private let generic: (any DeviceImmutableGenericOperations)?
    private let home: UnifiedHomeRuntime?
    private let validate: () throws -> Void
    private let validateActive: () throws -> Void
    private init(content: DeviceManagedStaticContent, manifest: DashboardManifest, seed: DeviceUnifiedPrivateRuntimeSeed,
        generic: (any DeviceImmutableGenericOperations)?, http: any HTTPTransport, webSocket: any WebSocketTransport,
        resolver: any DestinationResolver, validate: @escaping () throws -> Void, validateActive: @escaping () throws -> Void) {
        self.content = content; self.manifest = manifest; publicReads = seed.publicReads
        self.generic = generic; self.validate = validate; self.validateActive = validateActive
        home = seed.homeAssistant.map { UnifiedHomeRuntime(configuration: $0, http: http, webSocket: webSocket, resolver: resolver, validate: validateActive) }
    }
    public func verifyResources() throws { try content.verifyResources(); try validate() }
    public func verifyActive() throws { try verifyResources(); try validateActive(); try Task.checkCancellation() }
    public func request(alias: String, operation: String, parameters: [String: String], readOnly: Bool = false) async throws -> ConnectionHTTPResult {
        try verifyActive()
        let result: ConnectionHTTPResult
        if alias == "home", let home { result = try await home.request(operation: operation, parameters: parameters, readOnly: readOnly) }
        else if let generic { result = readOnly ? try await generic.requestRead(alias: alias, operation: operation, parameters: parameters) : try await generic.request(alias: alias, operation: operation, parameters: parameters) }
        else { throw ConnectionFailure.permissionRequired }
        try verifyActive(); return result
    }
    public func subscribe(alias: String, operation: String, parameters: [String: String]) async throws -> AsyncThrowingStream<DeviceUnifiedRuntimeUpdate, Error> {
        try verifyActive()
        if alias == "home", let home { return try await home.subscribe(operation: operation, parameters: parameters) }
        guard let generic else { throw ConnectionFailure.permissionRequired }
        let id = try await generic.subscribe(alias: alias, operation: operation, parameters: parameters)
        do { try verifyActive() } catch { await generic.unsubscribe(id: id); throw error }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task { [self] in
                do {
                    while !Task.isCancelled {
                        try verifyActive(); let data = try await generic.receive(id: id); try verifyActive()
                        if case .dropped = continuation.yield(.init(data: data, isSnapshot: false)) { throw ConnectionFailure.sizeLimit }
                    }
                    throw CancellationError()
                } catch { continuation.finish(throwing: error) }
                await generic.unsubscribe(id: id)
            }
            continuation.onTermination = { _ in task.cancel(); Task { await generic.unsubscribe(id: id) } }
        }
    }
    public func resolveCamera(_ source: CameraSource) async throws -> DeviceUnifiedCameraStream {
        try verifyActive()
        guard let home else { throw ConnectionFailure.permissionRequired }
        let stream = try await home.resolveCamera(source)
        try verifyActive(); return stream
    }
    public func cancel() async { await generic?.cancel(); await home?.cancel() }
    /// Public-read provisioning contains no secrets. The returned transport still
    /// checks the original private graph and common presentation on every result.
    public func guardedHTTP(_ transport: any HTTPTransport) -> any HTTPTransport { UnifiedRuntimeHTTP(delegate: transport, validate: validateActive) }
    static func issue(session: DeviceUnifiedInventorySession, operationID: UUID,
        http: any HTTPTransport, webSocket: any WebSocketTransport, resolver: any DestinationResolver,
        clock: any PairingClock, historicalMounted: Bool = false) async throws -> DeviceUnifiedManagedRuntime {
        let source: (resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore, capture: DeviceMixedInventoryStore.Capture, validate: () throws -> Void)
        if historicalMounted {
            guard let retained = try session.lastSuccessfulRuntimeSourceExact() else { throw DeviceManagedRenderFailure.invalidContent }
            source = retained
        } else { source = try session.runtimeSourceExact() }
        guard let historicalEntryID = source.capture.snapshot.configuredEntryID else { throw DeviceManagedRenderFailure.invalidContent }
        let local = historicalMounted
            ? try source.resolver.installedLocalRuntimeSourceExact(source.original, store: source.store, current: source.capture, entryID: historicalEntryID, historicalMounted: true)
            : try source.resolver.selectedLocalRuntimeSourceExact(source.original, store: source.store, current: source.capture)
        let seed = try local.gate.makeUnifiedRuntimeSeedExact(binding: local.binding, entryID: local.entryID)
        try source.validate()
        let presentation = UnifiedRuntimePresentationBinding()
        let activeValidate: () throws -> Void = {
            try source.validate()
            guard let mounted = try session.mountedAssociation(), mounted.generationID == source.capture.snapshot.generationID,
                mounted.entryID == local.entryID, mounted.manifestDigest == local.package.revision.digest else { throw ConnectionFailure.permissionRequired }
            try session.verifyRuntimePresentationMountedExact(presentation.requireContent())
            try source.validate()
        }
        let generic = seed.hasGeneric ? try await local.gate.makeGenericRuntimeExact(binding: local.binding, entryID: local.entryID,
            admission: CommonRuntimeAdmission(validate: source.validate), http: UnifiedRuntimeHTTP(delegate: http, validate: activeValidate),
            webSocket: UnifiedRuntimeSocketTransport(delegate: webSocket, validate: activeValidate), resolver: resolver, clock: clock) : nil
        do {
            try source.validate()
            guard let entry = source.capture.snapshot.entries.first(where: { $0.entryID == local.entryID }), case .retainedLocal(let retained) = entry else { throw DeviceManagedRenderFailure.invalidContent }
            let content = try DeviceManagedRenderProjection.makeRuntime(package: local.package, operationID: operationID,
                generationID: source.capture.snapshot.generationID, entryID: local.entryID,
                displayName: retained.entry.displayName, validate: source.validate)
            presentation.bind(content)
            let runtime = DeviceUnifiedManagedRuntime(content: content, manifest: local.package.manifest, seed: seed,
                generic: generic, http: http, webSocket: webSocket, resolver: resolver, validate: source.validate, validateActive: activeValidate)
            if historicalMounted { try session.retainRestoredRuntimePresentationExact(content, historical: source.capture) }
            else { try session.retainRuntimePresentationExact(content, current: source.capture) }
            try source.validate(); return runtime
        } catch { await generic?.cancel(); throw error }
    }
}
extension DeviceUnifiedInventorySession {
    @_spi(ManagedRender) public func lastSuccessfulManagedRuntime(operationID: UUID, http: any HTTPTransport,
        webSocket: any WebSocketTransport, resolver: any DestinationResolver, clock: any PairingClock) async throws -> DeviceUnifiedManagedRuntime {
        try await DeviceUnifiedManagedRuntime.issue(session: self, operationID: operationID, http: http, webSocket: webSocket, resolver: resolver, clock: clock, historicalMounted: true)
    }
    @_spi(ManagedRender) public func makeManagedRuntime(operationID: UUID, http: any HTTPTransport,
        webSocket: any WebSocketTransport, resolver: any DestinationResolver, clock: any PairingClock) async throws -> DeviceUnifiedManagedRuntime {
        try await DeviceUnifiedManagedRuntime.issue(session: self, operationID: operationID, http: http, webSocket: webSocket, resolver: resolver, clock: clock)
    }
}
/// Issuance binds an opaque candidate; only the session's successful native
/// mount callback can authorize that exact object for private runtime work.
private final class UnifiedRuntimePresentationBinding {
    private let lock = NSLock()
    private var content: DeviceManagedStaticContent?
    func bind(_ value: DeviceManagedStaticContent) { lock.lock(); defer { lock.unlock() }; precondition(content == nil); content = value }
    func requireContent() throws -> DeviceManagedStaticContent {
        lock.lock(); defer { lock.unlock() }
        guard let content else { throw ConnectionFailure.permissionRequired }
        return content
    }
}
private struct UnifiedRuntimeHTTP: HTTPTransport {
    let delegate: any HTTPTransport
    let validate: () throws -> Void
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        try Task.checkCancellation(); try validate(); let result = try await delegate.send(request)
        try Task.checkCancellation(); try validate(); return result
    }
}
private struct UnifiedRuntimeSocketTransport: WebSocketTransport {
    let delegate: any WebSocketTransport
    let validate: () throws -> Void
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        try Task.checkCancellation(); try validate()
        let session = try await delegate.connect(request)
        do { try Task.checkCancellation(); try validate(); return UnifiedRuntimeSocket(session: session, validate: validate) }
        catch { await session.close(); throw error }
    }
}
private actor UnifiedRuntimeSocket: WebSocketSession {
    let session: any WebSocketSession
    let validate: () throws -> Void
    private var closed = false
    init(session: any WebSocketSession, validate: @escaping () throws -> Void) { self.session = session; self.validate = validate }
    private func check() throws { guard !closed else { throw ConnectionFailure.permissionRequired }; try Task.checkCancellation(); try validate() }
    func receive() async throws -> Data { try check(); let bytes = try await session.receive(); do { try check(); return bytes } catch { await close(); throw error } }
    func send(_ data: Data) async throws { try check(); try await session.send(data); try check() }
    func sendText(_ text: String) async throws { try check(); try await session.sendText(text); try check() }
    func close() async { guard !closed else { return }; closed = true; await session.close() }
}
private actor UnifiedHomeRuntime {
    let configuration: HomeAssistantProvisioning
    let http: any HTTPTransport
    let webSocket: any WebSocketTransport
    let resolver: any DestinationResolver
    let validate: () throws -> Void
    private var sockets: [UUID: any WebSocketSession] = [:]
    private var cached: ConnectionHTTPResult?
    private var inFlight = false
    private var retired = false
    init(configuration: HomeAssistantProvisioning, http: any HTTPTransport, webSocket: any WebSocketTransport,
        resolver: any DestinationResolver, validate: @escaping () throws -> Void) {
        self.configuration = configuration; self.http = http; self.webSocket = webSocket; self.resolver = resolver; self.validate = validate
    }
    private func check() throws { guard !retired else { throw ConnectionFailure.permissionRequired }; try Task.checkCancellation(); try validate() }
    func cancel() async { retired = true; cached = nil; let live = Array(sockets.values); sockets.removeAll(); for socket in live { await socket.close() } }
    private func destination(path: String, write: Bool) throws -> URL {
        let grant = configuration.connectionGrant(path: path, write: write)
        return try ConnectionPolicy.authorize(grant: grant, operationName: "request", parameters: [:],
            resolvedAddresses: resolver.addresses(for: ConnectionPolicy.originHost(configuration.origin)),
            binding: .init(authRef: "home-device", placement: .bearer)).url
    }
    func resolveCamera(_ source: CameraSource) async throws -> DeviceUnifiedCameraStream {
        try check()
        guard source.kind == "homeAssistant", source.connection == "home", configuration.schemaVersion == 3,
            configuration.cameraEntities?.contains(source.entityId) == true else { throw ConnectionFailure.permissionRequired }
        var components = URLComponents(url: try destination(path: "/api/websocket", write: false), resolvingAgainstBaseURL: false)
        let secure = components?.scheme == "https"; components?.scheme = secure ? "wss" : "ws"
        guard let url = components?.url else { throw ConnectionFailure.validationFailed }
        let socket = try await webSocket.connect(.init(url: url, headers: [:], timeout: 12, maxMessageBytes: 65536))
        let id = UUID(); sockets[id] = socket
        let deadline = Task { try await Task.sleep(nanoseconds: 12_000_000_000); await socket.close() }
        defer { deadline.cancel(); sockets.removeValue(forKey: id); Task { await socket.close() } }
        return try await withTaskCancellationHandler(operation: {
            guard try await receive(socket)["type"] as? String == "auth_required" else { throw ConnectionFailure.permissionRequired }
            try await send(["type": "auth", "access_token": configuration.token], socket)
            guard try await receive(socket)["type"] as? String == "auth_ok" else { throw ConnectionFailure.permissionRequired }
            try await send(["id": 1, "type": "camera/stream", "entity_id": source.entityId, "format": "hls"], socket)
            let response = try await receive(socket)
            guard response["id"] as? Int == 1, response["success"] as? Bool == true,
                let result = response["result"] as? [String: Any], let path = result["url"] as? String else { throw ConnectionFailure.deniedEgress }
            let media = try UnifiedCameraMediaURL.resolve(path: path, origin: configuration.origin)
            try check()
            return DeviceUnifiedCameraStream(url: media, isAuthorized: { [weak self] in
                guard let self else { return false }; return await self.cameraAuthorized()
            })
        }, onCancel: { Task { await socket.close() } })
    }
    private func cameraAuthorized() -> Bool { (try? check()) != nil }
    func request(operation: String, parameters: [String: String], readOnly: Bool) async throws -> ConnectionHTTPResult {
        try check(); let authorized = try configuration.authorize(operation: operation, parameters: parameters)
        let write = authorized.body != nil
        guard !readOnly || !write, !inFlight else { throw ConnectionFailure.permissionRequired }
        if write { guard let cached, !cached.stale, Date().timeIntervalSince(cached.fetchedAt) <= 45 else { throw ConnectionFailure.deviceOffline } }
        let url = try destination(path: authorized.path, write: write)
        inFlight = true; defer { inFlight = false }
        do {
            let response = try await http.send(.init(url: url, method: write ? "POST" : "GET",
                headers: ["Authorization": "Bearer " + configuration.token], body: authorized.body, timeout: 10, maxBytes: 1024 * 1024))
            try check()
            guard response.status != 401, response.status != 403 else { cached = nil; throw ConnectionFailure.permissionRequired }
            guard (200...299).contains(response.status), response.body.count <= 1024 * 1024 else { throw ConnectionFailure.deviceOffline }
            let result = ConnectionHTTPResult(statusCode: response.status, body: write ? Data("null".utf8) : try configuration.filterStates(response.body), stale: false, fetchedAt: Date(), diagnostic: "")
            if !write { cached = result }; return result
        } catch {
            try check() // Removed grants and retired presentations never return cached data.
            if !write, var previous = cached { previous.stale = true; cached = previous; return previous }
            if var previous = cached { previous.stale = true; cached = previous }
            throw error
        }
    }
    func subscribe(operation: String, parameters: [String: String]) throws -> AsyncThrowingStream<DeviceUnifiedRuntimeUpdate, Error> {
        try check(); guard operation == "stateChanged", parameters.isEmpty else { throw ConnectionFailure.permissionRequired }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task { do { try await self.stream(continuation) } catch { continuation.finish(throwing: error) } }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func stream(_ continuation: AsyncThrowingStream<DeviceUnifiedRuntimeUpdate, Error>.Continuation) async throws {
        try check(); var components = URLComponents(url: try destination(path: "/api/websocket", write: false), resolvingAgainstBaseURL: false)
        let secure = components?.scheme == "https"; components?.scheme = secure ? "wss" : "ws"
        guard let url = components?.url else { throw ConnectionFailure.validationFailed }
        let socket = try await webSocket.connect(.init(url: url, headers: [:], timeout: 10, maxMessageBytes: ConnectionBounds.websocketMessageBytes))
        let id = UUID(); sockets[id] = socket
        defer { sockets.removeValue(forKey: id); Task { await socket.close() } }
        try await withTaskCancellationHandler(operation: {
            guard try await receive(socket)["type"] as? String == "auth_required" else { throw ConnectionFailure.permissionRequired }
            try await send(["type": "auth", "access_token": configuration.token], socket)
            guard try await receive(socket)["type"] as? String == "auth_ok" else { throw ConnectionFailure.permissionRequired }
            try await send(["id": 1, "type": "subscribe_events", "event_type": "state_changed"], socket)
            try await send(["id": 2, "type": "get_states"], socket)
            var initialized = false
            while !Task.isCancelled {
                let message = try await receive(socket)
                if message["type"] as? String == "result" {
                    guard message["success"] as? Bool == true else { throw ConnectionFailure.permissionRequired }
                    if message["id"] as? Int == 2 {
                        let bytes = try configuration.filterStates(JSONSerialization.data(withJSONObject: message["result"] ?? []))
                        cached = .init(statusCode: 200, body: bytes, stale: false, fetchedAt: Date(), diagnostic: "")
                        if case .dropped = continuation.yield(.init(data: bytes, isSnapshot: true)) { throw ConnectionFailure.sizeLimit }; initialized = true
                    }
                } else if initialized, message["type"] as? String == "event", message["id"] as? Int == 1,
                    let event = message["event"] as? [String: Any], event["event_type"] as? String == "state_changed",
                    let data = event["data"] as? [String: Any], let entity = data["entity_id"] as? String,
                    ["new_state", "old_state"].allSatisfy({ key in
                        guard let state = data[key] as? [String: Any] else { return data[key] is NSNull }; return state["entity_id"] as? String == entity
                    }) {
                    if case .dropped = continuation.yield(.init(data: try JSONSerialization.data(withJSONObject: data), isSnapshot: false)) { throw ConnectionFailure.sizeLimit }
                }
            }
            throw CancellationError()
        }, onCancel: { Task { await socket.close() } })
    }
    private func send(_ value: [String: Any], _ socket: any WebSocketSession) async throws {
        try check(); try await socket.send(try JSONSerialization.data(withJSONObject: value)); try check()
    }
    private func receive(_ socket: any WebSocketSession) async throws -> [String: Any] {
        try check(); let bytes = try await socket.receive(); try check()
        guard bytes.count <= ConnectionBounds.websocketMessageBytes, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ConnectionFailure.validationFailed }; return value
    }
}

/// Native media capability, never serialized into the screen JavaScript bridge.
@_spi(ManagedRender) public struct DeviceUnifiedCameraStream: Sendable {
    public let url: URL
    public let isAuthorized: @Sendable () async -> Bool
}

enum UnifiedCameraMediaURL {
    static func resolve(path: String, origin: String) throws -> URL {
        guard path.utf8.count <= 2048,
            path.range(of: "^/api/hls/[A-Za-z0-9_-]+/master_playlist\\.m3u8$", options: .regularExpression) == path.startIndex..<path.endIndex,
            let base = URL(string: origin), let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw ConnectionFailure.deniedEgress }
        return url
    }
}
