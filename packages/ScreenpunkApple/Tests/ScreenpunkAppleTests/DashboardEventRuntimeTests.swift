import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor
final class DashboardEventRuntimeTests: XCTestCase {
    func testLiveSourceRejectsOldTransientAndBrightnessEditKeepsReturn() async throws {
        let socket = NavigationFixtureSocket(payloads: [
            ["time": Date().addingTimeInterval(-60).timeIntervalSince1970, "id": "old"],
            ["time": Date().addingTimeInterval(1).timeIntervalSince1970, "id": "fresh"]
        ])
        let connection = try await connection(socket: socket)
        let runtime = try DashboardEventRuntime(manifest: manifest(condition: false), revision: "rev", settings: .init(), homeAssistant: nil, connections: connection)
        var pages: [String] = []
        runtime.onPage = { pages.append($0.id) }
        runtime.start()
        defer { runtime.stop() }
        for _ in 0..<100 where runtime.status["activeRuleId"] == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(pages, ["door"])
        let deadline = runtime.status["returnAt"] as? String
        XCTAssertNotNil(deadline)
        runtime.update(settings: .init(brightness: .init(mode: .fixed, fixedLevel: 0.2)))
        XCTAssertEqual(runtime.status["returnAt"] as? String, deadline)
        XCTAssertTrue(runtime.open(pageId: "door"))
        XCTAssertNil(runtime.status["returnAt"])
    }

    func testLiveConditionUsesSeparateApprovedHTTPBaseline() async throws {
        let socket = NavigationFixtureSocket(payloads: [["active": true]])
        let connection = try await connection(socket: socket)
        let runtime = try DashboardEventRuntime(manifest: manifest(condition: true), revision: "rev", settings: .init(), homeAssistant: nil, connections: connection)
        runtime.start()
        defer { runtime.stop() }
        for _ in 0..<100 where runtime.page.id != "door" { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(runtime.page.id, "door")
        XCTAssertEqual(runtime.status["activeRuleId"] as? String, "ring")
    }

    func testClosedPresentationGatePreventsDynamicSubscriptionBeforeRedraw() async throws {
        let connected = expectation(description:"resumed subscription connected"), closed = expectation(description:"queued worker observed closed gate")
        let counter = NavigationConnectCounter(onConnect:{connected.fulfill()}), socket = NavigationFixtureSocket(payloads:[])
        let connection = ConnectionRuntime(dashboardId:"dash",store:MemoryCredentialStore(),http:NavigationFixtureHTTP(),webSocket:NavigationCountingTransport(socket:socket,counter:counter),resolver:FixedResolver(["93.184.216.34"]))
        let grant = ConnectionGrant(schemaVersion:1,id:UUID(),alias:"events",origin:"https://example.com",transport:.ws,authRef:"events",lan:false,allowInsecureHTTP:false,operations:[.init(name:"listen",kind:.ws,method:.GET,path:"/events",idempotent:true,write:false)])
        try await connection.install(grant:grant,binding:.init(authRef:"events",placement:.none))
        let gate = RendererPresentationTestGate(onFirstDenial:{closed.fulfill()})
        let runtime = try DashboardEventRuntime(manifest:manifest(condition:false),revision:"rev",settings:.init(),homeAssistant:nil,connections:connection,presentationAllowed:{gate.allows()})
        runtime.start()
        gate.set(false) // The worker was queued, but SwiftUI has not stopped it.
        await fulfillment(of:[closed],timeout:2)
        let closedCount = await counter.value(); XCTAssertEqual(closedCount,0); XCTAssertFalse(runtime.running)
        XCTAssertFalse(runtime.open(pageId:"door"))
        gate.set(true); runtime.start()
        await fulfillment(of:[connected],timeout:2)
        let resumedCount = await counter.value(); XCTAssertEqual(resumedCount,1)
        runtime.stop()
    }
    func testSynchronousLifetimeSuspensionRejectsQueuedWorkWithoutClosedGateObservation() async throws {
        let connected = expectation(description:"only resumed subscription connected")
        connected.assertForOverFulfill = true
        let counter = NavigationConnectCounter(onConnect:{connected.fulfill()}), socket = NavigationFixtureSocket(payloads:[])
        let connection = ConnectionRuntime(dashboardId:"dash",store:MemoryCredentialStore(),http:NavigationFixtureHTTP(),webSocket:NavigationCountingTransport(socket:socket,counter:counter),resolver:FixedResolver(["93.184.216.34"]))
        let grant = ConnectionGrant(schemaVersion:1,id:UUID(),alias:"events",origin:"https://example.com",transport:.ws,authRef:"events",lan:false,allowInsecureHTTP:false,operations:[.init(name:"listen",kind:.ws,method:.GET,path:"/events",idempotent:true,write:false)])
        try await connection.install(grant:grant,binding:.init(authRef:"events",placement:.none))
        let gate = RendererPresentationTestGate(), lifetime = DeviceRuntimeLifetime()
        let runtime = try DashboardEventRuntime(manifest:manifest(condition:false),revision:"rev",settings:.init(),homeAssistant:nil,connections:connection,presentationAllowed:{gate.allows()})
        let registration = lifetime.registerSuspension { runtime.stop() }
        defer { lifetime.unregisterSuspension(registration); runtime.stop() }
        runtime.start() // Queued worker has not received a MainActor turn yet.
        gate.set(false); lifetime.suspendPresentation(); gate.set(true)
        XCTAssertFalse(runtime.running)
        runtime.start()
        await fulfillment(of:[connected],timeout:2)
        let count = await counter.value(); XCTAssertEqual(count,1)
    }
    private func manifest(condition: Bool) -> DashboardManifest {
        .init(schemaVersion: 1, dashboardId: "dash", name: "House", revision: "rev", entrypoint: "index.html", sdkVersion: "1",
              target: .init(profileId: "phone", width: 390, height: 844, scale: 1, orientation: "portrait"),
              connections: [.init(alias: "events", required: true, operations: [.init(name: "listen", kind: "ws")]), .init(alias: "state", required: true, operations: [.init(name: "read", kind: "http")])],
              files: [.init(path: "index.html", bytes: 0, sha256: String(repeating: "0", count: 64)), .init(path: "door.html", bytes: 0, sha256: String(repeating: "0", count: 64))],
              pages: [.init(id: "home", name: "Home", path: "index.html"), .init(id: "door", name: "Door", path: "door.html")], defaultPageId: "home",
              eventRules: [.init(id: "ring", name: "Ring", source: .init(mode: .live, alias: "events", operation: "listen", refreshOperation: condition ? "read" : nil, refreshAlias: condition ? "state" : nil), condition: condition ? .init(field: ["active"], equals: .bool(true)) : nil, defaults: .init(pageId: "door", returnBehavior: .timeout), payload: .init(eventId: ["id"], occurredAt: ["time"]))])
    }
    private func connection(socket: NavigationFixtureSocket) async throws -> ConnectionRuntime {
        let runtime = ConnectionRuntime(dashboardId: "dash", store: MemoryCredentialStore(), http: NavigationFixtureHTTP(), webSocket: NavigationFixtureTransport(socket: socket), resolver: FixedResolver(["93.184.216.34"]))
        for (alias, transport, name) in [("events", ConnectionTransport.ws, "listen"), ("state", .http, "read")] {
            let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: alias, origin: "https://example.com", transport: transport, authRef: alias, lan: false, allowInsecureHTTP: false,
                operations: [.init(name: name, kind: transport, method: .GET, path: "/events", idempotent: true, write: false)])
            try await runtime.install(grant: grant, binding: .init(authRef: alias, placement: .none))
        }
        return runtime
    }
}
private struct NavigationFixtureHTTP: HTTPTransport {
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse { .init(status: 200, body: Data("{\"active\":false}".utf8)) }
}
private struct NavigationFixtureTransport: WebSocketTransport {
    let socket: NavigationFixtureSocket
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession { socket }
}
private actor NavigationFixtureSocket: WebSocketSession {
    var data: [Data]
    init(payloads: [[String: Any]]) { data = payloads.map { try! JSONSerialization.data(withJSONObject: $0) } }
    func receive() async throws -> Data {
        if !data.isEmpty { return data.removeFirst() }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw ConnectionFailure.deviceOffline
    }
    func send(_ data: Data) async throws {}
    func close() async {}
}

private actor NavigationConnectCounter {
    var count = 0
    let onConnect: @Sendable () -> Void
    init(onConnect:@escaping @Sendable () -> Void) { self.onConnect = onConnect }
    func record() { count += 1; onConnect() }
    func value() -> Int { count }
}
private struct NavigationCountingTransport: WebSocketTransport {
    let socket: NavigationFixtureSocket
    let counter: NavigationConnectCounter
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession { await counter.record(); return socket }
}
