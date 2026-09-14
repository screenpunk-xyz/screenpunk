import XCTest
@testable import ScreenpunkCore

/// TEST_PLAN "Unlink": credentials and grants are gone before any further request can be built.
final class UnlinkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func statusGrant(authRef: String = "keychain:fixture-status") throws -> ConnectionGrant {
        var grant = try ConnectionGrantValidator.decode(RepoFixtures.data("schemas/fixtures/valid/connection-grant.json"))
        grant.authRef = authRef
        return grant
    }

    private func eventsGrant() throws -> ConnectionGrant {
        try ConnectionGrantValidator.decode(RepoFixtures.data("schemas/fixtures/valid/connection-grant-ws.json"))
    }

    func testClearCredentialsRemovesSecretsAndGrantsBeforeAnyFurtherRequest() async throws {
        let store = MemoryCredentialStore()
        let http = ScriptedHTTPTransport(fallback: .success(HTTPTransportResponse(status: 200, body: Data("{}".utf8))))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try statusGrant()
        try store.put(Data("fixture-token".utf8), for: grant.authRef)
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))

        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer fixture-token")

        try await runtime.clearCredentials()

        XCTAssertNil(try store.secret(for: grant.authRef), "Keychain-backed secret is deleted")
        let retained = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertNil(retained, "cached reads do not survive unlink")
        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("an unlinked runtime must not build requests")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        do {
            _ = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
            XCTFail("an unlinked runtime must not open sockets")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        XCTAssertEqual(http.requests.count, 1, "no transport call happens after unlink")
    }

    func testClearCredentialsCoversEveryAuthRefAndIsIdempotent() async throws {
        let store = MemoryCredentialStore()
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: ScriptedHTTPTransport(),
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let status = try statusGrant()
        let events = try eventsGrant()
        try store.put(Data("a".utf8), for: status.authRef)
        try store.put(Data("b".utf8), for: events.authRef)
        try store.put(Data("c".utf8), for: "keychain:orphaned-from-previous-dashboard")
        try await runtime.install(grant: status, binding: ConnectionAuthBinding(authRef: status.authRef, placement: .bearer))
        try await runtime.install(grant: events, binding: ConnectionAuthBinding(authRef: events.authRef, placement: .none))

        try await runtime.clearCredentials()
        XCTAssertNil(try store.secret(for: status.authRef))
        XCTAssertNil(try store.secret(for: events.authRef))
        XCTAssertNil(try store.secret(for: "keychain:orphaned-from-previous-dashboard"), "unlink wipes every stored secret, not only installed grants")

        try await runtime.clearCredentials()
        XCTAssertNil(try store.secret(for: status.authRef))
    }

    func testReinstallAfterUnlinkRequiresAFreshGrantAndSecret() async throws {
        let store = MemoryCredentialStore()
        let http = ScriptedHTTPTransport(fallback: .success(HTTPTransportResponse(status: 200, body: Data("{}".utf8))))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try statusGrant()
        try store.put(Data("old".utf8), for: grant.authRef)
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))
        try await runtime.clearCredentials()

        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))
        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("a re-installed grant without a re-approved secret must not send")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        XCTAssertTrue(http.requests.isEmpty)

        try store.put(Data("new".utf8), for: grant.authRef)
        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new")
    }

    func testClearCredentialsClosesSocketsAndForgetsCachedReads() async throws {
        let store = MemoryCredentialStore()
        let fresh = Data(#"{"fixture":"SCREENPUNK_HTTP_FIXTURE_V1","temperatureC":21}"#.utf8)
        let hello = Data(#"{"fixture":"SCREENPUNK_WS_FIXTURE_V1","event":"hello"}"#.utf8)
        let http = ScriptedHTTPTransport(fallback: .success(HTTPTransportResponse(status: 200, body: fresh)))
        let sockets = TrackedWebSocketTransport(queued: [hello])
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: sockets,
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let status = try statusGrant()
        let events = try eventsGrant()
        try store.put(Data("fixture-token".utf8), for: status.authRef)
        try await runtime.install(grant: status, binding: ConnectionAuthBinding(authRef: status.authRef, placement: .bearer))
        try await runtime.install(grant: events, binding: ConnectionAuthBinding(authRef: events.authRef, placement: .none))

        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        let id = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        _ = try await runtime.receive(id: id)
        let cachedRead = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(cachedRead?.valueJSON, String(decoding: fresh, as: UTF8.self))
        let cachedEvent = await runtime.lastRead(alias: "events", operation: "listen", parameters: [:])
        XCTAssertEqual(cachedEvent?.valueJSON, String(decoding: hello, as: UTF8.self))
        XCTAssertEqual(sockets.sessions.count, 1)
        XCTAssertFalse(sockets.sessions[0].isClosed)

        try await runtime.clearCredentials()

        XCTAssertTrue(sockets.sessions[0].isClosed, "unlink closes every open subscription")
        let readAfter = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertNil(readAfter, "HTTP cache is deleted with the credentials")
        let eventAfter = await runtime.lastRead(alias: "events", operation: "listen", parameters: [:])
        XCTAssertNil(eventAfter, "WebSocket last-known state is deleted with the credentials")
        do {
            _ = try await runtime.receive(id: id)
            XCTFail("a subscription closed by unlink must not receive")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }

        try store.put(Data("re-approved".utf8), for: status.authRef)
        try await runtime.install(grant: status, binding: ConnectionAuthBinding(authRef: status.authRef, placement: .bearer))
        let beforeRefetch = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertNil(beforeRefetch, "re-pairing starts from an empty cache, not the previous owner's payload")
        let refetched = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertFalse(refetched.stale)
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer re-approved")
    }

    func testReadInFlightAcrossUnlinkIsDiscarded() async throws {
        let store = MemoryCredentialStore()
        let http = HeldHTTPTransport()
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: TrackedWebSocketTransport(queued: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try statusGrant()
        try store.put(Data("fixture-token".utf8), for: grant.authRef)
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))

        let inFlight = Task { try await runtime.request(alias: "status", operation: "getStatus", parameters: [:]) }
        await http.untilSending()
        try await runtime.clearCredentials()
        http.respond(HTTPTransportResponse(status: 200, body: Data(#"{"temperatureC":21}"#.utf8)))

        switch await inFlight.result {
        case .success:
            XCTFail("a response that lands after unlink must not be delivered")
        case .failure(let error):
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        let cached = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertNil(cached, "the late response is not cached")
    }

    func testSubscriptionMessageLandingAfterUnlinkIsDiscarded() async throws {
        let hello = Data(#"{"fixture":"SCREENPUNK_WS_FIXTURE_V1","event":"hello"}"#.utf8)
        let sockets = TrackedWebSocketTransport(queued: [])
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            http: ScriptedHTTPTransport(),
            webSocket: sockets,
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try eventsGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        let id = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        let session = sockets.sessions[0]

        let inFlight = Task { try await runtime.receive(id: id) }
        await session.untilReading()
        try await runtime.clearCredentials()
        XCTAssertTrue(session.isClosed)
        session.deliver(hello)

        switch await inFlight.result {
        case .success:
            XCTFail("a frame buffered before close must not be delivered after unlink")
        case .failure(let error):
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        let cached = await runtime.lastRead(alias: "events", operation: "listen", parameters: [:])
        XCTAssertNil(cached, "the late frame is not remembered as last-known state")
    }

    func testSocketOpeningAfterUnlinkIsClosedAndRefused() async throws {
        let sockets = TrackedWebSocketTransport(queued: [])
        sockets.holdConnect = true
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            http: ScriptedHTTPTransport(),
            webSocket: sockets,
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try eventsGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

        let inFlight = Task { try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:]) }
        await sockets.untilConnecting()
        try await runtime.clearCredentials()
        sockets.releaseConnect()

        switch await inFlight.result {
        case .success:
            XCTFail("a socket that finishes opening after unlink must not be registered")
        case .failure(let error):
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        XCTAssertEqual(sockets.sessions.count, 1)
        XCTAssertTrue(sockets.sessions[0].isClosed, "the late socket is closed immediately")
    }

    func testDashboardStoreClearForgetsStateAndCacheAndResetsTheBudget() throws {
        var store = DashboardStore(dashboardId: "dash")
        try store.set(key: "layout", json: #"{"page":2}"#)
        try store.rememberRead(cacheKey: "status", json: #"{"temperatureC":21}"#, fetchedAt: t0)
        XCTAssertGreaterThan(store.usedBytes, 0)

        store.clear()

        XCTAssertEqual(store.usedBytes, 0)
        XCTAssertNil(try store.get(key: "layout"))
        XCTAssertNil(store.cachedRead(cacheKey: "status"))
        XCTAssertEqual(store.dashboardId, "dash")
        try store.rememberRead(cacheKey: "status", json: "{}", fetchedAt: t0)
        XCTAssertEqual(store.cachedRead(cacheKey: "status")?.valueJSON, "{}", "the store is usable after clear")
    }

    func testMemoryStoreNeverDescribesSecrets() throws {
        let store = MemoryCredentialStore()
        try store.put(Data("do-not-print".utf8), for: "keychain:x")
        XCTAssertFalse(store.debugDescription.contains("do-not-print"))
        XCTAssertFalse(store.debugDescription.contains("keychain:x"))
        try store.delete("keychain:x")
        XCTAssertNil(try store.secret(for: "keychain:x"))
    }

    func testUnlinkChromeIsNativeSingleActionAndSurvivesContentDeath() {
        XCTAssertEqual(UnlinkGestureSpec.fingers, 2)
        XCTAssertEqual(UnlinkGestureSpec.holdSeconds, 5)
        XCTAssertEqual(UnlinkGestureSpec.actionCount, 1)
        XCTAssertEqual(UnlinkGestureSpec.actionTitle, "Unlink")
        XCTAssertTrue(UnlinkGestureSpec.worksOverTerminatedWebContent)
        XCTAssertTrue(UnlinkGestureSpec.voiceOverEquivalent)
        XCTAssertTrue(UnlinkGestureSpec.explanation.lowercased().contains("credentials"))
        XCTAssertTrue(ContentProcessFailure.unlinkGestureRemainsAvailable)
        XCTAssertTrue(ContentProcessFailure.recoveryReloadsActivePackage)
    }
}

/// Parks each `send` until the test releases it, so a response can land after unlink.
final class HeldHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<HTTPTransportResponse, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending = continuation
            let woken = waiters
            waiters.removeAll()
            lock.unlock()
            woken.forEach { $0.resume() }
        }
    }

    func untilSending() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pending != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func respond(_ response: HTTPTransportResponse) {
        lock.lock()
        let parked = pending
        pending = nil
        lock.unlock()
        parked?.resume(returning: response)
    }
}

/// Serves queued frames, then parks `receive` until the test delivers a frame.
/// `close()` is recorded but does not fail a parked read, modelling a frame
/// that was already buffered when the socket was closed.
final class TrackedWebSocketSession: WebSocketSession, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Data]
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeCount = 0

    init(queued: [Data]) {
        self.queued = queued
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closeCount > 0
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closeCount > 0 {
                lock.unlock()
                continuation.resume(throwing: ConnectionFailure.deviceOffline)
                return
            }
            if queued.isEmpty == false {
                let next = queued.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
                return
            }
            pendingRead = continuation
            let woken = readWaiters
            readWaiters.removeAll()
            lock.unlock()
            woken.forEach { $0.resume() }
        }
    }

    func send(_ data: Data) async throws {}

    func close() async {
        recordClose()
    }

    private func recordClose() {
        lock.lock()
        closeCount += 1
        lock.unlock()
    }

    func untilReading() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingRead != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            readWaiters.append(continuation)
            lock.unlock()
        }
    }

    func deliver(_ data: Data) {
        lock.lock()
        let parked = pendingRead
        pendingRead = nil
        lock.unlock()
        parked?.resume(returning: data)
    }
}

final class TrackedWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let queued: [Data]
    private var opened: [TrackedWebSocketSession] = []
    private var pendingConnect: CheckedContinuation<Void, Never>?
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var hold = false

    init(queued: [Data]) {
        self.queued = queued
    }

    var sessions: [TrackedWebSocketSession] {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    var holdConnect: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hold
        }
        set {
            lock.lock()
            hold = newValue
            lock.unlock()
        }
    }

    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        if holdConnect {
            await withCheckedContinuation { continuation in
                lock.lock()
                pendingConnect = continuation
                let woken = connectWaiters
                connectWaiters.removeAll()
                lock.unlock()
                woken.forEach { $0.resume() }
            }
        }
        return open()
    }

    private func open() -> TrackedWebSocketSession {
        let session = TrackedWebSocketSession(queued: queued)
        lock.lock()
        opened.append(session)
        lock.unlock()
        return session
    }

    func untilConnecting() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingConnect != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            connectWaiters.append(continuation)
            lock.unlock()
        }
    }

    func releaseConnect() {
        lock.lock()
        let parked = pendingConnect
        pendingConnect = nil
        lock.unlock()
        parked?.resume()
    }
}
