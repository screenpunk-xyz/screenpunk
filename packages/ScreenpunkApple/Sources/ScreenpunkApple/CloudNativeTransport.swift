import Foundation
import ScreenpunkCore

final class CloudNativeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a human ID token to another origin, or replay it through a redirect.
        completionHandler(nil)
    }
}

/// Dedicated ephemeral native identity transport. No cookie, URL cache, or credential storage.
public final class CloudNativeURLSessionTransport: HTTPTransport, @unchecked Sendable {
    let session: URLSession
    let redirectDelegate: CloudNativeRedirectDelegate

    public convenience init() { self.init(protocolClasses: nil) }
    init(protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let delegate = CloudNativeRedirectDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        guard request.url.scheme?.lowercased() == "https", request.url.user == nil, request.url.password == nil else {
            throw CloudNativeFailure.invalidBaseURL
        }
        if Task.isCancelled { throw CloudNativeFailure.cancelled }
        var wire = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(30, request.timeout))
        wire.httpMethod = request.method
        wire.httpBody = request.body
        wire.httpShouldHandleCookies = false
        for (name, value) in request.headers { wire.setValue(value, forHTTPHeaderField: name) }
        wire.setValue(nil, forHTTPHeaderField: "Cookie")
        wire.setValue(nil, forHTTPHeaderField: "Cookie2")
        wire.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let maximum = min(max(0, request.maxBytes), CloudNativeClient.maximumResponseBytes)
        do {
            let (bytes, response) = try await session.bytes(for: wire)
            guard let http = response as? HTTPURLResponse, http.url == wire.url else { throw CloudNativeFailure.invalidResponse }
            if (300...399).contains(http.statusCode) { throw CloudNativeFailure.redirectRejected }
            if http.expectedContentLength > Int64(maximum) { throw CloudNativeFailure.responseTooLarge }
            var body = Data()
            for try await byte in bytes {
                if Task.isCancelled { throw CloudNativeFailure.cancelled }
                guard body.count < maximum else { throw CloudNativeFailure.responseTooLarge }
                body.append(byte)
            }
            return .init(status: http.statusCode, body: body)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CloudNativeFailure.cancelled }
            if let known = error as? CloudNativeFailure { throw known }
            throw CloudNativeFailure.transportUnavailable
        }
    }
}
