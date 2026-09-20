import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class HomeAssistantLiveTests: XCTestCase {
    private func config() -> HomeAssistantProvisioning {
        .init(dashboardId: "screen", connectionId: "ha", provisioningId: "grant", revision: "rev",
              origin: "https://home.example", token: "private-fixture-token")
    }

    func testNativeHandshakeSnapshotAndFreshEventsOnly() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(config(), owner: "owner")
        let socket = LiveFixtureSocket(messages: [
            ["type": "auth_required"], ["type": "auth_ok"],
            ["type": "result", "id": 1, "success": true],
            ["type": "event", "id": 1, "event": ["event_type": "state_changed", "data": ["entity_id": "door", "new_state": ["entity_id": "door", "state": "old"], "old_state": NSNull()]]],
            ["type": "result", "id": 2, "success": true, "result": [["entity_id": "binary_sensor.door", "state": "off"]]],
            ["type": "event", "id": 1, "event": ["event_type": "state_changed", "data": ["entity_id": "binary_sensor.door", "new_state": ["entity_id": "wrong.entity", "state": "on"], "old_state": NSNull()]]],
            ["type": "event", "id": 1, "event": ["event_type": "state_changed", "data": ["entity_id": "binary_sensor.door", "new_state": ["entity_id": "binary_sensor.door", "state": "on"], "old_state": NSNull()]]]
        ])
        let transport = LiveFixtureTransport(socket: socket)
        let runtime = HomeAssistantDeviceRuntime(vault: vault,
            scope: { .init(owner: "owner", revision: "rev", dashboardId: "screen") },
            resolver: FixedResolver(["203.0.113.10"]), webSocket: transport)
        let stream = try await runtime.subscribeStates(revision: "rev")
        var values: [HomeAssistantDeviceRuntime.StateUpdate] = []
        do { for try await value in stream { values.append(value) } } catch { }
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values[0].isSnapshot)
        XCTAssertFalse(values[1].isSnapshot)
        XCTAssertFalse(values.contains { String(decoding: $0.data, as: UTF8.self).contains("private-fixture-token") })
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url.absoluteString, "wss://home.example/api/websocket")
        XCTAssertEqual(requests.first?.headers, [:])
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0]["type"] as? String, "auth")
        XCTAssertEqual(sent[0]["access_token"] as? String, "private-fixture-token")
        XCTAssertEqual(sent[1]["event_type"] as? String, "state_changed")
        XCTAssertEqual(sent[2]["type"] as? String, "get_states")
    }

    func testSubscriptionCannotExpandFixedOperationOrScope() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(config(), owner: "owner")
        let runtime = HomeAssistantDeviceRuntime(vault: vault,
            scope: { .init(owner: "owner", revision: "rev", dashboardId: "screen") })
        for (revision, operation, parameters) in [("wrong", "stateChanged", [:]), ("rev", "arbitrary_event", [:]), ("rev", "stateChanged", ["token": "override"])] {
            do {
                _ = try await runtime.subscribeStates(revision: revision, operation: operation, parameters: parameters)
                XCTFail("Unexpected permission expansion")
            } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        }
        try vault.revoke()
        do { _ = try await runtime.subscribeStates(revision: "rev"); XCTFail("Revoked vault opened socket") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }

    func testAuthFailureDoesNotReturnCredentialsOrState() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(config(), owner: "owner")
        let socket = LiveFixtureSocket(messages: [["type": "auth_required"], ["type": "auth_invalid", "message": "private-fixture-token"]])
        let runtime = HomeAssistantDeviceRuntime(vault: vault,
            scope: { .init(owner: "owner", revision: "rev", dashboardId: "screen") },
            resolver: FixedResolver(["203.0.113.10"]), webSocket: LiveFixtureTransport(socket: socket))
        do {
            for try await _ in try await runtime.subscribeStates(revision: "rev") { XCTFail("Auth leaked a value") }
            XCTFail("Invalid auth should fail")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }
}

private actor LiveFixtureTransport: WebSocketTransport {
    var requests: [AuthorizedWebSocketRequest] = []
    let socket: LiveFixtureSocket
    init(socket: LiveFixtureSocket) { self.socket = socket }
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        requests.append(request); return socket
    }
}

private actor LiveFixtureSocket: WebSocketSession {
    var messages: [Data]
    var sent: [[String: Any]] = []
    var closed = false
    init(messages: [[String: Any]]) { self.messages = messages.map { try! JSONSerialization.data(withJSONObject: $0) } }
    func receive() async throws -> Data {
        guard !closed, !messages.isEmpty else { throw ConnectionFailure.deviceOffline }
        return messages.removeFirst()
    }
    func send(_ data: Data) async throws {
        sent.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }
    func close() async { closed = true }
}
