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

        var data = Data()
        let http: HTTPURLResponse
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let response = response as? HTTPURLResponse else { throw ConnectionFailure.deviceOffline }
            http = response
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < request.maxBytes else { throw ConnectionFailure.sizeLimit }
                data.append(byte)
            }
        } catch {
            if let failure = error as? ConnectionFailure { throw failure }
            if (error as? URLError)?.code == .timedOut { throw ConnectionFailure.timeout }
            throw ConnectionFailure.deviceOffline
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

    func sendText(_ text: String) async throws { try await task.send(.string(text)) }

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
        task.maximumMessageSize = request.maxMessageBytes
        task.resume()
        return URLSessionWebSocketSession(task: task, maxBytes: request.maxMessageBytes)
    }
}
