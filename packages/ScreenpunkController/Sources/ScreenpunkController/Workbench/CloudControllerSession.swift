import Foundation
#if os(macOS)
import CryptoKit
import Security

public enum ControllerCloudError: Error, Equatable {
    case invalidConfiguration, invalidCallback, signedOut, accountMismatch, conflict, deletedProject, invalidSource, sourceLimitExceeded, invalidResponse, http(Int)
}
extension ControllerCloudError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceLimitExceeded: return "This project exceeds the controller source limit of 2,000 files, 25 MiB total, or 5 MiB per file. Source was not truncated or applied."
        case .conflict: return "The project changed after review. Synchronize and review both revisions again."
        case .accountMismatch: return "This project is linked to a different cloud account."
        case .deletedProject: return "The cloud project is unavailable or deleted. Local source is preserved."
        default: return nil
        }
    }
}
public struct ControllerCloudConfiguration: Sendable {
    public let baseURL: URL
    public let authorizationURL: URL
    public let tokenURL: URL
    public let clientID: String
    public let redirectURI: String
    public let revocationURL: URL?
    public init(baseURL: URL, authorizationURL: URL, tokenURL: URL, clientID: String, redirectURI: String, revocationURL: URL? = nil) throws {
        let endpoints: [URL] = [baseURL, authorizationURL, tokenURL] + (revocationURL.map { [$0] } ?? [])
        for endpoint in endpoints {
            guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil else { throw ControllerCloudError.invalidConfiguration }
        }
        guard
              !clientID.isEmpty, let redirect = URL(string: redirectURI),
              redirect.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(redirect.host ?? "") else { throw ControllerCloudError.invalidConfiguration }
        self.baseURL = baseURL; self.authorizationURL = authorizationURL; self.tokenURL = tokenURL
        self.clientID = clientID; self.redirectURI = redirectURI; self.revocationURL = revocationURL
    }
}
public struct ControllerCloudTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
}
public protocol ControllerCloudTokenStore: Sendable {
    func load() throws -> ControllerCloudTokens?
    func save(_ tokens: ControllerCloudTokens?) throws
}
/// Each server/client pair has its own Keychain item. Tokens are never written to project backup.
public struct ControllerCloudKeychain: ControllerCloudTokenStore {
    private let account: String
    public init(server: URL, clientID: String) { account = server.absoluteString + "|" + clientID }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.screenpunk.controller.cloud", kSecAttrAccount as String: account] }
    public func load() throws -> ControllerCloudTokens? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ControllerCloudError.signedOut }
        return try JSONDecoder().decode(ControllerCloudTokens.self, from: data)
    }
    public func save(_ tokens: ControllerCloudTokens?) throws {
        guard let tokens else { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ControllerCloudError.signedOut }; return }
        let bytes = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { var q = query; attributes.forEach { q[$0.key] = $0.value }; status = SecItemAdd(q as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ControllerCloudError.signedOut }
    }
}
public struct ControllerCloudAuthorization: Sendable {
    public let url: URL
    public let state: String
    fileprivate let verifier: String
    fileprivate let generation: Int
}
public actor ControllerCloudSession {
    private let configuration: ControllerCloudConfiguration
    private let store: any ControllerCloudTokenStore
    private let session: URLSession
    private var epoch = 0
    private var pending: ControllerCloudAuthorization?
    private struct RefreshJob {
        let id: UUID
        let generation: Int
        let task: Task<ControllerCloudTokens, Error>
    }
    private var refreshTask: RefreshJob?
    private let tokenExchange: (@Sendable ([String:String]) async throws -> ControllerCloudTokens)?
    public init(configuration: ControllerCloudConfiguration, tokenStore: any ControllerCloudTokenStore, session: URLSession = .shared) {
        self.configuration = configuration; store = tokenStore; self.session = session; tokenExchange = nil
    }
    init(configuration: ControllerCloudConfiguration, tokenStore: any ControllerCloudTokenStore,
         tokenExchange: @escaping @Sendable ([String:String]) async throws -> ControllerCloudTokens) {
        self.configuration = configuration; store = tokenStore; session = .shared; self.tokenExchange = tokenExchange
    }
    public func beginAuthorization() throws -> ControllerCloudAuthorization {
        epoch += 1; refreshTask?.task.cancel(); refreshTask = nil; pending = nil
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ControllerCloudError.invalidConfiguration }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let verifier = try random(), state = try random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
        url.queryItems = ["response_type":"code", "client_id":configuration.clientID, "redirect_uri":configuration.redirectURI, "scope":"screenpunk.read screenpunk.write screenpunk.workspaces", "resource":configuration.baseURL.appendingPathComponent("mcp").absoluteString, "state":state, "code_challenge":challenge, "code_challenge_method":"S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let target = url.url else { throw ControllerCloudError.invalidConfiguration }
        let request = ControllerCloudAuthorization(url: target, state: state, verifier: verifier, generation: epoch); pending = request; return request
    }
    public func finishAuthorization(callback: URL) async throws {
        guard let request = pending, let expected = URL(string: configuration.redirectURI),
              callback.scheme == expected.scheme, callback.host == expected.host, callback.port == expected.port, callback.path == expected.path,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw ControllerCloudError.invalidCallback }
        let items = components.queryItems ?? []
        guard items.filter({$0.name == "state"}).count == 1, items.first(where: {$0.name == "state"})?.value == request.state,
              items.filter({$0.name == "code"}).count == 1, let code = items.first(where: {$0.name == "code"})?.value, !code.isEmpty else { throw ControllerCloudError.invalidCallback }
        pending = nil
        let authorizationEpoch = request.generation
        let tokens = try await exchange(["grant_type":"authorization_code", "code":code, "redirect_uri":configuration.redirectURI, "code_verifier":request.verifier])
        guard epoch == authorizationEpoch else { throw ControllerCloudError.signedOut }
        try store.save(tokens)
    }
    public func cancelAuthorization() { epoch += 1; pending = nil; refreshTask?.task.cancel(); refreshTask = nil }
    public func signOut() async throws {
        epoch += 1; pending = nil; refreshTask?.task.cancel(); refreshTask = nil
        let tokens = try store.load()
        // Always erase locally; disconnected clients must never keep using cached credentials.
        try store.save(nil)
        guard let tokens, let endpoint = configuration.revocationURL else { return }
        var components = URLComponents(); components.queryItems = [
            URLQueryItem(name: "token", value: tokens.refreshToken),
            URLQueryItem(name: "token_type_hint", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: configuration.clientID)]
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (_, response) = try await session.data(for: request)
        guard let result = response as? HTTPURLResponse, result.statusCode == 200 else { throw ControllerCloudError.invalidResponse }
    }
    public func accessToken() async throws -> String {
        guard let tokens = try store.load() else { throw ControllerCloudError.signedOut }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        let job: RefreshJob
        if let existing = refreshTask { job = existing }
        else {
            job = RefreshJob(id: UUID(), generation: epoch,
                task: Task { try await self.exchange(["grant_type":"refresh_token", "refresh_token":tokens.refreshToken]) })
            refreshTask = job
        }
        defer { if refreshTask?.id == job.id { refreshTask = nil } }
        let refreshed = try await job.task.value
        guard epoch == job.generation else { throw ControllerCloudError.signedOut }
        try store.save(refreshed)
        return refreshed.accessToken
    }

    private func exchange(_ values: [String: String]) async throws -> ControllerCloudTokens {
        if let tokenExchange { return try await tokenExchange(values) }
        var values = values; values["client_id"] = configuration.clientID
        var components = URLComponents(); components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: configuration.tokenURL); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControllerCloudError.invalidResponse }
        guard response.statusCode == 200 else { throw ControllerCloudError.http(response.statusCode) }
        struct Response: Decodable { let access_token: String; let refresh_token: String; let expires_in: Double; let token_type: String }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.token_type.lowercased() == "bearer", !result.access_token.isEmpty, !result.refresh_token.isEmpty, result.expires_in > 0 else { throw ControllerCloudError.invalidResponse }
        return .init(accessToken: result.access_token, refreshToken: result.refresh_token, expiresAt: Date().addingTimeInterval(result.expires_in))
    }
    public func request<Response: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil, as type: Response.Type) async throws -> Response {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(".."),
              let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.host == configuration.baseURL.host else { throw ControllerCloudError.invalidConfiguration }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControllerCloudError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ControllerCloudError.http(response.statusCode) }
        return try JSONDecoder().decode(type, from: data)
    }
}
#endif
