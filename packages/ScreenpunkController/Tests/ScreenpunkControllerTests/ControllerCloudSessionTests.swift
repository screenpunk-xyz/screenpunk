import XCTest
@testable import ScreenpunkController
#if os(macOS)
private final class CloudMemoryTokens: ControllerCloudTokenStore, @unchecked Sendable {
    private let lock = NSLock(); private var tokens: ControllerCloudTokens?
    func load() -> ControllerCloudTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ tokens: ControllerCloudTokens?) { lock.lock(); defer { lock.unlock() }; self.tokens = tokens }
}
/// Per-host handlers keep concurrent HTTP fixtures isolated. No real network or Keychain is used.
private final class CloudTokenHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]
    static func register(_ host: String, handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    static func unregister(_ host: String) {
        lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private actor CloudExchangeGate {
    private var pending: [String:CheckedContinuation<ControllerCloudTokens,Never>] = [:]
    private var started: [String:CheckedContinuation<Void,Never>] = [:]
    private var counts: [String:Int] = [:]
    func exchange(_ values: [String:String]) async -> ControllerCloudTokens {
        let key = values["code"] ?? values["refresh_token"] ?? "unknown"
        counts[key,default:0] += 1
        return await withCheckedContinuation { continuation in
            pending[key] = continuation; started.removeValue(forKey:key)?.resume()
        }
    }
    func waitFor(_ key: String) async {
        if pending[key] != nil { return }
        await withCheckedContinuation { started[key] = $0 }
    }
    func complete(_ key: String, access: String, refresh: String, expires: Date = Date().addingTimeInterval(1000)) {
        pending.removeValue(forKey:key)?.resume(returning:.init(accessToken:access,refreshToken:refresh,expiresAt:expires))
    }
    func count(_ key: String) -> Int { counts[key,default:0] }
}
final class ControllerCloudSessionTests: XCTestCase {
    private func configuration(tokenURL: URL = URL(string:"https://auth.screenpunk.test/token")!) throws -> ControllerCloudConfiguration {
        try .init(baseURL:URL(string:"https://cloud.screenpunk.test")!,authorizationURL:URL(string:"https://auth.screenpunk.test/authorize")!,tokenURL:tokenURL,clientID:"screenpunk-cli",redirectURI:"http://127.0.0.1:43871/callback")
    }
    func testAuthorizationUsesPKCEAndFreshState() async throws {
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:CloudMemoryTokens())
        let first = try await session.beginAuthorization(), second = try await session.beginAuthorization()
        XCTAssertNotEqual(first.state,second.state)
        let items = URLComponents(url:first.url,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(items.first {$0.name == "code_challenge_method"}?.value,"S256")
        XCTAssertEqual(items.first {$0.name == "code_challenge"}?.value?.count,43)
        XCTAssertNil(items.first {$0.name == "code_verifier"})
        XCTAssertEqual(Set((items.first {$0.name == "scope"}?.value ?? "").split(separator: " ")), Set(["openid", "offline_access", "screenpunk.read", "screenpunk.write", "screenpunk.workspaces"]))
        XCTAssertEqual(items.first {$0.name == "prompt"}?.value, "consent")
        XCTAssertEqual(items.first {$0.name == "resource"}?.value,"https://cloud.screenpunk.test/mcp")
    }
    private func httpFixture(status: Int = 200, inspect: @escaping (URLRequest, [String: String]) throws -> Void) throws -> (ControllerCloudSession, CloudMemoryTokens, URLSession, String) {
        let host = UUID().uuidString.lowercased() + ".screenpunk.test"
        let url = URL(string: "https://" + host + "/token")!
        CloudTokenHTTPProtocol.register(host) { request in
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            var encoded = URLComponents()
            encoded.percentEncodedQuery = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
            let items = encoded.queryItems ?? []
            XCTAssertEqual(Set(items.map(\.name)).count, items.count)
            let form = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(form["client_id"], "screenpunk-cli")
            XCTAssertEqual(form["resource"], "https://cloud.screenpunk.test/mcp")
            try inspect(request, form)
            return (status, Data(#"{"access_token":"fixture-access","refresh_token":"fixture-rotated","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudTokenHTTPProtocol.self]
        let transport = URLSession(configuration: configuration), store = CloudMemoryTokens()
        return (ControllerCloudSession(configuration: try self.configuration(tokenURL: url), tokenStore: store, session: transport), store, transport, host)
    }
    func testAuthorizationCodeHTTPFormIncludesResourceAndPKCE() async throws {
        let code = "fixture+code&with=reserved/value"
        let (session, store, transport, host) = try httpFixture { _, form in
            XCTAssertEqual(form["grant_type"], "authorization_code")
            XCTAssertEqual(form["code"], code)
            XCTAssertEqual(form["redirect_uri"], "http://127.0.0.1:43871/callback")
            XCTAssertEqual(form["code_verifier"]?.count, 43)
            XCTAssertNil(form["refresh_token"])
        }
        defer { transport.invalidateAndCancel(); CloudTokenHTTPProtocol.unregister(host) }
        let auth = try await session.beginAuthorization()
        var callback = URLComponents(string: "http://127.0.0.1:43871/callback")!
        callback.queryItems = [URLQueryItem(name: "state", value: auth.state), URLQueryItem(name: "code", value: code)]
        try await session.finishAuthorization(callback: callback.url!)
        XCTAssertEqual(store.load()?.accessToken, "fixture-access")
        XCTAssertEqual(store.load()?.refreshToken, "fixture-rotated")
    }
    func testRefreshHTTPFormIncludesResourceAndPersistsRotation() async throws {
        let (session, store, transport, host) = try httpFixture { _, form in
            XCTAssertEqual(form["grant_type"], "refresh_token")
            XCTAssertEqual(form["refresh_token"], "fixture+refresh&value=1")
            XCTAssertNil(form["code"]); XCTAssertNil(form["code_verifier"])
        }
        defer { transport.invalidateAndCancel(); CloudTokenHTTPProtocol.unregister(host) }
        store.save(.init(accessToken: "expired", refreshToken: "fixture+refresh&value=1", expiresAt: .distantPast))
        let access = try await session.accessToken()
        XCTAssertEqual(access, "fixture-access")
        XCTAssertEqual(store.load()?.refreshToken, "fixture-rotated")
    }
    func testRejectedHTTPTokenExchangeDoesNotPersistCredentials() async throws {
        let (session, store, transport, host) = try httpFixture(status: 400) { _, _ in }
        defer { transport.invalidateAndCancel(); CloudTokenHTTPProtocol.unregister(host) }
        let auth = try await session.beginAuthorization()
        do {
            try await session.finishAuthorization(callback: URL(string: "http://127.0.0.1:43871/callback?state=\(auth.state)&code=fixture-rejected")!)
            XCTFail("Rejected token exchange completed sign-in")
        } catch { XCTAssertEqual(error as? ControllerCloudError, .http(400)) }
        XCTAssertNil(store.load())
    }
    func testTamperedCallbackNeverExchangesOrPersistsTokens() async throws {
        let store = CloudMemoryTokens(); let session = ControllerCloudSession(configuration:try configuration(),tokenStore:store)
        let auth = try await session.beginAuthorization()
        for callback in ["http://127.0.0.1:43871/callback?state=wrong&code=x", "http://localhost:43871/callback?state=\(auth.state)&code=x", "http://127.0.0.1:43871/callback?state=\(auth.state)&state=\(auth.state)&code=x"] {
            do { try await session.finishAuthorization(callback:URL(string:callback)!); XCTFail("invalid callback accepted") } catch { XCTAssertEqual(error as? ControllerCloudError,.invalidCallback) }
        }
        XCTAssertNil(store.load())
    }
    func testSignOutInvalidatesEveryRefreshWaiterEvenIfExchangeIgnoresCancellation() async throws {
        let gate = CloudExchangeGate(), store = CloudMemoryTokens()
        store.save(.init(accessToken:"expired",refreshToken:"old-refresh",expiresAt:.distantPast))
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:store,tokenExchange:{ await gate.exchange($0) })
        let first = Task { try await session.accessToken() }
        await gate.waitFor("old-refresh")
        let second = Task { try await session.accessToken() }
        for _ in 0..<10 { await Task.yield() }
        try await session.signOut()
        await gate.complete("old-refresh",access:"must-not-return",refresh:"rotated")
        for waiter in [first,second] {
            do { _ = try await waiter.value; XCTFail("refresh survived signout") }
            catch { XCTAssertEqual(error as? ControllerCloudError,.signedOut) }
        }
        XCTAssertNil(store.load())
    }
    func testNewAuthorizationOwnsAccountEvenWhenOlderExchangeCompletesLater() async throws {
        let gate = CloudExchangeGate(), store = CloudMemoryTokens()
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:store,tokenExchange:{ await gate.exchange($0) })
        let first = try await session.beginAuthorization()
        let old = Task { try await session.finishAuthorization(callback:URL(string:"http://127.0.0.1:43871/callback?state=\(first.state)&code=old-code")!) }
        await gate.waitFor("old-code")
        let second = try await session.beginAuthorization()
        let new = Task { try await session.finishAuthorization(callback:URL(string:"http://127.0.0.1:43871/callback?state=\(second.state)&code=new-code")!) }
        await gate.waitFor("new-code"); await gate.complete("new-code",access:"new-account",refresh:"new-refresh")
        try await new.value
        await gate.complete("old-code",access:"old-account",refresh:"old-refresh")
        do { try await old.value; XCTFail("old authorization replaced account") } catch { XCTAssertEqual(error as? ControllerCloudError,.signedOut) }
        XCTAssertEqual(store.load()?.accessToken,"new-account")
    }
    func testCancelInvalidatesAlreadyExchangingAuthorization() async throws {
        let gate = CloudExchangeGate(), store = CloudMemoryTokens()
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:store,tokenExchange:{ await gate.exchange($0) })
        let auth = try await session.beginAuthorization()
        let login = Task { try await session.finishAuthorization(callback:URL(string:"http://127.0.0.1:43871/callback?state=\(auth.state)&code=cancelled-code")!) }
        await gate.waitFor("cancelled-code"); await session.cancelAuthorization()
        await gate.complete("cancelled-code",access:"cancelled",refresh:"cancelled-refresh")
        do { try await login.value; XCTFail("cancelled authorization saved tokens") } catch { XCTAssertEqual(error as? ControllerCloudError,.signedOut) }
        XCTAssertNil(store.load())
    }
    func testOldRefreshCleanupCannotClearNewGenerationRefresh() async throws {
        let gate = CloudExchangeGate(), store = CloudMemoryTokens()
        store.save(.init(accessToken:"expired",refreshToken:"old-refresh",expiresAt:.distantPast))
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:store,tokenExchange:{ await gate.exchange($0) })
        let old = Task { try await session.accessToken() }; await gate.waitFor("old-refresh")
        let auth = try await session.beginAuthorization()
        let login = Task { try await session.finishAuthorization(callback:URL(string:"http://127.0.0.1:43871/callback?state=\(auth.state)&code=new-code")!) }
        await gate.waitFor("new-code"); await gate.complete("new-code",access:"expired-new",refresh:"new-refresh",expires:.distantPast); try await login.value
        let current = Task { try await session.accessToken() }; await gate.waitFor("new-refresh")
        await gate.complete("old-refresh",access:"old",refresh:"old-rotated")
        do { _ = try await old.value; XCTFail("old refresh accepted") } catch {}
        let joined = Task { try await session.accessToken() }
        for _ in 0..<10 { await Task.yield() }
        let count = await gate.count("new-refresh"); XCTAssertEqual(count,1)
        await gate.complete("new-refresh",access:"current",refresh:"current-rotated")
        let currentToken = try await current.value, joinedToken = try await joined.value
        XCTAssertEqual(currentToken,"current"); XCTAssertEqual(joinedToken,"current")
    }
    func testSecureEndpointAndLoopbackRequirements() throws {
        XCTAssertThrowsError(try ControllerCloudConfiguration(baseURL:URL(string:"http://cloud.test")!,authorizationURL:URL(string:"https://auth.test")!,tokenURL:URL(string:"https://auth.test")!,clientID:"x",redirectURI:"http://127.0.0.1:43871/callback"))
        XCTAssertThrowsError(try ControllerCloudConfiguration(baseURL:URL(string:"https://cloud.test")!,authorizationURL:URL(string:"https://auth.test")!,tokenURL:URL(string:"https://auth.test")!,clientID:"x",redirectURI:"http://0.0.0.0:43871/callback"))
    }
    func testSignOutOnlyErasesHumanCredentials() async throws {
        let store = CloudMemoryTokens(); store.save(.init(accessToken:"a",refreshToken:"r",expiresAt:Date().addingTimeInterval(1000)))
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:store)
        let token = try await session.accessToken(); XCTAssertEqual(token,"a")
        try await session.signOut(); XCTAssertNil(store.load())
        do { _ = try await session.accessToken(); XCTFail("signed out credential reused") } catch { XCTAssertEqual(error as? ControllerCloudError,.signedOut) }
    }
}
#endif
