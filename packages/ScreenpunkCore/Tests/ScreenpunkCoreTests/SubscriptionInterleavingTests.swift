import XCTest
@testable import ScreenpunkCore

/// Force actor reentrancy at transport suspension points rather than relying on sleeps.
final class SubscriptionInterleavingTests: XCTestCase {
    func testOlderUnsubscribeCannotDeleteReplacement() async throws {
        let old = ReviewSocket(blockClose: true)
        let replacement = ReviewSocket()
        let transport = ReviewSocketTransport(sessions: [old, replacement])
        let runtime = try await makeRuntime(transport)
        let oldID = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        let close = Task { await runtime.unsubscribe(id: oldID) }
        await old.waitForClose()
        let newID = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        await old.finishClose()
        await close.value
        let received = try await runtime.receive(id: newID)
        XCTAssertEqual(received, Data("{}".utf8))
        await runtime.unsubscribe(id: newID)
    }

    func testOlderConnectCannotReplaceNewerSubscription() async throws {
        let old = ReviewSocket()
        let replacement = ReviewSocket()
        let transport = ReviewSocketTransport(sessions: [old, replacement], blockFirstConnect: true)
        let runtime = try await makeRuntime(transport)
        let first = Task { try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:]) }
        await transport.waitForFirstConnect()
        let newID = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        await transport.finishFirstConnect()
        do { _ = try await first.value; XCTFail("Replaced connect must be rejected") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        let wasClosed = await old.closed
        XCTAssertTrue(wasClosed)
        let received = try await runtime.receive(id: newID)
        XCTAssertEqual(received, Data("{}".utf8))
        await runtime.unsubscribe(id: newID)
    }

    func testNavigationConsumerCannotReplaceDashboardSubscription() async throws {
        let transport = ReviewSocketTransport(sessions: [ReviewSocket(), ReviewSocket()])
        let runtime = try await makeRuntime(transport)
        let page = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        let event = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:], consumer: "navigation")
        let pageData = try await runtime.receive(id: page)
        let eventData = try await runtime.receive(id: event)
        XCTAssertEqual(pageData, eventData)
        await runtime.unsubscribe(id: page)
        let remaining = try await runtime.receive(id: event)
        XCTAssertEqual(remaining, Data("{}".utf8))
        await runtime.unsubscribe(id: event)
    }

    private func makeRuntime(_ transport: ReviewSocketTransport) async throws -> ConnectionRuntime {
        let runtime = ConnectionRuntime(dashboardId: "review", store: MemoryCredentialStore(),
            http: MockHTTPTransport(response: .init(status: 200, body: Data())),
            webSocket: transport, resolver: FixedResolver(["127.0.0.1"]))
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "events",
            origin: "http://127.0.0.1:4173", transport: .ws, authRef: "review:events",
            lan: true, allowInsecureHTTP: true, operations: [.init(name: "listen", kind: .ws,
                method: .GET, path: "/events", idempotent: true, write: false)])
        try await runtime.install(grant: grant, binding: .init(authRef: grant.authRef, placement: .none))
        return runtime
    }
}

private actor ReviewSocket: WebSocketSession {
    private let blockClose: Bool
    private var closing = false
    private var closeStarted: CheckedContinuation<Void, Never>?
    private var closeRelease: CheckedContinuation<Void, Never>?
    private(set) var closed = false
    init(blockClose: Bool = false) { self.blockClose = blockClose }
    func receive() async throws -> Data { Data("{}".utf8) }
    func send(_ data: Data) async throws {}
    func close() async {
        closing = true
        closeStarted?.resume(); closeStarted = nil
        if blockClose { await withCheckedContinuation { closeRelease = $0 } }
        closed = true
    }
    func waitForClose() async {
        if !closing { await withCheckedContinuation { closeStarted = $0 } }
    }
    func finishClose() { closeRelease?.resume(); closeRelease = nil }
}

private actor ReviewSocketTransport: WebSocketTransport {
    private let sessions: [ReviewSocket]
    private let blockFirstConnect: Bool
    private var calls = 0
    private var firstStarted: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?
    init(sessions: [ReviewSocket], blockFirstConnect: Bool = false) {
        self.sessions = sessions; self.blockFirstConnect = blockFirstConnect
    }
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        let index = calls; calls += 1
        if index == 0 {
            firstStarted?.resume(); firstStarted = nil
            if blockFirstConnect { await withCheckedContinuation { firstRelease = $0 } }
        }
        return sessions[index]
    }
    func waitForFirstConnect() async {
        if calls == 0 { await withCheckedContinuation { firstStarted = $0 } }
    }
    func finishFirstConnect() { firstRelease?.resume(); firstRelease = nil }
}
