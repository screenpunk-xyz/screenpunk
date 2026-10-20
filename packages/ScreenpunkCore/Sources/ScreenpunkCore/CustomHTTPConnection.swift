import Foundation

/// A package describes access, never a credential or user-specific destination.
public struct CustomHTTPDeclaration: Codable, Equatable, Sendable {
    public var name: String
    public var authentication: String // none, bearer, apiKey
    public var headerName: String?
    public var operations: [CustomHTTPOperation]
    public init(name: String, authentication: String, headerName: String? = nil, operations: [CustomHTTPOperation]) {
        self.name = name; self.authentication = authentication; self.headerName = headerName; self.operations = operations
    }
    public func validate(alias: String) throws {
        guard !["home", "googleTV", "googleCalendar", "google-calendar", "appleMaps"].contains(alias),
            alias.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil,
            (1...80).contains(name.utf8.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            ["none", "bearer", "apiKey"].contains(authentication),
            (1...16).contains(operations.count), Set(operations.map(\.name)).count == operations.count else { throw ConnectionFailure.validationFailed }
        if authentication == "apiKey" {
            guard let headerName, headerName.range(of: "^[A-Za-z][A-Za-z0-9-]{0,63}$", options: .regularExpression) != nil,
                !["host", "cookie", "content-length", "transfer-encoding", "connection", "proxy-authorization", "authorization"].contains(headerName.lowercased()) else { throw ConnectionFailure.validationFailed }
        } else if headerName != nil { throw ConnectionFailure.validationFailed }
        for op in operations {
            guard PublicReadDeclaration.safeComponent(op.name), PublicReadDeclaration.safePath(op.path), op.path.utf8.count <= 512,
                ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(op.method), op.parameters.count <= 12 else { throw ConnectionFailure.validationFailed }
            for (key, values) in op.parameters {
                guard PublicReadDeclaration.safeComponent(key), !ConnectionAuthKeys.isOverride(key), !ConnectionAuthKeys.isDestination(key),
                    key.lowercased() != headerName?.lowercased(), (1...64).contains(values.count), Set(values).count == values.count,
                    values.allSatisfy({ $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw ConnectionFailure.validationFailed }
            }
        }
    }
}
public struct CustomHTTPOperation: Codable, Equatable, Sendable {
    public var name: String
    public var method: String
    public var path: String
    /// Exact allowed values. GET/DELETE use query parameters; other methods use a flat JSON body.
    public var parameters: [String: [String]]
    public init(name: String, method: String, path: String, parameters: [String: [String]] = [:]) {
        self.name = name; self.method = method; self.path = path; self.parameters = parameters
    }
}
public struct CustomHTTPConfiguration: Codable, Equatable, Sendable {
    public var origin: String
    public var secret: String
    public var allowLocalNetwork: Bool
    public var allowInsecureHTTP: Bool
    public init(origin: String, secret: String, allowLocalNetwork: Bool, allowInsecureHTTP: Bool) {
        self.origin = origin; self.secret = secret; self.allowLocalNetwork = allowLocalNetwork; self.allowInsecureHTTP = allowInsecureHTTP
    }
    public func grant(alias: String, declaration: CustomHTTPDeclaration) throws -> ConnectionGrant {
        try declaration.validate(alias: alias)
        guard secret.utf8.count <= 8192, !secret.contains("\r"), !secret.contains("\n"),
            declaration.authentication == "none" || !secret.isEmpty else { throw ConnectionFailure.validationFailed }
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: alias, origin: origin, transport: .http,
            authRef: "custom", lan: allowLocalNetwork, allowInsecureHTTP: allowInsecureHTTP,
            operations: declaration.operations.map { .init(name: $0.name, kind: .http, method: ConnectionMethod(rawValue: $0.method)!, path: $0.path, idempotent: $0.method == "GET", write: $0.method != "GET") })
        try ConnectionGrantValidator.validate(grant)
        return grant
    }
}
public typealias DeviceCustomHTTPProvider = @Sendable (UUID, DashboardManifest, String) throws -> CustomHTTPConfiguration?

/// A fresh native runtime per request prevents stale data and credentials crossing approvals.
actor DeviceCustomHTTPRuntime {
    let installationID: UUID
    let manifest: DashboardManifest
    let provider: DeviceCustomHTTPProvider
    let http: any HTTPTransport
    let webSocket: any WebSocketTransport
    let resolver: any DestinationResolver
    let validate: @Sendable () throws -> Void
    init(installationID: UUID, manifest: DashboardManifest, provider: @escaping DeviceCustomHTTPProvider,
         http: any HTTPTransport, webSocket: any WebSocketTransport, resolver: any DestinationResolver, validate: @escaping @Sendable () throws -> Void) {
        self.installationID = installationID; self.manifest = manifest; self.provider = provider
        self.http = http; self.webSocket = webSocket; self.resolver = resolver; self.validate = validate
    }
    func request(alias: String, operation: String, parameters: [String: String], readOnly: Bool) async throws -> ConnectionHTTPResult {
        try validate()
        guard let d = manifest.connections.first(where: { $0.alias == alias })?.customHTTP,
            let op = d.operations.first(where: { $0.name == operation }), !readOnly || op.method == "GET",
            Set(parameters.keys) == Set(op.parameters.keys), parameters.allSatisfy({ op.parameters[$0.key]?.contains($0.value) == true }),
            let config = try provider(installationID, manifest, alias) else { throw ConnectionFailure.permissionRequired }
        let store = MemoryCredentialStore()
        try store.put(Data(config.secret.utf8), for: "custom")
        let runtime = ConnectionRuntime(dashboardId: manifest.dashboardId, store: store, http: http, webSocket: webSocket, resolver: resolver,
            authorizeScope: { [provider, installationID, manifest, validate] in
                try validate()
                guard try provider(installationID, manifest, alias) == config else { throw ConnectionFailure.permissionRequired }
            })
        let binding = ConnectionAuthBinding(authRef: "custom", placement: d.authentication == "none" ? .none : d.authentication == "bearer" ? .bearer : .header, fieldName: d.headerName)
        try await runtime.install(grant: config.grant(alias: alias, declaration: d), binding: binding)
        return try await runtime.request(alias: alias, operation: operation, parameters: parameters)
    }
}
