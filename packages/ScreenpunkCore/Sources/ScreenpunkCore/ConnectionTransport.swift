import Foundation

public struct AuthorizedHTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var maxBytes: Int

    public init(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        maxBytes: Int
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maxBytes = maxBytes
    }
}

public struct HTTPTransportResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.headers = headers
        self.status = status
        self.body = body
    }
}

public struct AuthorizedWebSocketRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public var timeout: TimeInterval
    public var maxMessageBytes: Int

    public init(url: URL, headers: [String: String], timeout: TimeInterval, maxMessageBytes: Int) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.maxMessageBytes = maxMessageBytes
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse
}

public protocol WebSocketSession: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func sendText(_ text: String) async throws
    func close() async
}

public extension WebSocketSession {
    func sendText(_ text: String) async throws { try await send(Data(text.utf8)) }
}

public protocol WebSocketTransport: Sendable {
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession
}

public struct ConnectionHTTPResult: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data
    public var stale: Bool
    public var fetchedAt: Date
    public var diagnostic: String

    public init(statusCode: Int, body: Data, stale: Bool, fetchedAt: Date, diagnostic: String) {
        self.statusCode = statusCode
        self.body = body
        self.stale = stale
        self.fetchedAt = fetchedAt
        self.diagnostic = diagnostic
    }
}

public struct SubscriptionID: Sendable, Hashable, Equatable {
    public var raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct HTTPAdapterBounds: Sendable, Equatable {
    public var timeoutSeconds: TimeInterval
    public var maxResponseBytes: Int

    public init(timeoutSeconds: TimeInterval, maxResponseBytes: Int) {
        self.timeoutSeconds = timeoutSeconds
        self.maxResponseBytes = maxResponseBytes
    }

    public static let production = HTTPAdapterBounds(
        timeoutSeconds: TimeInterval(ConnectionBounds.httpTimeoutSeconds),
        maxResponseBytes: ConnectionBounds.httpResponseBytes
    )
}
