import XCTest
@testable import ScreenpunkController
#if os(macOS)
private final class CloudMemoryTokens: ControllerCloudTokenStore, @unchecked Sendable {
    private let lock = NSLock(); private var tokens: ControllerCloudTokens?
    func load() -> ControllerCloudTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ tokens: ControllerCloudTokens?) { lock.lock(); defer { lock.unlock() }; self.tokens = tokens }
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
    private func configuration() throws -> ControllerCloudConfiguration {
        try .init(baseURL:URL(string:"https://cloud.screenpunk.test")!,authorizationURL:URL(string:"https://auth.screenpunk.test/authorize")!,tokenURL:URL(string:"https://auth.screenpunk.test/token")!,clientID:"screenpunk-cli",redirectURI:"http://127.0.0.1:43871/callback")
    }
    func testAuthorizationUsesPKCEAndFreshState() async throws {
        let session = ControllerCloudSession(configuration:try configuration(),tokenStore:CloudMemoryTokens())
        let first = try await session.beginAuthorization(), second = try await session.beginAuthorization()
        XCTAssertNotEqual(first.state,second.state)
        let items = URLComponents(url:first.url,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(items.first {$0.name == "code_challenge_method"}?.value,"S256")
        XCTAssertEqual(items.first {$0.name == "code_challenge"}?.value?.count,43)
        XCTAssertNil(items.first {$0.name == "code_verifier"})
        XCTAssertEqual(items.first {$0.name == "resource"}?.value,"https://cloud.screenpunk.test/mcp")
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
