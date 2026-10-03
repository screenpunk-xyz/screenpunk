import XCTest
@testable import ScreenpunkCore

final class CloudNativeWorkspaceSetupTests: XCTestCase {
    private let operationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    // Exact fixture bytes: cloud commit eda8d5091d80a04c448e7a30ec0bb5a5248d97ef.
    private func fixtures() throws -> [[String: Any]] {
        let data = try RepoFixtures.data("packages/ScreenpunkCore/Tests/ScreenpunkCoreTests/Fixtures/native-workspace-setup-fixtures.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }
    private func fixture(_ name: String) throws -> Data {
        let item = try XCTUnwrap(try fixtures().first { $0["name"] as? String == name })
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(item["response"]))
    }
    private func api(_ transport: WorkspaceTransport, tokens: WorkspaceTokens = .init()) throws -> CloudNativeClient {
        try .init(baseURL: URL(string: "https://cloud.example")!, tokenProvider: tokens, transport: transport)
    }
    private func setup(workspace: String = "My workspace", location: String = "Home") throws -> CloudNativeWorkspaceSetupRequest {
        try .init(requestId: operationID, workspaceName: workspace, locationName: location)
    }

    func testReceiptTimestampBoundedWithoutFormatterOnLinuxAndApple() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("first-workspace-created")) as? [String: Any])
        let long = "2026-10-02T18:00:00." + String(repeating: "1", count: 220) + "Z"
        for timestamp in [long, "2026-10-02t18:00:00.123456z", "2000-02-29T00:00:00-00:00", "2026-10-02T19:00:00.123456+01:00"] {
            object["createdAt"] = timestamp
            let receipt = try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(receipt.createdAt, timestamp)
        }
        for timestamp in ["2026-10-02T18:00:00." + String(repeating: "1", count: 236) + "Z",
                          "2026-10-02T18:00:00." + String(repeating: "1", count: 4096) + "Z",
                          "2026-02-30T00:00:00Z", "1900-02-29T00:00:00Z", "0000-01-01T00:00:00Z",
                          "2026-10-02T00:00:60Z", "2026-10-02T00:00:00+24:00", "2026-10-02T00:00:00+00:60",
                          "2026-10-02T00:00:00.１Z", "2026-10-02T00:00:00Z\n"] {
            object["createdAt"] = timestamp
            XCTAssertThrowsError(try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }
    func testAllEightAcceptedFixturesDecodeAndReceiptsRoundTrip() throws {
        let cases = try fixtures()
        XCTAssertEqual(cases.count, 8)
        var names = Set<String>()
        var receipts: [CloudNativeWorkspaceSetupReceipt] = []
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(item["response"]))
            if try XCTUnwrap(item["statusCode"] as? Int) == 200 {
                let receipt = try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: data)
                XCTAssertEqual(receipt.requestId, operationID)
                XCTAssertEqual(receipt.createdAt, "2026-10-02T18:00:00.123456Z")
                XCTAssertEqual(try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: JSONEncoder().encode(receipt)), receipt)
                receipts.append(receipt)
                if let body = item["body"] {
                    let request = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: JSONSerialization.data(withJSONObject: body))
                    XCTAssertEqual(request, try setup())
                }
            } else {
                let error = try JSONDecoder().decode(CloudNativeAPIError.self, from: data)
                XCTAssertEqual(error.requestId, "example-http-request-id")
                XCTAssertNotEqual(error.requestId, operationID.uuidString.lowercased(), "HTTP trace IDs never become setup operation IDs")
            }
            XCTAssertTrue(names.insert(name).inserted)
        }
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first, receipts.last, "A lookup returns the original four-field receipt")
    }

    func testSetupAndLookupRequestsUseFreshBearerAndExactBodyWithoutGenericIdempotency() async throws {
        let tokens = WorkspaceTokens()
        let transport = WorkspaceTransport([.init(status: 200, body: try fixture("first-workspace-created")),
                                             .init(status: 200, body: try fixture("recovered-committed-setup"))])
        let request = try setup(workspace: "  Cafe\u{301} 日本語  ", location: "\u{FEFF}Home\u{00A0}")
        let client = try api(transport, tokens: tokens)
        let created = try await client.setupWorkspace(request: request)
        let found = try await client.workspaceSetup(requestID: operationID)
        XCTAssertEqual(created, found)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].url.path, "/v1/native/workspace-setup")
        let sent = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(requests[0].body))
        XCTAssertEqual(Array(sent.workspaceName.utf8), Array(request.workspaceName.utf8))
        XCTAssertEqual(Array(sent.locationName.utf8), Array(request.locationName.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["requestId", "workspaceName", "locationName"])
        XCTAssertEqual(body["requestId"] as? String, operationID.uuidString.lowercased())
        XCTAssertEqual(requests[1].method, "GET")
        XCTAssertEqual(requests[1].url.path, "/v1/native/workspace-setup/11111111-1111-4111-8111-111111111111")
        XCTAssertNil(requests[1].body)
        for wire in requests {
            XCTAssertNil(wire.headers["Idempotency-Key"])
            XCTAssertNil(wire.headers["Cookie"])
            XCTAssertNil(wire.url.query)
            XCTAssertEqual(wire.headers["Cache-Control"], "no-store")
        }
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["Bearer setup-fixture-token-1", "Bearer setup-fixture-token-2"])
    }

    func testNamesCountUnicodeCodePointsAndPreserveExactValidText() throws {
        let valid = ["A", " 日本語 ", String(repeating: "😀", count: 128), String(repeating: "e\u{301}", count: 64),
                     "Family 👨‍👩‍👧‍👦", "\u{FEFF}A", "\u{200B}", "é", "e\u{301}"]
        for name in valid {
            let request = try setup(workspace: name, location: name)
            let restored = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(Array(restored.workspaceName.utf8), Array(name.utf8))
            XCTAssertEqual(Array(restored.locationName.utf8), Array(name.utf8))
        }
        let invalid = ["", " ", "\u{00A0}\u{2003}\u{3000}", "\u{FEFF}", "A\nB", "A\tB", "A\u{0}B", "A\u{7F}B", "A\u{85}B",
                       String(repeating: "😀", count: 129), String(repeating: "e\u{301}", count: 65)]
        for name in invalid {
            XCTAssertThrowsError(try setup(workspace: name)) { XCTAssertEqual($0 as? CloudNativeFailure, .invalidWorkspaceSetup) }
            XCTAssertThrowsError(try setup(location: name)) { XCTAssertEqual($0 as? CloudNativeFailure, .invalidWorkspaceSetup) }
        }
        XCTAssertNotEqual(try setup(workspace: "é"), try setup(workspace: "e\u{301}"), "Canonical Unicode equivalence is not setup request equivalence")
    }

    func testCorruptedPendingRequestAndReceiptDecodeFailClosed() throws {
        for json in [
            #"{"requestId":"not-a-uuid","workspaceName":"Workspace","locationName":"Home"}"#,
            #"{"requestId":"11111111-1111-4111-8111-111111111111","workspaceName":" ","locationName":"Home"}"#,
            #"{"requestId":"11111111-1111-4111-8111-111111111111","workspaceName":"\ud800","locationName":"Home"}"#,
            #"{"requestId":"11111111-1111-4111-8111-111111111111","workspaceName":"Workspace"}"#
        ] { XCTAssertThrowsError(try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: Data(json.utf8))) }
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("first-workspace-created")) as? [String: Any])
        for timestamp in ["2026-10-02T18:00:00.123456Z", "2026-10-02t18:00:00z", "2026-10-02T19:00:00+01:00"] {
            var sample = valid
            sample["createdAt"] = timestamp
            let receipt = try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: JSONSerialization.data(withJSONObject: sample))
            XCTAssertEqual(receipt.createdAt, timestamp, "Receipt validation never rewrites timestamp precision or representation")
        }
        for (field, replacement) in [("requestId", "bad"), ("accountId", "bad"), ("locationId", "bad"), ("createdAt", ""), ("createdAt", "not-a-time")] {
            var invalid = valid
            invalid[field] = replacement
            XCTAssertThrowsError(try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
    }

    func testReceiptMustMatchOperationIDForBothPostAndLookup() async throws {
        let response = try fixture("first-workspace-created")
        let other = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let transport = WorkspaceTransport([.init(status: 200, body: response), .init(status: 200, body: response)])
        let client = try api(transport)
        do { _ = try await client.setupWorkspace(request: .init(requestId: other, workspaceName: "Workspace", locationName: "Home")); XCTFail("Expected mismatched receipt") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .workspaceSetupReceiptMismatch) }
        do { _ = try await client.workspaceSetup(requestID: other); XCTFail("Expected mismatched lookup receipt") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .workspaceSetupReceiptMismatch) }
        let requests = await transport.requests
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests[0].body), as: UTF8.self).contains(other.uuidString.lowercased()))
        XCTAssertTrue(requests[1].url.path.hasSuffix(other.uuidString.lowercased()))
    }

    func testAllStructuredSetupErrorsPreservedWithoutAutomaticRetry() async throws {
        for item in try fixtures() where (item["statusCode"] as? Int ?? 0) >= 400 {
            let response = try JSONSerialization.data(withJSONObject: XCTUnwrap(item["response"]))
            let status = try XCTUnwrap(item["statusCode"] as? Int)
            let expected = try JSONDecoder().decode(CloudNativeAPIError.self, from: response)
            let transport = WorkspaceTransport([.init(status: status, body: response)])
            let client = try api(transport)
            do {
                if item["operationId"] as? String == "nativeGetWorkspaceSetup" { _ = try await client.workspaceSetup(requestID: operationID) }
                else { _ = try await client.setupWorkspace(request: setup()) }
                XCTFail("Expected structured error")
            } catch { XCTAssertEqual(error as? CloudNativeFailure, .api(status: status, error: expected)) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testMaximumValidNamesFitFourKiBAndUncertainFailuresNeverRetry() async throws {
        let transport = WorkspaceTransport([.init(status: 503, body: Data("unavailable".utf8))])
        let request = try setup(workspace: String(repeating: "😀", count: 128), location: String(repeating: "𐐀", count: 128))
        do { _ = try await api(transport).setupWorkspace(request: request); XCTFail("Expected server failure") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .http(status: 503)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(requests.first?.body).count, 4096)
        let malformed = WorkspaceTransport([.init(status: 200, body: Data("{}".utf8))])
        do { _ = try await api(malformed).setupWorkspace(request: request); XCTFail("Expected malformed success") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .invalidResponse) }
        let malformedRequests = await malformed.requests
        XCTAssertEqual(malformedRequests.count, 1)
    }

    func testIdentityInputAndUncertainTransportErrorsDoNotReplaceOperationOrRetry() async throws {
        for (status, code) in [(400, "invalid_workspace_setup"), (401, "invalid_identity")] {
            let response = try JSONSerialization.data(withJSONObject: ["code": code, "message": "Example failure", "requestId": "http-trace-only"])
            let transport = WorkspaceTransport([.init(status: status, body: response)])
            do { _ = try await api(transport).setupWorkspace(request: setup()); XCTFail("Expected structured error") }
            catch {
                guard let failure = error as? CloudNativeFailure, case let .api(actual, envelope) = failure else { XCTFail("Wrong error"); continue }
                XCTAssertEqual(actual, status)
                XCTAssertEqual(envelope.code, code)
                XCTAssertEqual(envelope.requestId, "http-trace-only")
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            let body = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(requests.first?.body))
            XCTAssertEqual(body.requestId, operationID)
        }
        for (code, expected) in [(URLError.Code.timedOut, CloudNativeFailure.transportUnavailable), (.cancelled, .cancelled)] {
            let transport = WorkspaceTransport(error: code)
            do { _ = try await api(transport).setupWorkspace(request: setup()); XCTFail("Expected transport failure") }
            catch { XCTAssertEqual(error as? CloudNativeFailure, expected) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }
}

private actor WorkspaceTokens: CloudNativeTokenProvider {
    private var calls = 0
    func idToken() async throws -> String { calls += 1; return "setup-fixture-token-\(calls)" }
}
private actor WorkspaceTransport: HTTPTransport {
    private var responses: [HTTPTransportResponse]
    private var failure: URLError.Code?
    private(set) var requests: [AuthorizedHTTPRequest] = []
    init(_ responses: [HTTPTransportResponse]) { self.responses = responses }
    init(error: URLError.Code) { responses = []; failure = error }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        if let failure { throw URLError(failure) }
        guard !responses.isEmpty else { throw CloudNativeFailure.transportUnavailable }
        return responses.removeFirst()
    }
}
