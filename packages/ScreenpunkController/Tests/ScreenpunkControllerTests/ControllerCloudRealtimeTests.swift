import XCTest
import Foundation
@testable import ScreenpunkController

private let subscriber = "11111111-1111-4111-8111-111111111111"
private let generation = "22222222-2222-4222-8222-222222222222"
private let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
private func fixtureSession(cursor: String = "1", seconds: Double = 3_600) -> ControllerCloudRealtimeSession {
    .init(firebase: .init(projectId: "test-project", databaseURL: URL(string: "https://test-project-default-rtdb.firebaseio.com")!,
                         apiKey: "fixture-key", appId: "fixture-app", messagingSenderId: "123"),
          customToken: "fixture-custom", firebaseUID: "spctl:\(subscriber):\(generation)", subscriberId: subscriber,
          generationId: generation, wakePath: "v1/controllers/\(subscriber)/wake", cursor: cursor,
          authorityExpiresAtMs: Int64(fixtureNow.addingTimeInterval(seconds).timeIntervalSince1970 * 1000))
}
private func idToken(_ session: ControllerCloudRealtimeSession, expires: Date, uid: String? = nil) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: ["sub": uid ?? session.firebaseUID, "aud": session.firebase.projectId,
        "iss": "https://securetoken.google.com/" + session.firebase.projectId, "exp": expires.timeIntervalSince1970])
    let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).fixture-signature"
}
private func hint(_ cursor: String, event: String = "put") -> Data {
    Data("event: \(event)\ndata: {\"path\":\"/\",\"data\":{\"schemaVersion\":1,\"cursor\":\"\(cursor)\",\"changedAtMs\":1800000000000}}\n\n".utf8)
}
private actor RealtimeSink {
    var cursors: [String] = [], reconnects = 0, refreshes = 0, terminals = 0
    func cursor(_ value: String) { cursors.append(value) }
    func reconnect() { reconnects += 1 }
    func refresh() { refreshes += 1 }
    func terminal() { terminals += 1 }
    func state() -> ([String], Int, Int, Int) { (cursors, reconnects, refreshes, terminals) }
}
private final class RealtimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = fixtureNow
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private actor RealtimeTransport: ControllerCloudRealtimeTransport {
    enum Stream: Sendable { case hold, data([Data], end: Bool), status(Int) }
    var streams: [Stream], authRequests: [URLRequest] = [], streamRequests: [URLRequest] = []
    var active = 0, maximumActive = 0
    let session: ControllerCloudRealtimeSession
    let clock: RealtimeClock
    let firstTTL: Double
    let wrongUID: Bool
    init(_ streams: [Stream] = [.hold], session: ControllerCloudRealtimeSession = fixtureSession(),
         clock: RealtimeClock = RealtimeClock(), firstTTL: Double = 3_600, wrongUID: Bool = false) {
        self.streams = streams; self.session = session; self.clock = clock; self.firstTTL = firstTTL; self.wrongUID = wrongUID
    }
    func request(_ request: URLRequest, maximumBytes: Int) async throws -> ControllerCloudRealtimeHTTPResponse {
        authRequests.append(request)
        let refresh = request.url!.host == "securetoken.googleapis.com"
        let ttl = refresh ? 3_600 : firstTTL
        let token = try idToken(session, expires: clock.now().addingTimeInterval(ttl), uid: wrongUID ? "installation-user" : nil)
        let body: [String: Any] = refresh ? ["id_token": token, "refresh_token": "fixture-refresh", "expires_in": String(Int(ttl)), "user_id": session.firebaseUID] :
            ["idToken": token, "refreshToken": "fixture-refresh", "expiresIn": String(Int(ttl))]
        return .init(status: 200, contentType: "application/json", data: try JSONSerialization.data(withJSONObject: body))
    }
    func stream(_ request: URLRequest, onOpen: @escaping @Sendable (ControllerCloudRealtimeHTTPResponse) async throws -> Void,
                onData: @escaping @Sendable (Data) async throws -> Void) async throws {
        streamRequests.append(request); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let plan = streams.isEmpty ? .hold : streams.removeFirst()
        if case .status(let status) = plan { try await onOpen(.init(status: status)); return }
        try await onOpen(.init(status: 200, contentType: "text/event-stream; charset=utf-8"))
        if case .data(let data, let end) = plan { for part in data { try await onData(part) }; if end { return } }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
    func counts() -> (Int, Int, Int, Int) { (authRequests.count, streamRequests.count, active, maximumActive) }
    func requests() -> ([URLRequest], [URLRequest]) { (authRequests, streamRequests) }
}

private actor RealtimeSleeps {
    var values: [Double] = []
    func record(_ seconds: Double) { values.append(seconds) }
    func snapshot() -> [Double] { values }
}
private final class RealtimeOversizeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 97, count: 65_537))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RealtimeStreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0, stops = 0
    func reset() { lock.lock(); opens = 0; stops = 0; lock.unlock() }
    func open() { lock.lock(); opens += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (opens, stops) }
}
private final class RealtimeLongLivedURLProtocol: URLProtocol, @unchecked Sendable {
    static let probe = RealtimeStreamProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "identitytoolkit.googleapis.com" {
            do {
                let token = try idToken(fixtureSession(), expires: fixtureNow.addingTimeInterval(3_600))
                let data = try JSONSerialization.data(withJSONObject: ["idToken":token,"refreshToken":"fixture-refresh","expiresIn":"3600"])
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!, cacheStoragePolicy:.notAllowed)
                client?.urlProtocol(self, didLoad:data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError:ControllerCloudRealtimeFailure.invalidResponse) }
        } else {
            Self.probe.open()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!, cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad:hint("2"))
            // Deliberately do not finish. A frame must reach its callback before EOF.
        }
    }
    override func stopLoading() { if request.url?.host != "identitytoolkit.googleapis.com" { Self.probe.stop() } }
}

private actor RealtimeSuspendedCallback {
    private var continuation: CheckedContinuation<Void,Never>?
    private(set) var entered = false, finished = false
    func suspendIgnoringCancellation() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func finish() { finished = true }
}
private struct RealtimeAdmissionScope: Equatable, Sendable {
    let epoch: UUID, workspace: UUID, generation: String
}
private actor RealtimeScopedDurableAdmission {
    private var active: RealtimeAdmissionScope?
    private var entries: [(RealtimeAdmissionScope,String)] = []
    private var terminals: [RealtimeAdmissionScope] = []
    func activate(_ scope: RealtimeAdmissionScope) { active = scope }
    // Models the native owner's synchronous context-check+durable-write admission:
    // the captured context is checked after the caller's await, with no await in this commit.
    func commit(_ value: String, scope: RealtimeAdmissionScope) throws {
        guard active == scope else { throw CancellationError() }
        entries.append((scope,value))
    }
    func terminal(scope: RealtimeAdmissionScope) { if active == scope { terminals.append(scope) } }
    func snapshot() -> ([(RealtimeAdmissionScope,String)],[RealtimeAdmissionScope]) { (entries,terminals) }
}

final class ControllerCloudRealtimeTests: XCTestCase {
    private func start(_ consumer: ControllerCloudRealtimeConsumer, _ sink: RealtimeSink,
                       session: ControllerCloudRealtimeSession = fixtureSession()) async throws {
        try await consumer.start(session, onCursor: { await sink.cursor($0) }, onReconnect: { await sink.reconnect() },
                                 onSessionRefreshRequired: { await sink.refresh() }, onTerminal: { await sink.terminal() })
    }
    private func eventually(_ predicate: @escaping () async -> Bool, attempts: Int = 200, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<attempts { if await predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Expected bounded synthetic transport condition", file: file, line: line)
    }
    func testIncrementalFramesAndMonotonicCursorHints() throws {
        var parser = ControllerCloudRealtimeSSEDecoder(), wake = ControllerCloudRealtimeWakeDecoder(cursor: "9223372036854775805")
        let data = hint("9223372036854775806") + hint("9223372036854775806") + hint("2") + hint("9223372036854775807")
        var observed: [String] = []
        for byte in data { for event in try parser.append(Data([byte])) { if let value = try wake.consume(event) { observed.append(value); wake.acknowledge(value) } } }
        XCTAssertEqual(observed, ["9223372036854775806", "9223372036854775807"])
        var unaccepted = ControllerCloudRealtimeWakeDecoder(cursor:"1"), unacceptedFrames = ControllerCloudRealtimeSSEDecoder()
        let repeated = try unacceptedFrames.append(hint("2"))[0]
        XCTAssertEqual(try unaccepted.consume(repeated),"2")
        XCTAssertEqual(try unaccepted.consume(repeated),"2","Observed hints are not acknowledged before durable enqueue")
        unaccepted.acknowledge("2"); XCTAssertNil(try unaccepted.consume(repeated))
        XCTAssertFalse(ControllerCloudRealtimeCursor.valid("9223372036854775808")); XCTAssertFalse(ControllerCloudRealtimeCursor.valid("01"))
        var invalid = ControllerCloudRealtimeSSEDecoder()
        XCTAssertThrowsError(try invalid.append(Data(repeating: 97, count: 4_097)))
        var frames = ControllerCloudRealtimeSSEDecoder()
        XCTAssertThrowsError(try frames.append(Data(String(repeating: ": comment\n", count: 1_000).utf8)))
        var scoped = ControllerCloudRealtimeWakeDecoder(cursor: "1")
        XCTAssertThrowsError(try scoped.consume(.init(name: "put", data: Data("{\"path\":\"/other\",\"data\":3}".utf8))))
        XCTAssertThrowsError(try scoped.consume(.init(name: "put", data: Data("{\"path\":\"/\",\"data\":{\"cursor\":42}}".utf8))))
    }
    func testIdleHasOneListenerNoPeriodicAPIRequestsAndStopCancels() async throws {
        let transport = RealtimeTransport([.data([Data("event: keep-alive\ndata: null\n\n".utf8)], end: false)])
        let sink = RealtimeSink(), consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { fixtureNow })
        try await start(consumer, sink)
        try await eventually { await sink.state().1 == 1 }
        try await Task.sleep(nanoseconds: 40_000_000)
        let before = await transport.counts(); XCTAssertEqual(before.0, 1); XCTAssertEqual(before.1, 1)
        await consumer.stop()
        let after = await transport.counts(); XCTAssertEqual(after.2, 0)
        let requests = await transport.requests(); XCTAssertEqual(requests.0[0].url?.host, "identitytoolkit.googleapis.com")
        XCTAssertEqual(requests.1[0].url?.path, "/v1/controllers/\(subscriber)/wake.json")
        XCTAssertEqual(requests.1[0].value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }
    func testReconnectCatchupDedupeAndOneLiveListener() async throws {
        let transport = RealtimeTransport([.data([hint("2")], end: true), .data([hint("2"), hint("3")], end: false)])
        let sink = RealtimeSink(), consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { fixtureNow }, sleep: { seconds in
            if seconds < 1 { await Task.yield() } else { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }, jitter: { 0 })
        try await start(consumer, sink)
        try await eventually { let s = await sink.state(); return s.0.last == "3" && s.1 == 2 }
        let cursors = await sink.state().0; XCTAssertEqual(Set(cursors).count, cursors.count); XCTAssertFalse(cursors.contains("1"))
        try await start(consumer, sink)
        try await eventually { await transport.counts().1 == 3 }
        await consumer.stop(); let counts = await transport.counts(); XCTAssertEqual(counts.3, 1); XCTAssertEqual(counts.2, 0)
    }
    func testAuthRevocationAndPermissionCancelDoNotRetryOrAuthorize() async throws {
        for (event, refresh) in [("auth_revoked", false), ("cancel", false)] {
            let transport = RealtimeTransport([.data([Data("event: \(event)\ndata: null\n\n".utf8)], end: false)])
            let sink = RealtimeSink(), consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { fixtureNow })
            try await start(consumer, sink)
            try await eventually { let s = await sink.state(); return refresh ? s.2 == 1 : s.3 == 1 }
            await consumer.stop(); let c = await transport.counts(); XCTAssertEqual(c.0, 1); XCTAssertEqual(c.1, 1)
        }
    }
    func testIDRenewalOnlyAtExpiryAndAuthorityExpiryRequestsNewSession() async throws {
        let clock = RealtimeClock(), transport = RealtimeTransport(clock: clock, firstTTL: 1)
        let sink = RealtimeSink(), consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { clock.now() }, sleep: { seconds in
            if seconds <= 1 { clock.advance(seconds); await Task.yield() } else { try await Task.sleep(nanoseconds: 60_000_000_000) }
        })
        try await start(consumer, sink)
        try await eventually({ await transport.counts().0 == 2 },attempts:600)
        await consumer.stop()
        let requests = await transport.requests(); XCTAssertEqual(requests.0[1].url?.host, "securetoken.googleapis.com")
        let session = fixtureSession(seconds: 1), expiryClock = RealtimeClock(), expired = RealtimeTransport(session: session, clock: expiryClock)
        let expirySink = RealtimeSink(), expiryConsumer = ControllerCloudRealtimeConsumer(transport: expired, now: { expiryClock.now() }, sleep: { seconds in expiryClock.advance(seconds); await Task.yield() })
        try await start(expiryConsumer, expirySink, session: session)
        try await eventually({ await expirySink.state().2 == 1 },attempts:600)
        await expiryConsumer.stop(); let expiryCounts = await expired.counts(); XCTAssertEqual(expiryCounts.0, 1)
    }
    func testMixedDeviceUIDAndWrongWakeScopeFailClosed() async throws {
        let transport = RealtimeTransport(wrongUID: true), sink = RealtimeSink()
        let consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { fixtureNow })
        try await start(consumer, sink); try await eventually { await sink.state().3 == 1 }
        let mixedCounts = await transport.counts(); XCTAssertEqual(mixedCounts.1, 0); await consumer.stop()
        let original = fixtureSession()
        let wrong = ControllerCloudRealtimeSession(firebase: original.firebase, customToken: original.customToken, firebaseUID: original.firebaseUID,
            subscriberId: original.subscriberId, generationId: original.generationId, wakePath: "v1/installations/\(subscriber)/wake", cursor: "1", authorityExpiresAtMs: original.authorityExpiresAtMs)
        do { try await start(consumer, sink, session: wrong); XCTFail("Wrong scope accepted") } catch { XCTAssertEqual(error as? ControllerCloudRealtimeFailure, .invalidSession) }
    }
    func testConcurrentStartsFenceOldListenersAndCallbacks() async throws {
        let transport = RealtimeTransport(), sink = RealtimeSink()
        let consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { fixtureNow })
        let first = Task { try await self.start(consumer, sink) }
        let second = Task { try await self.start(consumer, sink) }
        for task in [first, second] {
            do { try await task.value } catch { XCTAssertTrue(error is CancellationError) }
        }
        try await eventually { await transport.counts().2 == 1 }
        await consumer.stop(); let counts = await transport.counts()
        XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 1)
    }
    func testReconnectBackoffIsJitteredAndBoundedWithoutFeedPolling() async throws {
        let transport = RealtimeTransport(Array(repeating: .data([], end: true), count: 8) + [.hold])
        let sleeps = RealtimeSleeps(), sink = RealtimeSink()
        let consumer = ControllerCloudRealtimeConsumer(transport: transport, now: { fixtureNow }, sleep: { seconds in
            if seconds <= 30 { await sleeps.record(seconds); await Task.yield() }
            else { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }, jitter: { 1 })
        try await start(consumer, sink)
        try await eventually { await transport.counts().1 == 9 }
        await consumer.stop()
        let values = await sleeps.snapshot(), counts = await transport.counts()
        XCTAssertEqual(values, [1, 2, 4, 8, 16, 30, 30, 30]); XCTAssertEqual(counts.0, 1)
    }
    func testActualURLSessionAuthBodyIsBoundedAndIsolated() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RealtimeOversizeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization":"must-not-inherit"]
        let transport = ControllerCloudRealtimeURLSessionTransport(configuration: configuration)
        var request = URLRequest(url: URL(string:"https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fixture")!)
        request.httpMethod = "POST"
        do { _ = try await transport.request(request, maximumBytes:65_536); XCTFail("Oversize body accepted") }
        catch { XCTAssertEqual(error as? ControllerCloudRealtimeFailure, .frameLimit) }
    }
    func testLongLivedURLSessionDeliversBeforeEOFAndCancellationStopsIt() async throws {
        RealtimeLongLivedURLProtocol.probe.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RealtimeLongLivedURLProtocol.self]
        let transport = ControllerCloudRealtimeURLSessionTransport(configuration:configuration), sink = RealtimeSink()
        let consumer = ControllerCloudRealtimeConsumer(transport:transport,now:{fixtureNow})
        try await start(consumer,sink)
        try await eventually { await sink.state().0 == ["2"] }
        XCTAssertEqual(RealtimeLongLivedURLProtocol.probe.counts().0,1)
        XCTAssertEqual(RealtimeLongLivedURLProtocol.probe.counts().1,0)
        await consumer.stop()
        try await eventually { RealtimeLongLivedURLProtocol.probe.counts().1 == 1 }
        try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(RealtimeLongLivedURLProtocol.probe.counts().0,1)
    }
    func testRejectedDurableEnqueueStopsAndSameHintCanBeOfferedAfterExplicitRestart() async throws {
        for rejectReconnect in [false,true] {
            let transport = RealtimeTransport([.data([hint("2")],end:false),.data([hint("2")],end:false)])
            let sink = RealtimeSink(), consumer = ControllerCloudRealtimeConsumer(transport:transport,now:{fixtureNow})
            try await consumer.start(fixtureSession(),onCursor:{ value in
                await sink.cursor(value); throw ControllerCloudRealtimeFailure.invalidResponse
            },onReconnect:{
                await sink.reconnect(); if rejectReconnect { throw ControllerCloudRealtimeFailure.invalidResponse }
            },onSessionRefreshRequired:{await sink.refresh()},onTerminal:{await sink.terminal()})
            try await eventually { await sink.state().3 == 1 }
            try await eventually { await transport.counts().2 == 0 }
            let before=await transport.counts();XCTAssertEqual(before.0,1);XCTAssertEqual(before.1,1)
            if !rejectReconnect {
                let failed=await sink.state().0;XCTAssertEqual(failed,["2"])
                try await start(consumer,sink)
                try await eventually { await sink.state().0 == ["2","2"] }
            }
            await consumer.stop()
        }
    }
    func testPermanent403NeverStartsAutomaticSessionRetryTraffic() async throws {
        let transport=RealtimeTransport([.status(403),.status(403)]),sink=RealtimeSink()
        let consumer=ControllerCloudRealtimeConsumer(transport:transport,now:{fixtureNow})
        try await start(consumer,sink)
        try await eventually { await sink.state().3 == 1 }
        try await Task.sleep(nanoseconds:30_000_000)
        let counts=await transport.counts();XCTAssertEqual(counts.0,1);XCTAssertEqual(counts.1,1)
        let state=await sink.state();XCTAssertEqual(state.2,0)
        await consumer.stop()
    }
    func testSuspendedOldCallbacksCannotAdmitAfterScopeReplacement() async throws {
        for suspendReconnect in [false,true] {
            let first = fixtureSession(), nextGeneration = "33333333-3333-4333-8333-333333333333"
            let second = ControllerCloudRealtimeSession(firebase:first.firebase,customToken:"fixture-custom",firebaseUID:"spctl:\(subscriber):\(nextGeneration)",subscriberId:subscriber,generationId:nextGeneration,wakePath:first.wakePath,cursor:first.cursor,authorityExpiresAtMs:first.authorityExpiresAtMs)
            let transport = RealtimeTransport([.data([hint("2")],end:false)],session:first)
            let consumer = ControllerCloudRealtimeConsumer(transport:transport,now:{fixtureNow})
            let admission = RealtimeScopedDurableAdmission(), gate = RealtimeSuspendedCallback(), staleCallbacks = RealtimeSink()
            let oldScope=RealtimeAdmissionScope(epoch:UUID(),workspace:UUID(),generation:first.generationId)
            let newScope=RealtimeAdmissionScope(epoch:UUID(),workspace:UUID(),generation:second.generationId)
            await admission.activate(oldScope)
            try await consumer.start(first,onCursor:{ value in
                if !suspendReconnect { await gate.suspendIgnoringCancellation() }
                do { try await admission.commit(value,scope:oldScope) }
                catch { await gate.finish();throw error }
                if !suspendReconnect { await gate.finish() }
            },onReconnect:{
                if suspendReconnect { await gate.suspendIgnoringCancellation() }
                do { try await admission.commit("reconnect",scope:oldScope) }
                catch { await gate.finish();throw error }
                if suspendReconnect { await gate.finish() }
            },onSessionRefreshRequired:{await staleCallbacks.refresh()},onTerminal:{
                await staleCallbacks.terminal();await admission.terminal(scope:oldScope)
            })
            try await eventually { await gate.entered }
            // Consent/workspace/generation fence changes before transport cancellation is awaited.
            await admission.activate(newScope)
            await consumer.stop() // Must complete although the old callback ignores cancellation.
            let replacementTransport = RealtimeTransport([.data([hint("2")],end:false)],session:second)
            let replacement = ControllerCloudRealtimeConsumer(transport:replacementTransport,now:{fixtureNow})
            try await replacement.start(second,onCursor:{try await admission.commit($0,scope:newScope)},onReconnect:{
                try await admission.commit("reconnect",scope:newScope)
            },onSessionRefreshRequired:{},onTerminal:{await admission.terminal(scope:newScope)})
            try await eventually { await admission.snapshot().0.contains { $0.0 == newScope && $0.1 == "2" } }
            let before = await admission.snapshot()
            await gate.resume()
            try await eventually { await gate.finished }
            try await Task.sleep(nanoseconds:10_000_000)
            let after = await admission.snapshot(), stale = await staleCallbacks.state()
            XCTAssertEqual(after.0.count,before.0.count,"Resumed stale callback must not enqueue or acknowledge its cursor")
            XCTAssertEqual(after.1.count,0);XCTAssertEqual(stale.2,0);XCTAssertEqual(stale.3,0)
            XCTAssertEqual(after.0.filter{$0.0==oldScope && $0.1=="2"}.count,0)
            await replacement.stop(); await consumer.stop()
        }
    }
    func testRedirectPolicyNeverForwardsTokensAcrossOriginsOrPaths() {
        let url = URL(string: "https://test-project-default-rtdb.firebaseio.com/v1/controllers/\(subscriber)/wake.json?auth=fixture")!
        XCTAssertTrue(ControllerCloudRealtimeURLPolicy.redirected(url, from: url, status: 307))
        XCTAssertFalse(ControllerCloudRealtimeURLPolicy.redirected(url, from: url, status: 302))
        for target in ["https://other.firebaseio.com", "http://test-project-default-rtdb.firebaseio.com", "https://attacker.invalid"] {
            let other = URL(string: target + url.path + "?auth=fixture")!
            XCTAssertFalse(ControllerCloudRealtimeURLPolicy.redirected(other, from: url, status: 307))
        }
        XCTAssertFalse(ControllerCloudRealtimeURLPolicy.redirected(URL(string: url.absoluteString.replacingOccurrences(of: "wake.json", with: "other.json"))!, from: url, status: 307))
        XCTAssertFalse(ControllerCloudRealtimeURLPolicy.authEndpoint(URL(string: "https://identitytoolkit.googleapis.com.attacker.invalid/v1/accounts:signInWithCustomToken")!))
    }
}
