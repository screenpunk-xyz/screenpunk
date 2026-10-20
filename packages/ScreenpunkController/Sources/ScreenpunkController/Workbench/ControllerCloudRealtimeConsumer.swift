import Foundation

private struct ControllerCloudRealtimeTokens: Sendable {
    let id: String, refresh: String
    let expires: Date
}
private actor ControllerCloudRealtimeFrames {
    private var framing = ControllerCloudRealtimeSSEDecoder()
    private var wake: ControllerCloudRealtimeWakeDecoder
    init(cursor: String) { wake = .init(cursor: cursor) }
    func reset() { framing = .init(); wake = .init(cursor: wake.cursor) }
    func acknowledge(_ cursor: String) { wake.acknowledge(cursor) }
    func append(_ data: Data) throws -> [String] {
        try framing.append(data).compactMap { try wake.consume($0) }
    }
}

/// At most one callback is active and one latest cursor/reconnect hint is pending.
/// Callbacks only enqueue admitted catch-up work; they never carry deployment authority.
private actor ControllerCloudRealtimeDelivery {
    private var valid = true, invalidated = false, reconnect = false, draining = false
    private var cursor: String?, end: Bool?
    private var acceptedCursor: String
    private let onAccepted: @Sendable (String) async -> Void
    private var task: Task<Void, Never>?
    private let onCursor: @Sendable (String) async throws -> Void
    private let onReconnect: @Sendable () async throws -> Void
    private let onRefresh: @Sendable () async -> Void
    private let onTerminal: @Sendable () async -> Void
    private let onRejected: @Sendable () async -> Void
    init(cursor: String, onAccepted: @escaping @Sendable (String) async -> Void, onCursor: @escaping @Sendable (String) async throws -> Void, onReconnect: @escaping @Sendable () async throws -> Void,
         onRefresh: @escaping @Sendable () async -> Void, onTerminal: @escaping @Sendable () async -> Void,
         onRejected: @escaping @Sendable () async -> Void) {
        self.acceptedCursor = cursor; self.onAccepted = onAccepted
        self.onCursor = onCursor; self.onReconnect = onReconnect; self.onRefresh = onRefresh; self.onTerminal = onTerminal; self.onRejected = onRejected
    }
    func offer(cursor next: String? = nil, reconnect: Bool = false, end: Bool? = nil) {
        guard valid else { return }
        if let next, ControllerCloudRealtimeCursor.greater(next, than: acceptedCursor),
           cursor == nil || ControllerCloudRealtimeCursor.greater(next, than: cursor!) { cursor = next }
        self.reconnect = self.reconnect || reconnect
        if let end { self.end = end }
        if !draining { draining = true; task = Task { await drain() } }
    }
    func invalidate() { invalidated = true; valid = false; cursor = nil; reconnect = false; end = nil; task?.cancel(); task = nil }
    private func drain() async {
        while valid && !Task.isCancelled {
            if let end { self.end = nil; cursor = nil; reconnect = false; valid = false; if end { await onRefresh() } else { await onTerminal() }; break }
            do {
                if reconnect { reconnect = false; try await onReconnect(); continue }
                if let cursor {
                    try await onCursor(cursor)
                    guard valid && !Task.isCancelled else { break }
                    acceptedCursor = cursor
                    await onAccepted(cursor)
                    if self.cursor == cursor { self.cursor = nil }
                    continue
                }
            } catch {
                guard valid && !Task.isCancelled else { break }
                // Keep the latest unaccepted cursor in memory, stop this listener, and park.
                // The facade's durable checkpoint remains authoritative; no hot retry loop follows an IO failure.
                valid = false
                await onRejected()
                guard !invalidated && !Task.isCancelled else { break }
                await onTerminal()
                break
            }
            break
        }
        draining = false; task = nil
    }
}

/// Owns one ephemeral controller listener. No Cloud feed/head polling or shared Firebase sign-in state.
public actor ControllerCloudRealtimeConsumer {
    /// Backoff injection only. Authentication deadlines use the standard cancellable monotonic sleep.
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    private let transport: any ControllerCloudRealtimeTransport
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let jitter: @Sendable () -> Double
    private var task: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var delivery: ControllerCloudRealtimeDelivery?
    public init(transport: any ControllerCloudRealtimeTransport = ControllerCloudRealtimeURLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.transport = transport; self.now = now; self.sleep = sleep; self.jitter = jitter
    }
    /// Every callback must capture the facade's consent epoch, account/workspace/client/local
    /// context and per-start generation. After each await, recheck that context INSIDE the
    /// synchronous durable admission that writes the queue/status, without an intervening await.
    /// Cancellation alone is not authority: an uncooperative callback may outlive stop().
    /// Cursor acceptance happens only after the throwing callback confirms durable admission.
    public func start(_ session: ControllerCloudRealtimeSession,
                      onCursor: @escaping @Sendable (String) async throws -> Void,
                      onReconnect: @escaping @Sendable () async throws -> Void,
                      onSessionRefreshRequired: @escaping @Sendable () async -> Void,
                      onTerminal: @escaping @Sendable () async -> Void) async throws {
        epoch &+= 1
        let selectedEpoch = epoch
        await cancelCurrent()
        guard selectedEpoch == epoch else { throw CancellationError() }
        try session.validate(now: now())
        let frames = ControllerCloudRealtimeFrames(cursor: session.cursor)
        let callbacks = ControllerCloudRealtimeDelivery(cursor: session.cursor, onAccepted: { await frames.acknowledge($0) }, onCursor: onCursor, onReconnect: onReconnect,
                                                       onRefresh: onSessionRefreshRequired, onTerminal: onTerminal,
                                                       onRejected: { [weak self] in await self?.reject(selectedEpoch) })
        delivery = callbacks
        let runner = ControllerCloudRealtimeRunner(transport: transport, now: now, sleep: sleep, jitter: jitter)
        task = Task { await runner.run(session, delivery: callbacks, frames: frames) }
    }
    /// Invalidate the facade's admission context BEFORE awaiting this method. The network
    /// listener is joined, while arbitrary callback code is cancelled but intentionally not
    /// joined (it may call stop itself or ignore cancellation). Its durable writes must fence
    /// the captured context as documented on start; a replacement listener must use a new one.
    public func stop() async { epoch &+= 1; await cancelCurrent() }
    private func reject(_ selectedEpoch: UInt64) { if epoch == selectedEpoch { task?.cancel() } }
    private func cancelCurrent() async {
        let previous = task, callbacks = delivery; task = nil; delivery = nil
        previous?.cancel()
        await callbacks?.invalidate()
        await previous?.value
    }
    deinit {
        task?.cancel()
        if let callbacks = delivery { Task { await callbacks.invalidate() } }
    }
}
private struct ControllerCloudRealtimeRunner: Sendable {
    let transport: any ControllerCloudRealtimeTransport
    let now: @Sendable () -> Date
    let sleep: ControllerCloudRealtimeConsumer.Sleep
    let jitter: @Sendable () -> Double
    private enum End: Sendable, Equatable { case disconnected, renewID, renewSession }
    func run(_ session: ControllerCloudRealtimeSession, delivery: ControllerCloudRealtimeDelivery, frames: ControllerCloudRealtimeFrames) async {
        var tokens: ControllerCloudRealtimeTokens?, attempt = 0
        while !Task.isCancelled {
            do {
                if milliseconds(now()) >= session.authorityExpiresAtMs { await delivery.offer(end: true); return }
                if tokens == nil { tokens = try await authenticate(session, refresh: nil) }
                guard let selected = tokens else { return }
                if selected.expires <= now() { tokens = try await authenticate(session, refresh: selected.refresh); continue }
                await frames.reset()
                let request = try streamRequest(session, token: selected.id)
                let remaining = min(selected.expires.timeIntervalSince(now()), Double(session.authorityExpiresAtMs) / 1000 - now().timeIntervalSince1970)
                let transport = self.transport
                let deadlineNanoseconds = UInt64(max(0, remaining) * 1_000_000_000)
                let deadlineEnd: End = selected.expires.timeIntervalSince1970 * 1000 < Double(session.authorityExpiresAtMs) ? .renewID : .renewSession
                let end = try await withThrowingTaskGroup(of: End.self) { group in
                    group.addTask {
                        try await transport.stream(request, onOpen: { response in
                            if response.status == 401 { throw ControllerCloudRealtimeFailure.authenticationRequired }
                            if response.status == 403 { throw ControllerCloudRealtimeFailure.permissionDenied }
                            guard response.status == 200,
                                  response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" else {
                                if [429, 500, 502, 503, 504].contains(response.status) { throw URLError(.resourceUnavailable) }
                                throw ControllerCloudRealtimeFailure.invalidResponse
                            }
                            await delivery.offer(reconnect: true)
                        }, onData: { data in
                            for cursor in try await frames.append(data) { await delivery.offer(cursor: cursor) }
                        })
                        return .disconnected
                    }
                    group.addTask {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: deadlineNanoseconds)
                        try Task.checkCancellation()
                        return deadlineEnd
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                if end == .renewSession { await delivery.offer(end: true); return }
                if end == .renewID { tokens = try await authenticate(session, refresh: selected.refresh); continue }
            } catch is CancellationError { return }
            catch is ControllerCloudRealtimeFailure {
                guard !Task.isCancelled else { return }
                // Early rejection/revocation is not proof of ordinary token expiry. Park until fresh scope admission.
                await delivery.offer(end: false)
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Infrastructure failures are retried with bounded jitter; error/URL bodies are never logged.
            }
            do {
                let delay = min(30, pow(2, Double(min(attempt, 5)))) * (0.5 + min(1, max(0, jitter())) * 0.5)
                attempt = min(attempt + 1, 6)
                try await sleep(min(delay, max(0, Double(session.authorityExpiresAtMs) / 1000 - now().timeIntervalSince1970)))
            } catch { return }
        }
    }
    private func authenticate(_ session: ControllerCloudRealtimeSession, refresh: String?) async throws -> ControllerCloudRealtimeTokens {
        guard milliseconds(now()) < session.authorityExpiresAtMs else { throw ControllerCloudRealtimeFailure.authenticationRequired }
        let endpoint = refresh == nil ? "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken" : "https://securetoken.googleapis.com/v1/token"
        var url = URLComponents(string: endpoint)!
        url.queryItems = [.init(name: "key", value: session.firebase.apiKey)]
        var request = URLRequest(url: url.url!); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let refresh {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents(); form.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: refresh)]
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["token": session.customToken, "returnSecureToken": true])
        }
        let response = try await transport.request(request, maximumBytes: 65_536)
        try Task.checkCancellation()
        if [400, 401, 403].contains(response.status) { throw ControllerCloudRealtimeFailure.authenticationRequired }
        if [429, 500, 502, 503, 504].contains(response.status) { throw URLError(.resourceUnavailable) }
        guard response.status == 200, response.data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = object[refresh == nil ? "idToken" : "id_token"] as? String,
              let renewed = object[refresh == nil ? "refreshToken" : "refresh_token"] as? String,
              let ttlText = object[refresh == nil ? "expiresIn" : "expires_in"] as? String,
              let ttl = Double(ttlText), ttl >= 1, ttl <= 3_600,
              !id.isEmpty, id.utf8.count <= 16_384, !renewed.isEmpty, renewed.utf8.count <= 16_384,
              refresh == nil || object["user_id"] as? String == session.firebaseUID else {
            throw ControllerCloudRealtimeFailure.invalidResponse
        }
        // The token comes only from the HTTPS Firebase exchange. Inspect identity to reject mixed sessions;
        // RTDB verifies its signature and rules. This is not a local token-verification authority.
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ControllerCloudRealtimeFailure.invalidResponse }
        let encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let raw = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)),
              let claims = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              claims["sub"] as? String == session.firebaseUID, claims["aud"] as? String == session.firebase.projectId,
              claims["iss"] as? String == "https://securetoken.google.com/" + session.firebase.projectId,
              let exp = claims["exp"] as? Double, exp.isFinite, exp > now().timeIntervalSince1970,
              exp <= now().timeIntervalSince1970 + ttl + 60 else { throw ControllerCloudRealtimeFailure.invalidResponse }
        return .init(id: id, refresh: renewed, expires: min(Date(timeIntervalSince1970: exp), now().addingTimeInterval(ttl)))
    }
    private func streamRequest(_ session: ControllerCloudRealtimeSession, token: String) throws -> URLRequest {
        var url = URLComponents(url: session.firebase.databaseURL, resolvingAgainstBaseURL: false)!
        url.path = "/" + session.wakePath + ".json"; url.queryItems = [.init(name: "auth", value: token)]
        guard let target = url.url else { throw ControllerCloudRealtimeFailure.invalidSession }
        var request = URLRequest(url: target); request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept"); request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
