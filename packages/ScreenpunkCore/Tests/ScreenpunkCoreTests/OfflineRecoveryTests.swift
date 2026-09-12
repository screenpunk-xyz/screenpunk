import XCTest
@testable import ScreenpunkCore

/// TEST_PLAN "Offline, recovery": injected clock and scripted transports, no Mac involved.
final class OfflineRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let fresh = Data(#"{"fixture":"SCREENPUNK_HTTP_FIXTURE_V1","temperatureC":21}"#.utf8)
    private let later = Data(#"{"fixture":"SCREENPUNK_HTTP_FIXTURE_V1","temperatureC":19}"#.utf8)

    private func statusGrant() throws -> ConnectionGrant {
        try ConnectionGrantValidator.decode(RepoFixtures.data("schemas/fixtures/valid/connection-grant.json"))
    }

    private func eventsGrant() throws -> ConnectionGrant {
        try ConnectionGrantValidator.decode(RepoFixtures.data("schemas/fixtures/valid/connection-grant-ws.json"))
    }

    private func makeRuntime(
        http: ScriptedHTTPTransport,
        webSocket: any WebSocketTransport = MockWebSocketTransport(messages: []),
        clock: TestClock,
        store: MemoryCredentialStore = MemoryCredentialStore(),
        bounds: HTTPAdapterBounds = .production
    ) -> ConnectionRuntime {
        ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: webSocket,
            resolver: FixedResolver(["127.0.0.1"]),
            clock: clock,
            httpBounds: bounds
        )
    }

    func testFreshReadThenRequiredFailureServesRetainedData() async throws {
        let clock = TestClock(t0)
        let http = ScriptedHTTPTransport()
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: fresh)))
        let runtime = makeRuntime(http: http, clock: clock)
        let grant = try statusGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

        let first = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertFalse(first.stale)
        XCTAssertEqual(first.fetchedAt, t0)
        XCTAssertFalse(ConnectionPolicy.isStale(lastSuccess: first.fetchedAt, maxAgeSeconds: 45, now: t0))

        clock.now = t0.addingTimeInterval(60)
        http.enqueue(.failure(TransportDown()))
        let outage = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertTrue(outage.stale)
        XCTAssertEqual(outage.statusCode, 0)
        XCTAssertEqual(outage.body, fresh, "last good payload is retained")
        XCTAssertEqual(outage.fetchedAt, t0, "fetchedAt reflects the last success, not the failure")
        XCTAssertTrue(outage.diagnostic.contains("status=0"))
        XCTAssertTrue(ConnectionPolicy.isStale(lastSuccess: outage.fetchedAt, maxAgeSeconds: 45, now: clock.now))
        XCTAssertTrue(ConnectionHealth.overlayVisible(requiredFailedOrStale: true, connectionCount: 1))

        let cached = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(cached?.stale, true)
        XCTAssertEqual(cached?.valueJSON, String(decoding: fresh, as: UTF8.self))
        XCTAssertEqual(http.requests.count, 2)
    }

    func testRecoveryAfterOutageReturnsFreshDataAndClearsStaleFlag() async throws {
        let clock = TestClock(t0)
        let http = ScriptedHTTPTransport()
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: fresh)))
        http.enqueue(.failure(ConnectionFailure.deviceOffline))
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: later)))
        let runtime = makeRuntime(http: http, clock: clock)
        let grant = try statusGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        clock.now = t0.addingTimeInterval(120)
        let outage = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertTrue(outage.stale)

        clock.now = t0.addingTimeInterval(180)
        let recovered = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertFalse(recovered.stale)
        XCTAssertEqual(recovered.body, later)
        XCTAssertEqual(recovered.fetchedAt, clock.now)
        let cached = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(cached?.stale, false)
        XCTAssertEqual(cached?.fetchedAt, clock.now)
        XCTAssertFalse(ConnectionPolicy.isStale(lastSuccess: recovered.fetchedAt, maxAgeSeconds: 45, now: clock.now))
        XCTAssertFalse(ConnectionHealth.overlayVisible(requiredFailedOrStale: false, connectionCount: 1))
    }

    func testFailureWithNothingCachedSurfacesDeviceOffline() async throws {
        let clock = TestClock(t0)
        let http = ScriptedHTTPTransport()
        http.enqueue(.failure(TransportDown()))
        let runtime = makeRuntime(http: http, clock: clock)
        let grant = try statusGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("no cache means the failure must surface")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .deviceOffline)
        }
        let cached = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertNil(cached)
        XCTAssertTrue(ConnectionPolicy.isStale(lastSuccess: nil, maxAgeSeconds: 45, now: t0), "no data yet counts as stale")
    }

    func testTimeoutIsPropagatedWhenNothingIsCached() async throws {
        let clock = TestClock(t0)
        let http = ScriptedHTTPTransport()
        http.enqueue(.failure(ConnectionFailure.timeout))
        let runtime = makeRuntime(http: http, clock: clock)
        let grant = try statusGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("timeout must surface")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .timeout)
        }
    }

    func testRedirectAndOversizedUpstreamFallBackToRetainedData() async throws {
        let clock = TestClock(t0)
        let http = ScriptedHTTPTransport()
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: fresh)))
        http.enqueue(.success(HTTPTransportResponse(status: 302, body: Data())))
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: Data(repeating: 0x78, count: 200))))
        let runtime = makeRuntime(
            http: http,
            clock: clock,
            bounds: HTTPAdapterBounds(timeoutSeconds: 15, maxResponseBytes: 128)
        )
        let grant = try statusGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        let redirected = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertTrue(redirected.stale, "a redirect is treated as an upstream failure, never followed")
        XCTAssertEqual(redirected.body, fresh)
        let oversized = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertTrue(oversized.stale, "an oversized body never replaces the retained payload")
        XCTAssertEqual(oversized.body, fresh)

        let bare = makeRuntime(http: ScriptedHTTPTransport(fallback: .success(HTTPTransportResponse(status: 302, body: Data()))), clock: clock)
        try await bare.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        do {
            _ = try await bare.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("redirect with no cache must be denied")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .deniedEgress)
        }
    }

    func testAuthExpiryServesRetainedDataStaleAndSurfacesStatusWithoutLeakingTheSecret() async throws {
        let clock = TestClock(t0)
        let store = MemoryCredentialStore()
        let http = ScriptedHTTPTransport()
        let denied = Data(#"{"error":"unauthorized"}"#.utf8)
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: fresh)))
        http.enqueue(.success(HTTPTransportResponse(status: 401, body: denied)))
        http.enqueue(.success(HTTPTransportResponse(status: 200, body: later)))
        let runtime = makeRuntime(http: http, clock: clock, store: store)
        var grant = try statusGrant()
        grant.authRef = "keychain:fixture-status"
        try store.put(Data("expired-fixture-token".utf8), for: grant.authRef)
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))

        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        clock.now = t0.addingTimeInterval(60)
        let expired = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(expired.statusCode, 401, "the upstream status is surfaced")
        XCTAssertTrue(expired.stale, "auth expiry is a failed refresh, not fresh data")
        XCTAssertEqual(expired.body, fresh, "the 401 body never replaces the last good payload")
        XCTAssertNotEqual(expired.body, denied)
        XCTAssertEqual(expired.fetchedAt, t0)
        XCTAssertTrue(expired.diagnostic.contains("status=401"))
        XCTAssertFalse(expired.diagnostic.contains("expired-fixture-token"))
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer expired-fixture-token")
        XCTAssertFalse(http.requests.first?.url.absoluteString.contains("expired-fixture-token") ?? true)
        XCTAssertTrue(ConnectionHealth.overlayVisible(requiredFailedOrStale: true, connectionCount: 1))
        let cached = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(cached?.valueJSON, String(decoding: fresh, as: UTF8.self))
        XCTAssertEqual(cached?.stale, true)

        clock.now = t0.addingTimeInterval(120)
        let recovered = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(recovered.statusCode, 200)
        XCTAssertFalse(recovered.stale)
        XCTAssertEqual(recovered.body, later)
    }

    func testUpstreamErrorStatusesAreFailuresAndNeverCachedAsReads() async throws {
        for status in [400, 401, 403, 404, 429, 500, 502, 503] {
            let clock = TestClock(t0)
            let http = ScriptedHTTPTransport()
            let errorBody = Data("{\"error\":\(status)}".utf8)
            http.enqueue(.success(HTTPTransportResponse(status: status, body: errorBody)))
            let runtime = makeRuntime(http: http, clock: clock)
            let grant = try statusGrant()
            try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

            do {
                _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
                XCTFail("\(status) with nothing cached must surface as a failure")
            } catch {
                XCTAssertEqual(error as? ConnectionFailure, .deviceOffline, "status \(status)")
            }
            let nothing = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
            XCTAssertNil(nothing, "a \(status) body is never remembered as a read")

            http.enqueue(.success(HTTPTransportResponse(status: 200, body: fresh)))
            http.enqueue(.success(HTTPTransportResponse(status: status, body: errorBody)))
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            clock.now = t0.addingTimeInterval(60)
            let failed = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTAssertTrue(failed.stale, "status \(status) serves retained data stale")
            XCTAssertEqual(failed.statusCode, status)
            XCTAssertEqual(failed.body, fresh)
            XCTAssertEqual(failed.fetchedAt, t0)
            let retained = await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:])
            XCTAssertEqual(retained?.valueJSON, String(decoding: fresh, as: UTF8.self), "status \(status)")
            XCTAssertEqual(retained?.stale, true)
        }
    }

    func testStalenessFollowsInjectedClockAndOperationMaxAge() {
        XCTAssertFalse(ConnectionPolicy.isStale(lastSuccess: t0, maxAgeSeconds: 45, now: t0.addingTimeInterval(45)))
        XCTAssertTrue(ConnectionPolicy.isStale(lastSuccess: t0, maxAgeSeconds: 45, now: t0.addingTimeInterval(46)))
        let defaultMaxAge = RuntimeBounds.minPollSeconds * 2 + RuntimeBounds.httpTimeoutSeconds
        XCTAssertEqual(defaultMaxAge, 45)
        XCTAssertFalse(ConnectionPolicy.isStale(lastSuccess: t0, maxAgeSeconds: nil, now: t0.addingTimeInterval(Double(defaultMaxAge))))
        XCTAssertTrue(ConnectionPolicy.isStale(lastSuccess: t0, maxAgeSeconds: nil, now: t0.addingTimeInterval(Double(defaultMaxAge) + 1)))
        XCTAssertFalse(
            ConnectionPolicy.isStale(lastSuccess: t0, maxAgeSeconds: RuntimeBounds.weatherPollSeconds, now: t0.addingTimeInterval(600)),
            "a 15 minute weather poll is not stale after 10 minutes"
        )
    }

    func testOfflineOverlayNeedsARequiredFailureAndAtLeastOneConnection() {
        XCTAssertFalse(ConnectionRuntime.macIsRuntimeProxy, "Mac disappearance alone must never trigger Offline")
        XCTAssertFalse(ConnectionHealth.overlayVisible(requiredFailedOrStale: false, connectionCount: 2), "optional failure only")
        XCTAssertFalse(ConnectionHealth.overlayVisible(requiredFailedOrStale: true, connectionCount: 0), "no connections, no ring")
        XCTAssertTrue(ConnectionHealth.overlayVisible(requiredFailedOrStale: true, connectionCount: 1))
        XCTAssertFalse(OfflineOverlayLayout.interceptsTouches)
        XCTAssertFalse(OfflineOverlayLayout.blinks)
        XCTAssertFalse(OfflineOverlayLayout.hideableByDashboardCSS)
        XCTAssertEqual(OfflineOverlayLayout.label, "Offline")
    }

    func testWebSocketLossRetainsLastMessageAndResubscribeRecovers() async throws {
        let clock = TestClock(t0)
        let hello = Data(#"{"fixture":"SCREENPUNK_WS_FIXTURE_V1","event":"hello","stale":false}"#.utf8)
        let runtime = makeRuntime(
            http: ScriptedHTTPTransport(),
            webSocket: MockWebSocketTransport(messages: [hello]),
            clock: clock
        )
        let grant = try eventsGrant()
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))

        let id = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        let firstMessage = try await runtime.receive(id: id)
        XCTAssertEqual(firstMessage, hello)
        do {
            _ = try await runtime.receive(id: id)
            XCTFail("socket loss must surface")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .deviceOffline)
        }
        let retained = await runtime.lastRead(alias: "events", operation: "listen", parameters: [:])
        XCTAssertEqual(retained?.valueJSON, String(decoding: hello, as: UTF8.self))
        XCTAssertEqual(retained?.fetchedAt, t0)

        clock.now = t0.addingTimeInterval(100)
        XCTAssertTrue(ConnectionPolicy.isStale(lastSuccess: retained?.fetchedAt, maxAgeSeconds: nil, now: clock.now))

        let again = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        XCTAssertNotEqual(again, id, "re-subscribe opens a new session")
        let replayed = try await runtime.receive(id: again)
        XCTAssertEqual(replayed, hello)
        let recovered = await runtime.lastRead(alias: "events", operation: "listen", parameters: [:])
        XCTAssertEqual(recovered?.fetchedAt, clock.now)
        XCTAssertFalse(ConnectionPolicy.isStale(lastSuccess: recovered?.fetchedAt, maxAgeSeconds: nil, now: clock.now))
        await runtime.unsubscribe(id: again)
        do {
            _ = try await runtime.receive(id: again)
            XCTFail("unsubscribed ids must not receive")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
    }

    func testBackoffIsBoundedAndNonIdempotentWritesNeverRetry() {
        var previous = 0.0
        for attempt in 0...12 {
            let seconds = ConnectionPolicy.backoffSeconds(attempt: attempt, jitter: 1)
            XCTAssertLessThanOrEqual(seconds, Double(RuntimeBounds.backoffCapSeconds))
            XCTAssertGreaterThanOrEqual(seconds, previous)
            previous = seconds
        }
        XCTAssertEqual(ConnectionPolicy.backoffSeconds(attempt: 3, jitter: 0), 4)
        XCTAssertEqual(ConnectionPolicy.backoffSeconds(attempt: 3, jitter: 1), 8)
        XCTAssertEqual(ConnectionPolicy.backoffSeconds(attempt: 3, jitter: 5), 8, "jitter is clamped")
        XCTAssertEqual(ConnectionPolicy.backoffSeconds(attempt: -2, jitter: 1), 1)
        XCTAssertFalse(ConnectionPolicy.shouldRetry(write: true, idempotent: false))
        XCTAssertTrue(ConnectionPolicy.shouldRetry(write: true, idempotent: true))
        XCTAssertTrue(ConnectionPolicy.shouldRetry(write: false, idempotent: false))
    }

    func testStateAndCacheBudgetsFailClosedWithoutCorruptingExistingData() throws {
        var store = DashboardStore(dashboardId: "dash")
        try store.set(key: "keep", json: "1")
        let before = store.usedBytes
        let huge = String(repeating: "x", count: RuntimeBounds.stateCacheBytes)
        XCTAssertThrowsError(try store.set(key: "big", json: huge)) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues, [.sizeLimit])
        }
        XCTAssertEqual(store.usedBytes, before)
        XCTAssertEqual(try store.get(key: "keep"), "1")
        XCTAssertThrowsError(try store.rememberRead(cacheKey: "c", json: huge, fetchedAt: t0))
        XCTAssertNil(store.cachedRead(cacheKey: "c"))
        XCTAssertThrowsError(try store.set(key: "", json: "1"))
        XCTAssertThrowsError(try store.set(key: String(repeating: "k", count: 257), json: "1"))
        try store.remove(key: "keep")
        XCTAssertEqual(store.usedBytes, 0)
    }
}

struct TransportDown: Error {}

final class TestClock: PairingClock, @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class ScriptedHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<HTTPTransportResponse, Error>] = []
    private let fallback: Result<HTTPTransportResponse, Error>
    private(set) var requests: [AuthorizedHTTPRequest] = []

    init(fallback: Result<HTTPTransportResponse, Error> = .failure(ConnectionFailure.deviceOffline)) {
        self.fallback = fallback
    }

    func enqueue(_ result: Result<HTTPTransportResponse, Error>) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(result)
    }

    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        try record(request).get()
    }

    private func record(_ request: AuthorizedHTTPRequest) -> Result<HTTPTransportResponse, Error> {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return queue.isEmpty ? fallback : queue.removeFirst()
    }
}
