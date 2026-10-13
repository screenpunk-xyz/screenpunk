import Foundation

/// Test-only routing to the owned local API. Responses are supplied exclusively
/// by that API; this adapter does not manufacture enrollment or delivery proof.
final class JoinedCloudHTTPForwarder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var route: (logical: URL, transport: URL)?
    private var forwardingTask: URLSessionDataTask?
    static func install(logical: URL, transport: URL) {
        lock.lock(); route = (logical, transport); lock.unlock()
        URLProtocol.registerClass(Self.self)
    }
    static func remove() {
        URLProtocol.unregisterClass(Self.self)
        lock.lock(); route = nil; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host == route?.logical.host
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let route = Self.route; Self.lock.unlock()
        guard let route, let original = request.url,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: route.transport, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        components.scheme = target.scheme; components.host = target.host; components.port = target.port
        guard let url = components.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        var forwarded = request; forwarded.url = url
        forwarded.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration,delegate:JoinedCloudNoRedirect(),delegateQueue:nil)
        forwardingTask = session.dataTask(with: forwarded) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let response = response as? HTTPURLResponse,
                  let relayed = HTTPURLResponse(url: original, statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1", headerFields: response.allHeaderFields.reduce(into: [String:String]()) {
                        if let key = $1.key as? String { $0[key] = String(describing: $1.value) }
                    }) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            print("Joined API response", request.httpMethod ?? "GET", original.path.split(separator:"/").prefix(5).joined(separator:"/"), response.statusCode)
            if response.statusCode != 200, let data,
               let error = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let code = error["code"] as? String {
                print("Joined API error code", code)
            }
            self.client?.urlProtocol(self, didReceive: relayed, cacheStoragePolicy: .notAllowed)
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardingTask?.resume()
    }
    override func stopLoading() { forwardingTask?.cancel() }
}

private final class JoinedCloudNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
