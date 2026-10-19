import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class CloudNativeTransportTests: XCTestCase {
    func testEphemeralConfigurationOmitsCookieCacheAndCredentialStorage() {
        let transport = CloudNativeURLSessionTransport()
        let configuration = transport.session.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRedirectDelegateNeverReturnsAuthorizedRequest() {
        let transport = CloudNativeURLSessionTransport()
        let original = URLRequest(url: URL(string: "https://cloud.example/v1/native/accounts")!)
        let task = transport.session.dataTask(with: original)
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://elsewhere.example"])!
        for url in ["https://elsewhere.example", "https://cloud.example/another", "http://cloud.example"] {
            var redirected = URLRequest(url: URL(string: url)!)
            redirected.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
            var called = false
            transport.redirectDelegate.urlSession(transport.session, task: task, willPerformHTTPRedirection: response,
                                                   newRequest: redirected) { selected in
                called = true
                XCTAssertNil(selected, "Even same-origin redirects cannot replay a native ID token")
            }
            XCTAssertTrue(called)
        }
        task.cancel()
    }

    func testActualSessionSendsAuthorizationButNoCookiesAndNeverCaches() async throws {
        let recorder = NativeWireRecorder()
        NativeWireProtocol.recorder = recorder
        defer { NativeWireProtocol.recorder = nil }
        let transport = CloudNativeURLSessionTransport(protocolClasses: [NativeWireProtocol.self])
        let request = AuthorizedHTTPRequest(url: URL(string: "https://cloud.example/v1/native/accounts")!, method: "GET",
                                           headers: ["Authorization": "Bearer fixture-id-token", "Cookie": "browser=session"],
                                           body: nil, timeout: 5, maxBytes: 1024)
        let first = try await transport.send(request)
        let second = try await transport.send(request)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(second.status, 200)
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 2)
        for wire in requests {
            XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-id-token")
            XCTAssertNil(wire.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(wire.httpShouldHandleCookies)
            XCTAssertEqual(wire.cachePolicy, .reloadIgnoringLocalCacheData)
        }
        XCTAssertNil(transport.session.configuration.httpCookieStorage)
    }

    func testSessionRejectsRedirectResponseWithoutFollowingLocation() async throws {
        let recorder = NativeWireRecorder(status: 302)
        NativeWireProtocol.recorder = recorder
        defer { NativeWireProtocol.recorder = nil }
        let transport = CloudNativeURLSessionTransport(protocolClasses: [NativeWireProtocol.self])
        do { _ = try await transport.send(request()); XCTFail("Expected redirect failure") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .redirectRejected) }
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testStreamBoundsNetworkErrorsAndCancellation() async throws {
        let recorder = NativeWireRecorder(body: Data(repeating: 32, count: 100))
        NativeWireProtocol.recorder = recorder
        defer { NativeWireProtocol.recorder = nil }
        let transport = CloudNativeURLSessionTransport(protocolClasses: [NativeWireProtocol.self])
        do { _ = try await transport.send(request(maxBytes: 10)); XCTFail("Expected response size failure") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .responseTooLarge) }
        recorder.setError(URLError(.timedOut))
        do { _ = try await transport.send(request()); XCTFail("Expected transport failure") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .transportUnavailable) }
        recorder.setError(URLError(.cancelled))
        do { _ = try await transport.send(request()); XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .cancelled) }
        var insecure = request()
        insecure.url = URL(string: "http://cloud.example/v1/native/accounts")!
        do { _ = try await transport.send(insecure); XCTFail("Expected HTTPS requirement") }
        catch { XCTAssertEqual(error as? CloudNativeFailure, .invalidBaseURL) }
    }

    private func request(maxBytes: Int = 1024) -> AuthorizedHTTPRequest {
        .init(url: URL(string: "https://cloud.example/v1/native/accounts")!, method: "GET",
              headers: ["Authorization": "Bearer fixture-id-token"], body: nil, timeout: 5, maxBytes: maxBytes)
    }
}

private final class NativeWireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var error: Error?
    let status: Int
    let body: Data
    init(status: Int = 200, body: Data = Data("{\"items\":[],\"nextCursor\":null}".utf8)) { self.status = status; self.body = body }
    func record(_ request: URLRequest) -> Error? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return error
    }
    func setError(_ error: Error) { lock.lock(); defer { lock.unlock() }; self.error = error }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class NativeWireProtocol: URLProtocol {
    // Each test installs its isolated recorder; XCTest runs this class sequentially.
    static var recorder: NativeWireRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let recorder = Self.recorder else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if let error = recorder.record(request) { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: recorder.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Set-Cookie": "browser=must-not-stick; Secure", "Cache-Control": "max-age=3600",
                           "Location": "https://elsewhere.example"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: recorder.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
