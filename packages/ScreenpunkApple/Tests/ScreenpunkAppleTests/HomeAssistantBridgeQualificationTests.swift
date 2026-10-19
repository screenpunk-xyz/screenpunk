import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkApple

/// No TV, Keychain, LAN, or identity operations. The additional verifier can only
/// add a check; it cannot replace Core qualification on a genuine managed runtime.
@MainActor final class HomeAssistantBridgeQualificationTests: XCTestCase {
    private func request(_ id: String, method: String = "connections.request", parameters: [String: String] = [:]) -> [String: Any] {
        ["protocolVersion": 1, "kind": "request", "id": id, "method": method,
         "alias": "googleTV", "operation": "status", "parameters": parameters]
    }
    private func fixture(clock: BridgeFixtureClock, gate: BridgeFixtureGate = .init(), connections: ConnectionRuntime? = nil,
        verify: @escaping @Sendable (Bool) throws -> Void,
        provider: @escaping @MainActor (String, String, [String: String]) async throws -> [String: Any],
        reply: @escaping ([String: Any]) -> Void,
        operationCompletion: ((String, Bool) -> Void)? = nil) throws -> (HomeAssistantWebBridge, URL, DeviceRuntimeLifetime) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-bridge-qualification-" + UUID().uuidString)
        let html = Data("<!doctype html><title>Provider fixture</title>".utf8)
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "provider-fixture", name: "Fixture", revision: "fixture",
            entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture", width: 390, height: 844, scale: 1, orientation: "portrait"),
            connections: [.init(alias: "googleTV", required: false)],
            files: [.init(path: "index.html", bytes: html.count, sha256: PeerPin.hex(PeerPin.sha256(html)))])
        let navigation = try DashboardEventRuntime(manifest: manifest, revision: "fixture", settings: .init(), homeAssistant: nil, connections: nil)
        let lifetime = DeviceRuntimeLifetime()
        let bridge = HomeAssistantWebBridge(runtime: nil, connections: connections, navigation: navigation, revision: "fixture", lifetime: lifetime,
            presentationAllowed: { gate.allows() }, preferenceStore: .init(root: root),
            calendarService: .init(store: MemoryCredentialStore(), suspension: GoogleCalendarSuspensionDomain()),
            additionalQualification: verify, timing: .init(sleep: { try await clock.sleep($0) }),
            fixtureGoogleTVRequest: provider, observeReply: reply, observeOperationCompletion: operationCompletion, onHealth: { _ in })
        return (bridge, root, lifetime)
    }
    private func clean(_ bridge: HomeAssistantWebBridge, _ root: URL, _ clock: BridgeFixtureClock) {
        bridge.suspendForReset(); clock.cancelAll(); try? FileManager.default.removeItem(at: root)
    }

    func testHeldQualificationLeavesMainActorResponsiveAndCancellationSettlesBeforeRelease() async throws {
        let entered = expectation(description: "worker entered full verification")
        let finished = expectation(description: "worker drained after explicit release")
        let held = BridgeFixtureVerifier(entered: entered, finished: finished), clock = BridgeFixtureClock()
        var providerCalls = 0, replies: [[String: Any]] = []
        let targetSettled = expectation(description: "cancelled request settled without verifier release")
        let (bridge, root, _) = try fixture(clock: clock, verify: { try held.verify($0) }, provider: { _, _, _ in
            providerCalls += 1; return ["connected": true]
        }, reply: { message in replies.append(message); if message["id"] as? String == "status" { targetSettled.fulfill() } })
        defer { held.release(); clean(bridge, root, clock) }
        bridge.handleValidatedBody(request("status"), id: "status")
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertFalse(held.ranOnMainThread)
        // This local navigation callback runs while the graph worker is held.
        // The old synchronous preflight cannot reach this line before its escape.
        var localBackHandled = false
        let localBack = expectation(description: "local Back callback remained schedulable")
        Task { @MainActor in localBackHandled = true; localBack.fulfill() }
        await fulfillment(of: [localBack], timeout: 1)
        XCTAssertTrue(localBackHandled); XCTAssertEqual(providerCalls, 0)
        bridge.handleValidatedBody(request("cancel", method: "connections.cancel", parameters: ["requestId": "status"]), id: "cancel")
        await fulfillment(of: [targetSettled], timeout: 1)
        XCTAssertEqual(replies.first { $0["id"] as? String == "status" }?["code"] as? String, "device_offline")
        XCTAssertEqual(held.calls, 1, "cancellation must not enter graph qualification")
        held.release(); await fulfillment(of: [finished], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(replies.filter { $0["id"] as? String == "status" }.count, 1)
        XCTAssertFalse(held.escaped)
    }

    func testQualificationDeadlineSettlesOnceAndLateSuccessCannotEnterProvider() async throws {
        let entered = expectation(description: "held verifier entered"), finished = expectation(description: "held verifier exited")
        let settled = expectation(description: "qualification timeout delivered")
        let held = BridgeFixtureVerifier(entered: entered, finished: finished), clock = BridgeFixtureClock()
        var calls = 0, replies: [[String: Any]] = []
        let (bridge, root, _) = try fixture(clock: clock, verify: { try held.verify($0) }, provider: { _, _, _ in
            calls += 1; return ["connected": true]
        }, reply: { replies.append($0); settled.fulfill() })
        defer { held.release(); clean(bridge, root, clock) }
        bridge.handleValidatedBody(request("deadline"), id: "deadline")
        await fulfillment(of: [entered], timeout: 3)
        clock.fire(8_000_000_000)
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertEqual(replies.first?["code"] as? String, "timeout"); XCTAssertEqual(calls, 0)
        held.release(); await fulfillment(of: [finished], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(replies.count, 1); XCTAssertEqual(calls, 0); XCTAssertFalse(held.escaped)
    }

    func testClosedGateDeniesBeforeVerifierAndNonterminalPauseSettlesHeldRequest() async throws {
        let entered = expectation(description: "open gate verifier entered"), finished = expectation(description: "paused worker drained")
        let held = BridgeFixtureVerifier(entered: entered, finished: finished), clock = BridgeFixtureClock(), gate = BridgeFixtureGate()
        let resumed = expectation(description: "fresh request succeeds after qualified host resume")
        var replies: [[String: Any]] = [], providers = 0
        let (bridge, root, _) = try fixture(clock: clock, gate: gate, verify: { try held.verify($0) }, provider: { _, _, _ in
            providers += 1; return ["connected": true]
        }, reply: { replies.append($0); if $0["id"] as? String == "resumed" { resumed.fulfill() } })
        defer { held.release(); clean(bridge, root, clock) }
        gate.set(false)
        bridge.handleValidatedBody(request("closed"), id: "closed")
        XCTAssertEqual(held.calls, 0); XCTAssertEqual(replies.first?["code"] as? String, "device_offline")
        gate.set(true); bridge.setActive(true)
        bridge.handleValidatedBody(request("paused"), id: "paused")
        await fulfillment(of: [entered], timeout: 3)
        gate.set(false); bridge.suspendPresentation(); gate.set(true)
        XCTAssertEqual(replies.filter { $0["id"] as? String == "paused" }.count, 1)
        XCTAssertEqual(replies.last?["code"] as? String, "device_offline")
        held.release(); await fulfillment(of: [finished], timeout: 3)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(providers, 0)
        XCTAssertFalse(bridge.isSuspendedForReset); XCTAssertFalse(held.escaped)
        bridge.setActive(true)
        bridge.handleValidatedBody(request("resumed"), id: "resumed")
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertEqual(providers, 1)
        XCTAssertEqual((replies.last?["value"] as? [String: Any])?["connected"] as? Bool, true)
    }

    func testTerminalRetirementSuppressesHeldCompletionAndCannotReactivate() async throws {
        let entered = expectation(description: "verifier entered"), finished = expectation(description: "retired verifier drained")
        let held = BridgeFixtureVerifier(entered: entered, finished: finished), clock = BridgeFixtureClock()
        var replies = 0, providers = 0
        let (bridge, root, lifetime) = try fixture(clock: clock, verify: { try held.verify($0) }, provider: { _, _, _ in
            providers += 1; return ["connected": true]
        }, reply: { _ in replies += 1 })
        defer { held.release(); clean(bridge, root, clock) }
        bridge.handleValidatedBody(request("old"), id: "old")
        await fulfillment(of: [entered], timeout: 3)
        lifetime.retire(); bridge.suspendForReset(); bridge.setActive(true)
        held.release(); await fulfillment(of: [finished], timeout: 3)
        bridge.handleValidatedBody(request("late"), id: "late")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(providers, 0); XCTAssertEqual(replies, 0); XCTAssertTrue(bridge.isSuspendedForReset)
        XCTAssertEqual(held.calls, 1); XCTAssertFalse(held.escaped)
    }

    func testUnconfiguredUnavailableDeniedAndConfiguredStatusAreBoundedFixtureResults() async throws {
        for outcome in ["unconfigured", "unavailable", "denied", "configured"] {
            let clock = BridgeFixtureClock(), settled = expectation(description: outcome)
            var replies: [[String: Any]] = [], calls = 0
            let (bridge, root, _) = try fixture(clock: clock, verify: { _ in
                if outcome == "denied" { throw ConnectionFailure.permissionRequired }
            }, provider: { dashboard, operation, parameters in
                calls += 1
                XCTAssertEqual(dashboard, "provider-fixture"); XCTAssertEqual(operation, "status"); XCTAssertTrue(parameters.isEmpty)
                switch outcome {
                case "unconfigured": throw GoogleTVError.message("Google TV permission required. Pair and approve this screen in native Google TV settings.")
                case "unavailable": throw GoogleTVError.message("Cannot reach the paired Google TV.")
                default: return ["connected": true, "streamerAwake": false]
                }
            }, reply: { replies.append($0); settled.fulfill() })
            bridge.handleValidatedBody(request(outcome), id: outcome)
            await fulfillment(of: [settled], timeout: 3)
            XCTAssertEqual(replies.count, 1)
            if outcome == "configured" {
                XCTAssertEqual((replies.first?["value"] as? [String: Any])?["connected"] as? Bool, true)
            } else {
                XCTAssertEqual(replies.first?["ok"] as? Bool, false)
                XCTAssertFalse((replies.first?["code"] as? String ?? "").isEmpty)
            }
            XCTAssertEqual(calls, outcome == "denied" ? 0 : 1)
            clean(bridge, root, clock)
        }
    }

    func testWholeRequestDeadlineCancelsProviderAndSuppressesLateReply() async throws {
        let clock = BridgeFixtureClock(), entered = expectation(description: "provider entered"), settled = expectation(description: "whole request timed out")
        let provider = BridgeFixtureProvider(entered: entered)
        var replies: [[String: Any]] = []
        let (bridge, root, _) = try fixture(clock: clock, verify: { _ in }, provider: { _, _, _ in
            await provider.result()
        }, reply: { replies.append($0); settled.fulfill() })
        defer { provider.release(); clean(bridge, root, clock) }
        bridge.handleValidatedBody(request("provider-deadline"), id: "provider-deadline")
        await fulfillment(of: [entered], timeout: 3)
        clock.fire(14_000_000_000)
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertEqual(replies.first?["code"] as? String, "timeout")
        provider.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(replies.count, 1)
    }

    func testResultRequalifiesOriginalAdmissionAndSuppressesConfiguredReceiptAfterRevocation() async throws {
        let clock = BridgeFixtureClock(), approval = BridgeFixtureGate(), settled = expectation(description: "revoked result denied")
        var calls = 0, replies: [[String: Any]] = []
        let (bridge, root, _) = try fixture(clock: clock, verify: { _ in
            guard approval.allows() else { throw ConnectionFailure.permissionRequired }
        }, provider: { _, _, _ in
            calls += 1; approval.set(false); return ["connected": true]
        }, reply: { replies.append($0); settled.fulfill() })
        defer { clean(bridge, root, clock) }
        bridge.handleValidatedBody(request("revoked"), id: "revoked")
        await fulfillment(of: [settled], timeout: 3)
        XCTAssertEqual(calls, 1); XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?["code"] as? String, "permission_required")
        XCTAssertNil(replies.first?["value"])
    }

    func testTimedOutVerifiersRetainBoundedWorkerSlotsUntilTheyActuallyDrain() async throws {
        let entered = expectation(description: "four bounded workers entered"), finished = expectation(description: "four owned workers drained")
        entered.expectedFulfillmentCount = 4; finished.expectedFulfillmentCount = 4
        let timedOut = expectation(description: "four requests timed out"), overflow = expectation(description: "new request rejected while workers drain")
        timedOut.expectedFulfillmentCount = 4
        let held = BridgeFixtureVerifier(entered: entered, finished: finished, allCalls: true), clock = BridgeFixtureClock()
        var providers = 0, overflowCode: String?
        let (bridge, root, _) = try fixture(clock: clock, verify: { try held.verify($0) }, provider: { _, _, _ in
            providers += 1; return ["connected": true]
        }, reply: {
            if $0["id"] as? String == "overflow" { overflowCode = $0["code"] as? String; overflow.fulfill() }
            else { timedOut.fulfill() }
        })
        defer { held.release(); clean(bridge, root, clock) }
        for index in 0..<4 { let id = "held-\(index)"; bridge.handleValidatedBody(request(id), id: id) }
        await fulfillment(of: [entered], timeout: 3)
        clock.fire(8_000_000_000)
        await fulfillment(of: [timedOut], timeout: 1)
        bridge.handleValidatedBody(request("overflow"), id: "overflow")
        await fulfillment(of: [overflow], timeout: 1)
        XCTAssertEqual(overflowCode, "size_limit"); XCTAssertEqual(held.calls, 4); XCTAssertEqual(providers, 0)
        held.release(); await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(held.escaped)
    }

    func testReusedIDOldUncooperativeCompletionCannotRemoveOrCancelReplacement() async throws {
        let oldEntered = expectation(description: "old provider entered"), oldCompleted = expectation(description: "old task cleanup ran after replacement registration")
        let secondEntered = expectation(description: "replacement pre-effect verifier entered"), secondDrained = expectation(description: "replacement verifier drained")
        let secondCompleted = expectation(description: "replacement task observed cancellation"), freshSettled = expectation(description: "later same ID request succeeds")
        let clock = BridgeFixtureClock(), oldProvider = BridgeFixtureProvider(entered: oldEntered)
        let held = BridgeFixtureVerifier(entered: secondEntered, finished: secondDrained), checks = BridgeFixtureCounter()
        var providerCalls = 0, completions = 0, removed: [Bool] = [], replies: [[String: Any]] = []
        let (bridge, root, _) = try fixture(clock: clock, verify: {
            if checks.next() == 4 { try held.verify($0) }
        }, provider: { _, _, _ in
            providerCalls += 1
            if providerCalls == 1 { return await oldProvider.result() }
            return ["connected": true]
        }, reply: {
            guard $0["id"] as? String == "reused" else { return }
            replies.append($0)
            if replies.count == 3 { freshSettled.fulfill() }
        }, operationCompletion: { id, didRemove in
            guard id == "reused" else { return }
            completions += 1; removed.append(didRemove)
            if completions == 1 { oldCompleted.fulfill() }
            if completions == 2 { secondCompleted.fulfill() }
        })
        defer { oldProvider.release(); held.release(); clean(bridge, root, clock) }
        bridge.handleValidatedBody(request("reused"), id: "reused")
        await fulfillment(of: [oldEntered], timeout: 3)
        bridge.handleValidatedBody(request("cancel-old", method: "connections.cancel", parameters: ["requestId": "reused"]), id: "cancel-old")
        XCTAssertEqual(replies.count, 1); XCTAssertEqual(replies[0]["code"] as? String, "device_offline")
        bridge.handleValidatedBody(request("reused"), id: "reused")
        await fulfillment(of: [secondEntered], timeout: 3)
        // Force A's late cleanup while B owns the very same string ID.
        oldProvider.release(); await fulfillment(of: [oldCompleted], timeout: 1)
        XCTAssertEqual(removed, [false], "old cleanup must not erase B's task handle")
        XCTAssertEqual(replies.count, 1, "old result must not consume B's reply eligibility")
        bridge.handleValidatedBody(request("cancel-new", method: "connections.cancel", parameters: ["requestId": "reused"]), id: "cancel-new")
        await fulfillment(of: [secondCompleted], timeout: 1)
        XCTAssertEqual(replies.count, 2); XCTAssertEqual(replies[1]["code"] as? String, "device_offline")
        held.release(); await fulfillment(of: [secondDrained], timeout: 3)
        XCTAssertEqual(providerCalls, 1, "B must not enter provider after its cancellation")
        bridge.handleValidatedBody(request("reused"), id: "reused")
        await fulfillment(of: [freshSettled], timeout: 3)
        XCTAssertEqual(providerCalls, 2); XCTAssertEqual(replies.count, 3)
        XCTAssertEqual((replies[2]["value"] as? [String: Any])?["connected"] as? Bool, true)
        XCTAssertFalse(held.escaped)
    }

    func testRepeatedSecondQualificationFailuresCleanRegistrationsAndRecoverCapacity() async throws {
        let clock = BridgeFixtureClock(), checks = BridgeFixtureCounter(), rejecting = BridgeFixtureGate()
        var providerCalls = 0, expectedID = "", replyWait: XCTestExpectation?, completionWait: XCTestExpectation?
        var lastReply: [String: Any]?, completed = false
        let (bridge, root, _) = try fixture(clock: clock, verify: { _ in
            let count = checks.next()
            if rejecting.allows(), count.isMultiple(of: 2) { throw ConnectionFailure.permissionRequired }
        }, provider: { _, _, _ in
            providerCalls += 1; return ["connected": true]
        }, reply: {
            guard $0["id"] as? String == expectedID else { return }
            lastReply = $0; replyWait?.fulfill()
        }, operationCompletion: { id, removed in
            guard id == expectedID else { return }
            completed = true; XCTAssertTrue(removed, "failed pre-effect check must release its own registry slot")
            completionWait?.fulfill()
        })
        defer { clean(bridge, root, clock) }
        // More than the 16-request bound, without a document-wide cancellation.
        for index in 0..<20 {
            expectedID = "second-check-\(index)"; completed = false; lastReply = nil
            let replied = expectation(description: expectedID + " denied"), cleaned = expectation(description: expectedID + " cleaned")
            replyWait = replied; completionWait = cleaned
            bridge.handleValidatedBody(request(expectedID), id: expectedID)
            await fulfillment(of: [replied, cleaned], timeout: 3)
            XCTAssertEqual(lastReply?["code"] as? String, "permission_required")
            guard completed else { return }
        }
        XCTAssertEqual(checks.count, 40); XCTAssertEqual(providerCalls, 0)
        rejecting.set(false); expectedID = "recovered"; completed = false
        let replied = expectation(description: "valid retry succeeded"), cleaned = expectation(description: "valid retry cleaned")
        replyWait = replied; completionWait = cleaned
        bridge.handleValidatedBody(request(expectedID), id: expectedID)
        await fulfillment(of: [replied, cleaned], timeout: 3)
        XCTAssertEqual(providerCalls, 1); XCTAssertTrue(completed)
        XCTAssertEqual((lastReply?["value"] as? [String: Any])?["connected"] as? Bool, true)
    }

    func testSubscriptionKeepsOperationIdentityAfterAcknowledgementUntilExactUnsubscribe() async throws {
        let acknowledged = expectation(description: "subscription acknowledged"), received = expectation(description: "event delivered after acknowledgement")
        let unsubscribed = expectation(description: "unsubscribe acknowledged"), completed = expectation(description: "subscription task drained")
        let clock = BridgeFixtureClock(), socket = BridgeFixtureSocket()
        let connection = ConnectionRuntime(dashboardId: "provider-fixture", store: MemoryCredentialStore(), http: BridgeFixtureNoHTTP(),
            webSocket: BridgeFixtureSocketTransport(socket: socket), resolver: FixedResolver(["93.184.216.34"]))
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "probe", origin: "https://example.com", transport: .ws,
            authRef: "probe", lan: false, allowInsecureHTTP: false, operations: [.init(name: "events", kind: .ws, method: .GET, path: "/events", idempotent: true, write: false)])
        try await connection.install(grant: grant, binding: .init(authRef: "probe", placement: .none))
        var frames: [[String: Any]] = []
        let (bridge, root, _) = try fixture(clock: clock, connections: connection, verify: { _ in }, provider: { _, _, _ in
            XCTFail("subscription must never use the TV fixture"); return [:]
        }, reply: {
            frames.append($0)
            if $0["id"] as? String == "sub", $0["kind"] as? String == "response" { acknowledged.fulfill() }
            if $0["id"] as? String == "sub", $0["kind"] as? String == "event" { received.fulfill() }
            if $0["id"] as? String == "unsubscribe" { unsubscribed.fulfill() }
        }, operationCompletion: { id, _ in if id == "sub" { completed.fulfill() } })
        defer { clean(bridge, root, clock); Task { try? await connection.clearCredentials(); await socket.close() } }
        var body = request("sub", method: "connections.subscribe")
        body["alias"] = "probe"; body["operation"] = "events"
        bridge.handleValidatedBody(body, id: "sub")
        await fulfillment(of: [acknowledged], timeout: 3)
        await socket.emit(Data("{\"value\":1}".utf8))
        await fulfillment(of: [received], timeout: 3)
        bridge.handleValidatedBody(request("unsubscribe", method: "connections.unsubscribe", parameters: ["subscriptionId": "sub"]), id: "unsubscribe")
        await fulfillment(of: [unsubscribed, completed], timeout: 3)
        await socket.emit(Data("{\"value\":2}".utf8))
        XCTAssertEqual(frames.filter { $0["id"] as? String == "sub" && $0["kind"] as? String == "response" }.count, 1)
        XCTAssertEqual(frames.filter { $0["id"] as? String == "sub" && $0["kind"] as? String == "event" }.count, 1)
        XCTAssertEqual(frames.filter { $0["id"] as? String == "sub" && $0["kind"] as? String == "error" }.count, 0)
        try await connection.clearCredentials(); await socket.close()
    }
}

private final class BridgeFixtureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class BridgeFixtureGate: @unchecked Sendable {
    private let lock = NSLock(); private var value = true
    func allows() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
}

private final class BridgeFixtureVerifier: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false, didEscape = false, onMain = false, count = 0
    private let entered: XCTestExpectation, finished: XCTestExpectation
    private let allCalls: Bool
    init(entered: XCTestExpectation, finished: XCTestExpectation, allCalls: Bool = false) { self.entered = entered; self.finished = finished; self.allCalls = allCalls }
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    var escaped: Bool { condition.lock(); defer { condition.unlock() }; return didEscape }
    var ranOnMainThread: Bool { condition.lock(); defer { condition.unlock() }; return onMain }
    func verify(_ active: Bool) throws {
        condition.lock(); count += 1; onMain = onMain || Thread.isMainThread
        let first = count == 1; condition.unlock()
        if first || allCalls { entered.fulfill() }
        condition.lock()
        let escape = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: escape) { didEscape = true; break }
        }
        let escaped = didEscape; condition.unlock()
        if first || allCalls { finished.fulfill() }
        if escaped { throw ConnectionFailure.timeout }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

/// Manually fired deadlines make timeout order deterministic; XCTest timeouts and
/// the verifier's independent escape keep a broken implementation from hanging.
private final class BridgeFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = Set<UInt64>(), cancelled = Set<UUID>()
    private var waiting: [UUID: (UInt64, CheckedContinuation<Void, Error>)] = [:]
    func sleep(_ value: UInt64) async throws {
        let token = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { register(token, value, $0) }
        }, onCancel: { self.cancel(token) })
    }
    private func register(_ token: UUID, _ value: UInt64, _ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled.remove(token) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        if fired.contains(value) { lock.unlock(); continuation.resume(); return }
        waiting[token] = (value, continuation); lock.unlock()
    }
    private func cancel(_ token: UUID) {
        lock.lock(); let waiter = waiting.removeValue(forKey: token); if waiter == nil { cancelled.insert(token) }; lock.unlock()
        waiter?.1.resume(throwing: CancellationError())
    }
    func fire(_ value: UInt64) {
        lock.lock(); fired.insert(value)
        let ready = waiting.filter { $0.value.0 == value }
        for token in ready.keys { waiting.removeValue(forKey: token) }
        lock.unlock(); ready.values.forEach { $0.1.resume() }
    }
    func cancelAll() {
        lock.lock(); let ready = waiting.values; waiting.removeAll(); lock.unlock()
        ready.forEach { $0.1.resume(throwing: CancellationError()) }
    }
}

@MainActor private final class BridgeFixtureProvider {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<[String: Any], Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func result() async -> [String: Any] {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume(returning: ["connected": true]) }
}

private struct BridgeFixtureNoHTTP: HTTPTransport {
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse { throw ConnectionFailure.permissionRequired }
}
private struct BridgeFixtureSocketTransport: WebSocketTransport {
    let socket: BridgeFixtureSocket
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession { socket }
}
private actor BridgeFixtureSocket: WebSocketSession {
    private var queued: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    func receive() async throws -> Data {
        if closed { throw ConnectionFailure.deviceOffline }
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func emit(_ bytes: Data) {
        guard !closed else { return }
        if let waiter = pending { pending = nil; waiter.resume(returning: bytes) }
        else { queued.append(bytes) }
    }
    func send(_ data: Data) async throws { }
    func close() {
        closed = true; queued.removeAll(); let waiter = pending; pending = nil
        waiter?.resume(throwing: ConnectionFailure.deviceOffline)
    }
}
