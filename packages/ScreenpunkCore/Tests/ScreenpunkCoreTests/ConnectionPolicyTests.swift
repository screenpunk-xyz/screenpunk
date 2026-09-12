import XCTest
@testable import ScreenpunkCore

final class ConnectionPolicyTests: XCTestCase {
    func testVectors() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("tests/adapters/vectors.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(root?["macIsRuntimeProxy"] as? Bool, false)
        XCTAssertEqual(root?["followsRedirects"] as? Bool, false)
        let cases = root?["cases"] as? [[String: Any]] ?? []
        XCTAssertFalse(cases.isEmpty)
        let decoder = JSONDecoder()
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let expect = item["expect"] as? String
            let operation = item["operation"] as? String ?? ""
            let parameters = item["parameters"] as? [String: String] ?? [:]
            let resolved = item["resolvedAddresses"] as? [String] ?? []
            let grantData = try JSONSerialization.data(withJSONObject: item["grant"] as Any)
            let grant = try decoder.decode(ConnectionGrant.self, from: grantData)
            let binding = ConnectionAuthBinding(authRef: grant.authRef, placement: .none)
            let decision = ConnectionPolicy.decide(
                grant: grant,
                operationName: operation,
                parameters: parameters,
                resolvedAddresses: resolved,
                binding: binding
            )
            XCTAssertEqual(decision.rawValue, expect, id)
        }
    }

    func testAuthOverrideAndRetry() {
        XCTAssertTrue(ConnectionAuthKeys.isOverride("Authorization"))
        XCTAssertTrue(ConnectionAuthKeys.isOverride("token"))
        XCTAssertFalse(ConnectionPolicy.shouldRetry(write: true, idempotent: false))
        XCTAssertTrue(ConnectionPolicy.shouldRetry(write: false, idempotent: true))
        XCTAssertLessThanOrEqual(ConnectionPolicy.backoffSeconds(attempt: 8, jitter: 1), 60)
    }

    func testRedactsQueryCredentials() throws {
        let url = URL(string: "https://example.test/v1?api_key=secret&q=1")!
        let redacted = ConnectionRedaction.redact(url: url)
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("redacted"))
        XCTAssertTrue(ConnectionRedaction.hostLabel(origin: "https://example.test", lan: false).hasPrefix("public:"))
    }

    func testRuntimeCachesReadsNotWrites() async throws {
        let grant = try ConnectionGrantValidator.decode(
            Data(contentsOf: repoRoot().appendingPathComponent("schemas/fixtures/valid/connection-grant.json"))
        )
        let store = MemoryCredentialStore()
        let http = MockHTTPTransport(response: HTTPTransportResponse(
            status: 200,
            body: Data(#"{"fixture":"SCREENPUNK_HTTP_FIXTURE_V1"}"#.utf8)
        ))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"])
        )
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        let first = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertFalse(first.stale)
        XCTAssertFalse(first.diagnostic.contains("Bearer"))
        XCTAssertNotNil(await runtime.lastRead(alias: "status", operation: "getStatus", parameters: [:]))

        let writeGrant = writeGrantFixture()
        try await runtime.install(
            grant: writeGrant,
            binding: ConnectionAuthBinding(authRef: writeGrant.authRef, placement: .none)
        )
        _ = try await runtime.request(alias: "writer", operation: "putValue", parameters: ["n": "1"])
        XCTAssertNil(await runtime.lastRead(alias: "writer", operation: "putValue", parameters: ["n": "1"]))
    }

    func testBearerComesFromStoreNotParameters() async throws {
        var grant = try ConnectionGrantValidator.decode(
            Data(contentsOf: repoRoot().appendingPathComponent("schemas/fixtures/valid/connection-grant.json"))
        )
        grant.authRef = "keychain:fixture-status"
        let store = MemoryCredentialStore()
        try store.put(Data("fixture-token".utf8), for: grant.authRef)
        let http = MockHTTPTransport(response: HTTPTransportResponse(status: 200, body: Data("{}".utf8)))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"])
        )
        try await runtime.install(
            grant: grant,
            binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer)
        )
        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(http.lastRequest?.headers["Authorization"], "Bearer fixture-token")
        XCTAssertFalse(http.lastRequest?.url.absoluteString.contains("fixture-token") == true)
    }

    func testDeniedGrantNeverTouchesTransport() async throws {
        let grant = try ConnectionGrantValidator.decode(
            Data(contentsOf: repoRoot().appendingPathComponent("schemas/fixtures/valid/connection-grant.json"))
        )
        let http = MockHTTPTransport(response: HTTPTransportResponse(status: 200, body: Data()))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["169.254.169.254"])
        )
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("metadata destination must be denied")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .deniedEgress)
        }
        XCTAssertNil(http.lastRequest)
    }

    func testSubscribeReceivesFixtureHello() async throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("schemas/fixtures/valid/connection-grant-ws.json"))
        let grant = try ConnectionGrantValidator.decode(data)
        let hello = Data(#"{"fixture":"SCREENPUNK_WS_FIXTURE_V1","event":"hello"}"#.utf8)
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: MemoryCredentialStore(),
            http: MockHTTPTransport(response: HTTPTransportResponse(status: 200, body: Data())),
            webSocket: MockWebSocketTransport(messages: [hello]),
            resolver: FixedResolver(["127.0.0.1"])
        )
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .none))
        let id = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
        let message = try await runtime.receive(id: id)
        XCTAssertTrue(String(decoding: message, as: UTF8.self).contains("SCREENPUNK_WS_FIXTURE_V1"))
        await runtime.unsubscribe(id: id)
    }

    private func writeGrantFixture() -> ConnectionGrant {
        ConnectionGrant(
            schemaVersion: 1,
            id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            alias: "writer",
            origin: "http://127.0.0.1:4173",
            transport: .http,
            authRef: "keychain:fixture-write",
            lan: true,
            allowInsecureHTTP: true,
            operations: [
                ConnectionOperation(
                    name: "putValue",
                    kind: .http,
                    method: .POST,
                    path: "/v1/write",
                    idempotent: false,
                    write: true
                )
            ]
        )
    }

    private func repoRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("schemas/connection-grant.schema.json").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: file)
    }
}

final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    var response: HTTPTransportResponse
    var lastRequest: AuthorizedHTTPRequest?
    var error: Error?

    init(response: HTTPTransportResponse) {
        self.response = response
    }

    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        lastRequest = request
        if let error { throw error }
        return response
    }
}

final class MockWebSocketSession: WebSocketSession, @unchecked Sendable {
    var messages: [Data]
    init(messages: [Data]) { self.messages = messages }
    func receive() async throws -> Data {
        if messages.isEmpty { throw ConnectionFailure.deviceOffline }
        return messages.removeFirst()
    }
    func send(_ data: Data) async throws {}
    func close() async {}
}

struct MockWebSocketTransport: WebSocketTransport {
    var messages: [Data]
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        MockWebSocketSession(messages: messages)
    }
}
