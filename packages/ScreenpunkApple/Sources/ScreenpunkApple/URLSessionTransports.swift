import Foundation
import ScreenpunkCore

final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Native HTTP adapter. TLS stays on. Redirects are not followed.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let bounds: HTTPAdapterBounds
    private let session: URLSession
    private let delegate: RedirectDenyingDelegate

    public init(bounds: HTTPAdapterBounds = .production) {
        self.bounds = bounds
        let delegate = RedirectDenyingDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = bounds.timeoutSeconds
        configuration.timeoutIntervalForResource = bounds.timeoutSeconds
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            if (error as? URLError)?.code == .timedOut {
                throw ConnectionFailure.timeout
            }
            throw ConnectionFailure.deviceOffline
        }

        guard let http = response as? HTTPURLResponse else {
            throw ConnectionFailure.deviceOffline
        }
        if data.count > request.maxBytes {
            throw ConnectionFailure.sizeLimit
        }
        return HTTPTransportResponse(status: http.statusCode, body: data)
    }
}

final class URLSessionWebSocketSession: WebSocketSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let maxBytes: Int

    init(task: URLSessionWebSocketTask, maxBytes: Int) {
        self.task = task
        self.maxBytes = maxBytes
    }

    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw ConnectionFailure.deviceOffline
        }
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw ConnectionFailure.validationFailed
        }
        if data.count > maxBytes {
            throw ConnectionFailure.sizeLimit
        }
        return data
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Native WebSocket adapter. Auth is applied on the handshake, never by page JS.
public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: RedirectDenyingDelegate

    public init() {
        let delegate = RedirectDenyingDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.webSocketTask(with: urlRequest)
        task.resume()
        return URLSessionWebSocketSession(task: task, maxBytes: request.maxMessageBytes)
    }
}
