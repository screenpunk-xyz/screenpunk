import Foundation

/// The Firebase adapter asks the SDK for an ID token for each request. The client never stores tokens.
public protocol CloudNativeTokenProvider: Sendable {
    func idToken() async throws -> String
}

/// Only the three accepted human identity endpoints. No enrollment, cookie session, or default IDs.
public struct CloudNativeClient: Sendable {
    private let origin: URL
    private let tokenProvider: any CloudNativeTokenProvider
    private let transport: any HTTPTransport
    public static let maximumResponseBytes = 1_048_576

    public init(baseURL: URL, tokenProvider: any CloudNativeTokenProvider, transport: any HTTPTransport) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw CloudNativeFailure.invalidBaseURL }
        origin = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    public func signIn() async throws -> CloudNativeSignInResponse {
        try await request(path: "/v1/native/sign-in", method: "POST", body: Data("{}".utf8))
    }
    public func accounts(limit: Int? = nil, cursor: String? = nil) async throws -> CloudNativePage<CloudNativeAccount> {
        try await request(path: "/v1/native/accounts", query: pagination(limit: limit, cursor: cursor))
    }
    public func locations(accountID: UUID, limit: Int? = nil, cursor: String? = nil) async throws -> CloudNativePage<CloudNativeLocation> {
        try await request(path: "/v1/native/accounts/\(accountID.uuidString.lowercased())/locations", query: pagination(limit: limit, cursor: cursor))
    }
    public func allAccounts(limit: Int? = nil) async throws -> [CloudNativeAccount] {
        try await collect { try await accounts(limit: limit, cursor: $0) }
    }
    public func allLocations(accountID: UUID, limit: Int? = nil) async throws -> [CloudNativeLocation] {
        try await collect { try await locations(accountID: accountID, limit: limit, cursor: $0) }
    }

    private func collect<Item>(_ page: (String?) async throws -> CloudNativePage<Item>) async throws -> [Item] {
        var result: [Item] = []
        var cursor: String?
        var observed = Set<String>()
        repeat {
            try checkCancellation()
            let next = try await page(cursor)
            result += next.items
            cursor = next.nextCursor
            if let cursor, !observed.insert(cursor).inserted { throw CloudNativeFailure.paginationCycle }
        } while cursor != nil
        return result
    }

    private func pagination(limit: Int?, cursor: String?) throws -> [URLQueryItem] {
        guard limit.map({ (1...200).contains($0) }) ?? true,
              cursor.map({ !$0.isEmpty && $0.count <= 2048 }) ?? true else { throw CloudNativeFailure.invalidPagination }
        var items: [URLQueryItem] = []
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        if let cursor { items.append(.init(name: "cursor", value: cursor)) }
        return items
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CloudNativeFailure.cancelled }
    }
    private func request<Response: Decodable>(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Response {
        try checkCancellation()
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        // '+' is a literal cursor character, never form-encoded whitespace.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw CloudNativeFailure.invalidBaseURL }
        let token: String
        do { token = try await tokenProvider.idToken() }
        catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CloudNativeFailure.cancelled }
            throw CloudNativeFailure.tokenUnavailable
        }
        try checkCancellation()
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw CloudNativeFailure.tokenUnavailable }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json", "Cache-Control": "no-store"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let response: HTTPTransportResponse
        do {
            response = try await transport.send(.init(url: url, method: method, headers: headers, body: body, timeout: 30, maxBytes: Self.maximumResponseBytes))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CloudNativeFailure.cancelled }
            if let known = error as? CloudNativeFailure { throw known }
            throw CloudNativeFailure.transportUnavailable
        }
        try checkCancellation()
        guard response.body.count <= Self.maximumResponseBytes else { throw CloudNativeFailure.responseTooLarge }
        if (300...399).contains(response.status) { throw CloudNativeFailure.redirectRejected }
        let decoder = JSONDecoder()
        guard (200...299).contains(response.status) else {
            if let api = try? decoder.decode(CloudNativeAPIError.self, from: response.body) { throw CloudNativeFailure.api(status: response.status, error: api) }
            throw CloudNativeFailure.http(status: response.status)
        }
        do { return try decoder.decode(Response.self, from: response.body) }
        catch { throw CloudNativeFailure.invalidResponse }
    }
}
