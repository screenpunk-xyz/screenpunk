import XCTest
import Foundation
import CryptoKit
import ScreenpunkController
@testable import WorkbenchCommand

final class WorkbenchCloudSyncEventTests: XCTestCase {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var request: ControllerCloudScreenSyncRequest?
        var attempts = 0, acknowledgments = 0
        func snapshot() -> ControllerCloudScreenSyncRequest? { lock.lock(); defer { lock.unlock() }; return request }
        func set(_ value: ControllerCloudScreenSyncRequest?) { lock.lock(); request = value; lock.unlock() }
        func attempt() -> Int { lock.lock(); defer { lock.unlock() }; attempts += 1; return attempts }
        func ack(_ id: String) { lock.lock(); defer { lock.unlock() }; if request?.requestId == id { request = nil }; acknowledgments += 1 }
        func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (attempts, acknowledgments) }
    }
    private func request(_ id: String) throws -> ControllerCloudScreenSyncRequest {
        let value: [String: Any] = ["requestId": id, "trigger": "reconnected", "accountId": "synthetic", "clientId": "screenpunk-mac",
            "workspaceId": UUID().uuidString, "localWorkspaceId": UUID().uuidString, "epoch": "consent", "dashboardIds": [], "requiresFullCheck": false,
            "notBefore": Date().addingTimeInterval(-1).timeIntervalSinceReferenceDate]
        return try JSONDecoder().decode(ControllerCloudScreenSyncRequest.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testIdleDoesNotProcessAndFailedRequestParksUntilNewDurableEvent() async throws {
        let state = State()
        var continuation: AsyncStream<WorkbenchCloudSyncEventLoop.Wake>.Continuation!
        let events = AsyncStream<WorkbenchCloudSyncEventLoop.Wake> { continuation = $0 }
        let attempted = expectation(description: "first bounded attempt"), retried = expectation(description: "new event retry")
        let task = Task {
            await WorkbenchCloudSyncEventLoop.run(events: events, load: { state.snapshot() }, localChange: {}, process: { _ in
                let count = state.attempt()
                if count == 1 { attempted.fulfill(); return false }
                retried.fulfill(); return true
            }, acknowledge: { state.ack($0) })
        }
        // An idle listener has no timer, request, or remote work.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(state.counts().0, 0)
        state.set(try request("one")); continuation.yield(.request)
        await fulfillment(of: [attempted], timeout: 2)
        continuation.yield(.request) // Filesystem/status noise does not retry the same failed UUID.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(state.counts().0, 1); XCTAssertEqual(state.counts().1, 0)
        XCTAssertEqual(state.snapshot()?.requestId, "one")
        state.set(try request("two")); continuation.yield(.request)
        await fulfillment(of: [retried], timeout: 2)
        continuation.finish(); await task.value
        XCTAssertEqual(state.counts().0, 2); XCTAssertEqual(state.counts().1, 1)
        XCTAssertNil(state.snapshot())
    }
    func testConsentCancellationDoesNotKillServiceForNextExplicitEnable() async throws {
        let state = State(); state.set(try request("old-consent"))
        let replacement = try request("new-consent")
        var continuation: AsyncStream<WorkbenchCloudSyncEventLoop.Wake>.Continuation!
        let events = AsyncStream<WorkbenchCloudSyncEventLoop.Wake> { continuation = $0 }
        let done = expectation(description: "next consent event")
        let task = Task {
            await WorkbenchCloudSyncEventLoop.run(events: events, load: { state.snapshot() }, localChange: {}, process: { _ in
                if state.attempt() == 1 { state.set(replacement); throw CancellationError() }
                done.fulfill(); return true
            }, acknowledge: { state.ack($0) })
        }
        continuation.yield(.request); continuation.yield(.request)
        await fulfillment(of: [done], timeout: 2)
        continuation.finish(); await task.value
        XCTAssertEqual(state.counts().0, 2); XCTAssertEqual(state.counts().1, 1)
    }
    func testNewRequestDuringAwaitSurvivesOldAcknowledgement() async throws {
        let state = State(); state.set(try request("one"))
        let next = try request("two")
        var continuation: AsyncStream<WorkbenchCloudSyncEventLoop.Wake>.Continuation!
        let events = AsyncStream<WorkbenchCloudSyncEventLoop.Wake> { continuation = $0 }
        let done = expectation(description: "both requests")
        let task = Task {
            await WorkbenchCloudSyncEventLoop.run(events: events, load: { state.snapshot() }, localChange: {}, process: { _ in
                if state.attempt() == 1 { state.set(next); await Task.yield() } else { done.fulfill() }
                return true
            }, acknowledge: { state.ack($0) })
        }
        continuation.yield(.request); await fulfillment(of: [done], timeout: 2)
        continuation.finish(); await task.value
        XCTAssertEqual(state.counts().0, 2); XCTAssertEqual(state.counts().1, 2); XCTAssertNil(state.snapshot())
    }
}

private struct SyncCoordinatorDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root }
}
private struct SyncCoordinatorTokens: ControllerCloudTokenStore {
    func load() -> ControllerCloudTokens? { .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600)) }
    func save(_ tokens: ControllerCloudTokens?) {}
}
private final class SyncCoordinatorHTTP: URLProtocol {
    static var fixture: SyncCoordinatorHTTPState?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let value = try XCTUnwrap(Self.fixture).handle(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: value.1); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class SyncCoordinatorHTTPState: @unchecked Sendable {
    let workspace = "05f93b4e-7b95-40fa-bb3d-e1b2f59a6356"
    let subscriber = "65f30700-1b9e-4d8f-a7f0-17d32169e087"
    let firstLease: Double
    let feedEntered: XCTestExpectation
    let releaseFeed = DispatchSemaphore(value: 0)
    let releaseSession = DispatchSemaphore(value: 0)
    var replacementSessionEntered: XCTestExpectation?
    private let lock = NSLock()
    private var sessions = 0, feeds = 0
    private var controller: String?
    init(firstLease: Double, feedEntered: XCTestExpectation) { self.firstLease = firstLease; self.feedEntered = feedEntered }
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (sessions, feeds) }
    func handle(_ request: URLRequest) throws -> (Int, Data) {
        func response(_ value: Any) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        let path = request.url!.path
        if path == "/controller/v1/session" { return try response(["userId": "synthetic-account"]) }
        if path == "/controller/v1/workspaces" { return try response(["items": [["id": workspace, "name": "Synthetic", "membershipId": "synthetic", "role": "owner"]], "nextCursor": NSNull()]) }
        if path.hasSuffix("/connections") {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            }
            let id = try XCTUnwrap((JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["controllerId"] as? String)
            lock.lock(); controller = id; lock.unlock()
            return try response(["id": id])
        }
        if path.hasSuffix("/realtime/session") {
            lock.lock(); sessions += 1; let count = sessions, id = controller; lock.unlock()
            XCTAssertEqual(path.split(separator: "/").dropLast(2).last.map(String.init), id)
            if count == 2, let entered = replacementSessionEntered { entered.fulfill(); _ = releaseSession.wait(timeout: .now() + 10) }
            let generation = UUID().uuidString.lowercased()
            return try response(["schemaVersion": 1, "transport": "firebase-rtdb", "firebase": ["projectId": "controller-test", "databaseURL": "https://controller-test-default-rtdb.firebaseio.com", "apiKey": "synthetic", "appId": "synthetic", "messagingSenderId": "synthetic"],
                "customToken": generation, "firebaseUID": "spctl:\(subscriber):\(generation)", "subscriberId": subscriber,
                "generationId": generation, "wakePath": "v1/controllers/\(subscriber)/wake", "cursor": "9001",
                "authorityExpiresAtMs": Int64(Date().addingTimeInterval(count == 1 ? firstLease : 3600).timeIntervalSince1970 * 1000)])
        }
        if path.hasSuffix("/changes") {
            lock.lock(); feeds += 1; let count = feeds, seeded = sessions > 0; lock.unlock()
            guard seeded else { return (403, Data("{}".utf8)) }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value, count == 1 ? "0" : "1")
            if count == 1 { feedEntered.fulfill(); _ = releaseFeed.wait(timeout: .now() + 10) }
            return try response(["schemaVersion": 1, "items": [], "nextCursor": "1", "highWaterCursor": "1", "hasMore": false, "resetRequired": false])
        }
        if path.hasSuffix("/projects") { return try response(["items": [], "nextCursor": NSNull()]) }
        throw ControllerCloudError.invalidResponse
    }
}
private actor SyncCoordinatorRealtime: ControllerCloudRealtimeTransport {
    private var active: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var auths = 0, opens = 0, maximumActive = 0
    let opened: @Sendable (Int) -> Void
    init(opened: @escaping @Sendable (Int) -> Void) { self.opened = opened }
    func request(_ request: URLRequest, maximumBytes: Int) async throws -> ControllerCloudRealtimeHTTPResponse {
        auths += 1
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let generation = body["token"] as! String
        let uid = "spctl:65f30700-1b9e-4d8f-a7f0-17d32169e087:\(generation)"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": uid, "aud": "controller-test", "iss": "https://securetoken.google.com/controller-test", "exp": Date().addingTimeInterval(3600).timeIntervalSince1970])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return .init(status: 200, contentType: "application/json", data: try JSONSerialization.data(withJSONObject: ["idToken": "e30.\(encoded).synthetic", "refreshToken": "synthetic-refresh", "expiresIn": "3600"]))
    }
    func stream(_ request: URLRequest, onOpen: @escaping @Sendable (ControllerCloudRealtimeHTTPResponse) async throws -> Void, onData: @escaping @Sendable (Data) async throws -> Void) async throws {
        let id = UUID(); opens += 1
        try await onOpen(.init(status: 200, contentType: "text/event-stream"))
        opened(opens)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { active[id] = continuation; maximumActive = max(maximumActive, active.count) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { active.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func terminate() { let held = active.values; active.removeAll(); for continuation in held { continuation.resume(throwing: ControllerCloudRealtimeFailure.permissionDenied) } }
    func counts() -> (Int, Int, Int, Int) { (auths, opens, active.count, maximumActive) }
}

extension WorkbenchCloudSyncEventTests {
    private func coordinatorFixture(lease: Double, feedEntered: XCTestExpectation, realtime: SyncCoordinatorRealtime,
                                    makeListener: (@Sendable () -> any WorkbenchCloudRealtimeListener)? = nil) async throws -> (URL, WorkbenchBrokerServer, WorkbenchBrokerClient, WorkbenchCloudSyncCoordinator, SyncCoordinatorHTTPState) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-csync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime)
        let machine = broker.runtimeDirectory.appendingPathComponent("machine"), home = root.appendingPathComponent("home")
        let workspace = try WorkspaceStore(documents: SyncCoordinatorDocuments(root: root), machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("workspace").path)
        let controller = try ControllerService.bootstrap(root: home, deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let server = WorkbenchBrokerServer(environment: broker, domain: WorkbenchBrokerDomain(controller: controller, workspace: workspace, mutationGate: {}))
        try server.start()
        let client = WorkbenchBrokerClient(environment: broker); try client.connect()
        let configuration = try ControllerCloudConfiguration(baseURL: URL(string: "https://cloud.test")!, authorizationURL: URL(string: "https://cloud.test/auth")!, tokenURL: URL(string: "https://cloud.test/token")!, clientID: "screenpunk-cli", redirectURI: "http://127.0.0.1:43871/callback")
        let http = SyncCoordinatorHTTPState(firstLease: lease, feedEntered: feedEntered); SyncCoordinatorHTTP.fixture = http
        let url = URLSessionConfiguration.ephemeral; url.protocolClasses = [SyncCoordinatorHTTP.self]
        let session = ControllerCloudSession(configuration: configuration, tokenStore: SyncCoordinatorTokens(), session: URLSession(configuration: url))
        let facade = try ControllerCloudWorkbench(configuration: configuration, client: client, machineRoot: machine, session: session)
        try await facade.selectWorkspace(http.workspace, creatingLocalWorkspaceAt: root.appendingPathComponent("workspace").path)
        try await facade.setScreenSyncEnabled(true)
        let namespace = SHA256.hash(data: Data(configuration.baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let source = try WorkbenchCloudSyncEventSource(root: machine.appendingPathComponent("cloud-controller/" + namespace))
        let coordinator = WorkbenchCloudSyncCoordinator(baseURL: configuration.baseURL, environment: [:], broker: broker, home: home, source: source,
            preparedConnection: (client, facade, "screenpunk-cli"), makeConsumer: makeListener ?? { ControllerCloudRealtimeConsumer(transport: realtime) })
        return (root, server, client, coordinator, http)
    }
    func testActualCoordinatorRetainsRenewalDuringCatchupPastAuthorityExpiry() async throws {
        let feed = expectation(description: "long catchup"), first = expectation(description: "first listener"), second = expectation(description: "replacement listener")
        let realtime = SyncCoordinatorRealtime { if $0 == 1 { first.fulfill() } else if $0 == 2 { second.fulfill() } }
        let (root, server, client, coordinator, http) = try await coordinatorFixture(lease: 1, feedEntered: feed, realtime: realtime)
        defer { client.close(); server.stop(); SyncCoordinatorHTTP.fixture = nil; try? FileManager.default.removeItem(at: root) }
        let base = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("runtime/machine")
        let request = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let task = Task { try await coordinator.process(request) }
        await fulfillment(of: [feed, first], timeout: 3)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        http.releaseFeed.signal()
        let firstResult = try await task.value
        XCTAssertFalse(firstResult, "expired catchup cannot acknowledge the only wake")
        let pending = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        XCTAssertNotEqual(pending.requestId, request.requestId)
        XCTAssertEqual(pending.trigger, .reconnected)
        let replacementResult = try await coordinator.process(pending)
        XCTAssertTrue(replacementResult)
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(http.counts().0, 2)
        let next = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let catchupResult = try await coordinator.process(next)
        XCTAssertTrue(catchupResult)
        XCTAssertEqual(http.counts().0, 2, "ordinary catch-up must not rotate the live generation")
        let counts = await realtime.counts(); XCTAssertEqual(counts.3, 1)
        await coordinator.stop()
        let stopped = await realtime.counts(); XCTAssertEqual(stopped.2, 0)
    }
    func testActualCoordinatorTerminalDuringCatchupParksWithoutAcknowledgementOrAuthLoop() async throws {
        let feed = expectation(description: "held catchup"), opened = expectation(description: "listener opened")
        let realtime = SyncCoordinatorRealtime { _ in opened.fulfill() }
        let (root, server, client, coordinator, http) = try await coordinatorFixture(lease: 3600, feedEntered: feed, realtime: realtime)
        defer { client.close(); server.stop(); SyncCoordinatorHTTP.fixture = nil; try? FileManager.default.removeItem(at: root) }
        let base = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("runtime/machine")
        let request = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let task = Task { try await coordinator.process(request) }
        await fulfillment(of: [feed, opened], timeout: 3)
        await realtime.terminate()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: machine.appendingPathComponent("cloud-sync-status.json").path) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: machine.appendingPathComponent("cloud-sync-status.json").path))
        http.releaseFeed.signal()
        let initialResult = try await task.value
        XCTAssertFalse(initialResult)
        let pending = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let retryResult = try await coordinator.process(pending)
        XCTAssertFalse(retryResult, "listener's own reconnect wake cannot cause a permanent-auth retry loop")
        XCTAssertEqual(http.counts().0, 1); XCTAssertEqual(http.counts().1, 1)
        let counts = await realtime.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        await coordinator.stop()
    }
}

/// Deliberately retains a callback after stop, matching the documented uncooperative-callback
/// boundary. The first two Coordinator tests above still use the real realtime consumer.
private actor RetainedCoordinatorListener: WorkbenchCloudRealtimeListener {
    private var onTerminal: (@Sendable () async -> Void)?
    private var onRefresh: (@Sendable () async -> Void)?
    private var active = false
    func start(_ session: ControllerCloudRealtimeSession, onCursor: @escaping @Sendable (String) async throws -> Void,
               onReconnect: @escaping @Sendable () async throws -> Void,
               onSessionRefreshRequired: @escaping @Sendable () async -> Void,
               onTerminal: @escaping @Sendable () async -> Void) async throws {
        self.onTerminal = onTerminal; onRefresh = onSessionRefreshRequired; active = true
        try await onReconnect()
    }
    func stop() { active = false }
    func requestRefresh() async { await onRefresh?() }
    func deliverRetainedTerminal() async { await onTerminal?() }
    func isActive() -> Bool { active }
}
private final class RetainedCoordinatorListeners: @unchecked Sendable {
    private let lock = NSLock(); private var listeners: [RetainedCoordinatorListener] = []
    func make() -> any WorkbenchCloudRealtimeListener {
        lock.lock(); defer { lock.unlock() }
        let listener = RetainedCoordinatorListener(); listeners.append(listener); return listener
    }
    func first() -> RetainedCoordinatorListener? { lock.lock(); defer { lock.unlock() }; return listeners.first }
}
extension WorkbenchCloudSyncEventTests {
    func testActualCoordinatorOldTerminalDuringHeldRotationCannotParkReplacement() async throws {
        let feed = expectation(description: "initial catchup"), rotation = expectation(description: "held replacement session")
        let bank = RetainedCoordinatorListeners(), realtime = SyncCoordinatorRealtime { _ in }
        let (root, server, client, coordinator, http) = try await coordinatorFixture(lease: 3600, feedEntered: feed, realtime: realtime, makeListener: { bank.make() })
        defer { client.close(); server.stop(); SyncCoordinatorHTTP.fixture = nil; try? FileManager.default.removeItem(at: root) }
        let base = URL(string: "https://cloud.test")!, machine = root.appendingPathComponent("runtime/machine")
        let original = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let first = Task { try await coordinator.process(original) }
        await fulfillment(of: [feed], timeout: 3); http.releaseFeed.signal()
        let initialResult = try await first.value; XCTAssertTrue(initialResult)
        let old = try XCTUnwrap(bank.first())
        http.replacementSessionEntered = rotation
        await old.requestRefresh()
        let renewal = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let second = Task { try await coordinator.process(renewal) }
        await fulfillment(of: [rotation], timeout: 3)
        let oldActive = await old.isActive(); XCTAssertFalse(oldActive, "old listener must stop before the awaited rotation")
        await old.deliverRetainedTerminal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: machine.appendingPathComponent("cloud-sync-status.json").path), "stale terminal cannot publish paused status")
        http.releaseSession.signal()
        let replacementResult = try await second.value; XCTAssertTrue(replacementResult)
        let pending = try XCTUnwrap(ControllerCloudWorkbench.pendingScreenSyncRequest(baseURL: base, machineRoot: machine))
        let caughtUp = try await coordinator.process(pending); XCTAssertTrue(caughtUp, "old terminal cannot leave the new generation parked")
        XCTAssertEqual(http.counts().0, 2); XCTAssertEqual(http.counts().1, 3)
        await coordinator.stop()
    }
}
