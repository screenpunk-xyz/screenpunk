import XCTest
@testable import ScreenpunkCore

final class CloudNativeClientTests: XCTestCase {
    // Exact fixture bytes from cloud commit 37c83d4560541e64c2dd5df8cd9bd085086d8b8c.
    private func fixtures() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "native-sign-in-fixtures", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }
    private func fixture(_ name: String) throws -> Data {
        let value = try XCTUnwrap(try fixtures().first { $0["name"] as? String == name })
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(value["response"]))
    }
    private func client(_ transport: NativeMockTransport, tokens: NativeMockTokens = .init()) throws -> CloudNativeClient {
        try .init(baseURL: URL(string: "https://cloud.example")!, tokenProvider: tokens, transport: transport)
    }

    func testAllFifteenAcceptedFixturesDecode() throws {
        let cases = try fixtures()
        XCTAssertEqual(cases.count, 15)
        var decoded = Set<String>()
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(item["response"]))
            let decoder = JSONDecoder()
            if try XCTUnwrap(item["statusCode"] as? Int) >= 400 {
                let value = try decoder.decode(CloudNativeAPIError.self, from: data)
                XCTAssertEqual(value.requestId, "example-request-id")
                XCTAssertFalse(value.code.isEmpty)
            } else {
                switch item["operationId"] as? String {
                case "nativeSignIn":
                    let value = try decoder.decode(CloudNativeSignInResponse.self, from: data)
                    XCTAssertEqual(value.authTime, "2026-10-02T16:00:00.000Z")
                    XCTAssertNil(value.user.email)
                case "nativeListAccounts":
                    let value = try decoder.decode(CloudNativePage<CloudNativeAccount>.self, from: data)
                    if name == "sparse-workspace-page" { XCTAssertTrue(value.items.isEmpty); XCTAssertNotNil(value.nextCursor) }
                    if name == "member-workspace" { XCTAssertFalse(try XCTUnwrap(value.items.first).capabilities.canEnroll) }
                case "nativeListLocations":
                    let value = try decoder.decode(CloudNativePage<CloudNativeLocation>.self, from: data)
                    XCTAssertTrue(value.items.allSatisfy { $0.capabilities.canView })
                default: XCTFail("Unknown accepted fixture operation")
                }
            }
            XCTAssertTrue(decoded.insert(name).inserted)
        }
    }

    func testFreshTokensHeadersAndExactSignInBodyWithoutCaching() async throws {
        let tokens = NativeMockTokens()
        let transport = NativeMockTransport([.init(status: 200, body: try fixture("sign-in-google")),
                                             .init(status: 200, body: try fixture("no-workspaces")),
                                             .init(status: 200, body: try fixture("no-workspaces"))])
        let api = try client(transport, tokens: tokens)
        let signIn = try await api.signIn()
        XCTAssertEqual(signIn.signInProvider, .google)
        let first = try await api.accounts()
        let second = try await api.accounts()
        XCTAssertTrue(first.items.isEmpty); XCTAssertTrue(second.items.isEmpty)
        let requests = await transport.requests
        let tokenCalls = await tokens.calls
        XCTAssertEqual(tokenCalls, 3)
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["Bearer fixture-id-token-1", "Bearer fixture-id-token-2", "Bearer fixture-id-token-3"])
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].body, Data("{}".utf8))
        XCTAssertEqual(requests[0].url.path, "/v1/native/sign-in")
        XCTAssertEqual(requests[1].url.path, "/v1/native/accounts")
        for request in requests {
            XCTAssertNil(request.headers["Cookie"])
            XCTAssertEqual(request.headers["Cache-Control"], "no-store")
            XCTAssertNil(request.url.query)
        }
    }

    func testSparsePaginationFollowsNonNullCursorAndRefreshesToken() async throws {
        let transport = NativeMockTransport([.init(status: 200, body: try fixture("sparse-workspace-page")),
                                             .init(status: 200, body: try fixture("owner-workspace"))])
        let api = try client(transport)
        let accounts = try await api.allAccounts(limit: 200)
        XCTAssertEqual(accounts.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "200")
        XCTAssertEqual(query?.first { $0.name == "cursor" }?.value,
                       try JSONDecoder().decode(CloudNativePage<CloudNativeAccount>.self, from: fixture("sparse-workspace-page")).nextCursor)
        XCTAssertNotEqual(requests[0].headers["Authorization"], requests[1].headers["Authorization"])
    }

    func testQueryEncodingAndAccountPathAreUnambiguous() async throws {
        let transport = NativeMockTransport([.init(status: 200, body: try fixture("no-visible-locations"))])
        let id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let cursor = "a+b /?&#=%日本語"
        _ = try await client(transport).locations(accountID: id, limit: 1, cursor: cursor)
        let recorded = await transport.requests
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.url.path, "/v1/native/accounts/22222222-2222-4222-8222-222222222222/locations")
        XCTAssertNil(request.url.fragment)
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value, cursor)
        XCTAssertTrue(request.url.absoluteString.contains("%2B"))
        XCTAssertFalse(request.url.absoluteString.contains("fixture-id-token"))
    }

    func testErrorCodesRemainDistinctAndNeverRetrySignIn() async throws {
        for name in ["sign-in-required", "recent-sign-in-required", "identity-unavailable", "workspace-unavailable"] {
            let status = name == "workspace-unavailable" ? 404 : 401
            let expected = try JSONDecoder().decode(CloudNativeAPIError.self, from: fixture(name))
            let transport = NativeMockTransport([.init(status: status, body: try fixture(name))])
            do { _ = try await client(transport).signIn(); XCTFail("Expected API failure") }
            catch { XCTAssertEqual(error as? CloudNativeFailure, .api(status: status, error: expected)) }
            let recorded = await transport.requests
            XCTAssertEqual(recorded.count, 1)
        }
        let transport = NativeMockTransport([.init(status: 503, body: Data("not-json".utf8))])
        do { _ = try await client(transport).accounts(); XCTFail("Expected HTTP failure") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .http(status: 503)) }
    }

    func testRedirectMalformedResponseAndResponseBoundsFailClosed() async throws {
        let cases: [(HTTPTransportResponse, CloudNativeFailure)] = [
            (.init(status: 302, body: Data(), headers: ["Location": "https://other.example"]), .redirectRejected),
            (.init(status: 200, body: Data("{\"items\":[]}".utf8)), .invalidResponse),
            (.init(status: 200, body: Data(repeating: 32, count: CloudNativeClient.maximumResponseBytes + 1)), .responseTooLarge)
        ]
        for (response, expected) in cases {
            let transport = NativeMockTransport([response])
            do { _ = try await client(transport).accounts(); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? CloudNativeFailure, expected) }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CloudNativeUser.self, from: Data("{\"id\":\"11111111-1111-4111-8111-111111111111\",\"displayName\":\"User\"}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(CloudNativeLocationCapabilities.self, from: Data("{\"canView\":false,\"canOperate\":true,\"canEnroll\":true}".utf8)))
    }

    func testPaginationCycleAndInvalidArgumentsStopWithoutInventingIdentifiers() async throws {
        let sparse = try fixture("sparse-workspace-page")
        let transport = NativeMockTransport([.init(status: 200, body: sparse), .init(status: 200, body: sparse)])
        do { _ = try await client(transport).allAccounts(); XCTFail("Expected cursor cycle") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .paginationCycle) }
        let empty = NativeMockTransport([])
        do { _ = try await client(empty).accounts(limit: 0); XCTFail("Expected invalid limit") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .invalidPagination) }
        do { _ = try await client(empty).accounts(cursor: ""); XCTFail("Expected invalid cursor") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .invalidPagination) }
        let emptyRequests = await empty.requests
        XCTAssertTrue(emptyRequests.isEmpty)
        for value in ["http://cloud.example", "https://person@cloud.example", "https://cloud.example/path", "https://cloud.example?token=secret", "https://cloud.example#fragment"] {
            XCTAssertThrowsError(try CloudNativeClient(baseURL: URL(string: value)!, tokenProvider: NativeMockTokens(), transport: empty))
        }
    }

    func testCancellationDoesNotCallTokenProviderOrTransport() async throws {
        let transport = NativeMockTransport([])
        let tokens = NativeMockTokens()
        let api = try client(transport, tokens: tokens)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.accounts()
        }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .cancelled) }
        let calls = await tokens.calls
        let requests = await transport.requests
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(requests.isEmpty)
    }

    func testTokenFailuresAndHeaderInjectionNeverReachTransport() async throws {
        for token in ["", "token\r\nCookie: browser=session", "token with whitespace"] {
            let transport = NativeMockTransport([])
            let api = try CloudNativeClient(baseURL: URL(string: "https://cloud.example")!,
                                            tokenProvider: NativeFixedTokens(value: token), transport: transport)
            do { _ = try await api.accounts(); XCTFail("Expected token failure") }
            catch { XCTAssertEqual(error as? CloudNativeFailure, .tokenUnavailable) }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
        let transport = NativeMockTransport([])
        let api = try CloudNativeClient(baseURL: URL(string: "https://cloud.example")!,
                                        tokenProvider: NativeFailingTokens(), transport: transport)
        do { _ = try await api.accounts(); XCTFail("Expected SDK token failure") }
        catch {
            XCTAssertEqual(error as? CloudNativeFailure, .tokenUnavailable)
            XCTAssertFalse(String(describing: error).contains("fixture-secret-diagnostic"))
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLocationPaginationContinuesAcrossEmptyPage() async throws {
        let transport = NativeMockTransport([.init(status: 200, body: Data("{\"items\":[],\"nextCursor\":\"next+location\"}".utf8)),
                                             .init(status: 200, body: try fixture("viewer-location"))])
        let locations = try await client(transport).allLocations(accountID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        XCTAssertEqual(locations.count, 1)
        XCTAssertFalse(try XCTUnwrap(locations.first).capabilities.canEnroll)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "next+location")
    }

    func testCancellationAfterTransportDoesNotReturnStaleSuccess() async throws {
        let api = try CloudNativeClient(baseURL: URL(string: "https://cloud.example")!, tokenProvider: NativeMockTokens(),
                                        transport: NativeSelfCancellingTransport())
        let work = Task { try await api.accounts() }
        do { _ = try await work.value; XCTFail("Expected cancelled response") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .cancelled) }
    }
}

private struct NativeFixedTokens: CloudNativeTokenProvider {
    let value: String
    func idToken() async throws -> String { value }
}
private struct NativeFailingTokens: CloudNativeTokenProvider {
    struct Failure: Error, CustomStringConvertible { var description: String { "fixture-secret-diagnostic" } }
    func idToken() async throws -> String { throw Failure() }
}
private struct NativeSelfCancellingTransport: HTTPTransport {
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        withUnsafeCurrentTask { $0?.cancel() }
        return .init(status: 200, body: Data("{\"items\":[],\"nextCursor\":null}".utf8))
    }
}

private actor NativeMockTokens: CloudNativeTokenProvider {
    private(set) var calls = 0
    func idToken() async throws -> String { calls += 1; return "fixture-id-token-\(calls)" }
}
private actor NativeMockTransport: HTTPTransport {
    private var responses: [HTTPTransportResponse]
    private(set) var requests: [AuthorizedHTTPRequest] = []
    init(_ responses: [HTTPTransportResponse]) { self.responses = responses }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw CloudNativeFailure.transportUnavailable }
        return responses.removeFirst()
    }
}
