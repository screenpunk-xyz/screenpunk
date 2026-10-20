import Foundation

public struct ControllerCloudRealtimeHTTPResponse: Sendable {
    public let status: Int
    public let contentType: String?
    public let data: Data
    public init(status: Int, contentType: String? = nil, data: Data = Data()) {
        self.status = status; self.contentType = contentType; self.data = data
    }
}
public protocol ControllerCloudRealtimeTransport: Sendable {
    func request(_ request: URLRequest, maximumBytes: Int) async throws -> ControllerCloudRealtimeHTTPResponse
    func stream(_ request: URLRequest,
                onOpen: @escaping @Sendable (ControllerCloudRealtimeHTTPResponse) async throws -> Void,
                onData: @escaping @Sendable (Data) async throws -> Void) async throws
}

enum ControllerCloudRealtimeURLPolicy {
    static func databaseOrigin(_ url: URL) -> Bool {
        guard cleanHTTPS(url), url.path.isEmpty || url.path == "/", url.query == nil,
              let host = url.host, host == host.lowercased() else { return false }
        return host.range(of: "^[a-z0-9-]+\\.firebaseio\\.com$", options: .regularExpression) != nil ||
            host.range(of: "^[a-z0-9-]+(?:\\.[a-z0-9-]+)?\\.firebasedatabase\\.app$", options: .regularExpression) != nil
    }
    static func cleanHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.fragment == nil &&
            (url.port == nil || url.port == 443)
    }
    static func authEndpoint(_ url: URL) -> Bool {
        guard cleanHTTPS(url) else { return false }
        return (url.host == "identitytoolkit.googleapis.com" && url.path == "/v1/accounts:signInWithCustomToken") ||
            (url.host == "securetoken.googleapis.com" && url.path == "/v1/token")
    }
    static func redirected(_ next: URL, from original: URL, status: Int) -> Bool {
        guard status == 307, cleanHTTPS(next), next.host == original.host,
              next.port == original.port, next.path == original.path,
              let a = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: next, resolvingAgainstBaseURL: false) else { return false }
        // No guessed shared-shard routing and no forwarding credentials to another Firebase project.
        return a.queryItems == b.queryItems
    }
}

private final class ControllerCloudRealtimeNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Ephemeral, cookie/cache-free REST/SSE client. No Firebase SDK, global auth state or URL logging.
public final class ControllerCloudRealtimeURLSessionTransport: ControllerCloudRealtimeTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate = ControllerCloudRealtimeNoRedirect()
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpAdditionalHeaders = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 3_660
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func request(_ request: URLRequest, maximumBytes: Int) async throws -> ControllerCloudRealtimeHTTPResponse {
        guard let url = request.url, ControllerCloudRealtimeURLPolicy.authEndpoint(url),
              request.httpMethod == "POST", maximumBytes > 0, maximumBytes <= 65_536 else {
            throw ControllerCloudRealtimeFailure.invalidScope
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControllerCloudRealtimeFailure.invalidResponse }
        guard response.expectedContentLength <= maximumBytes else { throw ControllerCloudRealtimeFailure.frameLimit }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw ControllerCloudRealtimeFailure.frameLimit }
            data.append(byte)
        }
        return .init(status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"), data: data)
    }
    public func stream(_ request: URLRequest,
                       onOpen: @escaping @Sendable (ControllerCloudRealtimeHTTPResponse) async throws -> Void,
                       onData: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard let original = request.url, ControllerCloudRealtimeURLPolicy.cleanHTTPS(original),
              var origin = URLComponents(url: original, resolvingAgainstBaseURL: false) else { throw ControllerCloudRealtimeFailure.invalidScope }
        origin.path = ""; origin.query = nil
        guard let database = origin.url, ControllerCloudRealtimeURLPolicy.databaseOrigin(database),
              request.httpMethod == "GET", request.value(forHTTPHeaderField: "Accept") == "text/event-stream" else {
            throw ControllerCloudRealtimeFailure.invalidScope
        }
        var selected = request, redirects = 0
        while true {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: selected)
            guard let response = response as? HTTPURLResponse else { throw ControllerCloudRealtimeFailure.invalidResponse }
            if response.statusCode == 307 {
                guard redirects < 3, let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: selected.url)?.absoluteURL,
                      ControllerCloudRealtimeURLPolicy.redirected(next, from: original, status: 307) else {
                    throw ControllerCloudRealtimeFailure.invalidScope
                }
                redirects += 1; selected.url = next
                continue
            }
            try await onOpen(.init(status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type")))
            var chunk = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if byte == 10 || chunk.count == 4_096 { try await onData(chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { try await onData(chunk) }
            return
        }
    }
}
