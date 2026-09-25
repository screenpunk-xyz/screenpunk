import Foundation

/// A bounded, unencoded single path segment; never a URL or relative path.
public struct PublicReadPathSegment: Codable, Equatable, Sendable {
    public var maxLength: Int
    public init(maxLength: Int) { self.maxLength = maxLength }
    func accepts(_ value: String) -> Bool {
        (1...maxLength).contains(value.utf8.count) &&
        value.range(of: "^[a-zA-Z0-9_][a-zA-Z0-9_.~-]*\\z", options: .regularExpression) != nil
    }
}

/// Untrusted package declaration. Approval binds the complete declaration to an immutable revision.
public struct PublicReadParameter: Codable, Equatable, Sendable {
    public var location: String // path or query
    public var minimum: Int?
    public var maximum: Int?
    public var values: [String]?
    public var pathSegment: PublicReadPathSegment?
    public init(location: String, minimum: Int? = nil, maximum: Int? = nil, values: [String]? = nil, pathSegment: PublicReadPathSegment? = nil) {
        self.location = location; self.minimum = minimum; self.maximum = maximum; self.values = values; self.pathSegment = pathSegment
    }
    func validate() throws {
        guard ["path", "query"].contains(location) else { throw ConnectionFailure.validationFailed }
        if let pathSegment {
            guard location == "path", minimum == nil, maximum == nil, values == nil,
                  (1...256).contains(pathSegment.maxLength) else { throw ConnectionFailure.validationFailed }
        } else if let values {
            guard minimum == nil, maximum == nil, (1...64).contains(values.count), Set(values).count == values.count,
                  values.allSatisfy({ value in
                      (1...256).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { (32...126).contains($0.value) }
                      && (location == "query" || PublicReadDeclaration.safePathComponent(value))
                  }) else { throw ConnectionFailure.validationFailed }
        } else {
            guard let minimum, let maximum, minimum >= -9_007_199_254_740_991,
                  maximum <= 9_007_199_254_740_991, minimum <= maximum else { throw ConnectionFailure.validationFailed }
        }
    }
    func accepts(_ value: String) -> Bool {
        if let pathSegment { return pathSegment.accepts(value) }
        if let values { return values.contains(value) }
        guard let n = Int(value), String(n) == value, let minimum, let maximum else { return false }
        return (minimum...maximum).contains(n)
    }
}

public struct PublicReadOperation: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var response: String // json or raster
    public var parameters: [String: PublicReadParameter]
    public var maxAgeSeconds: Int
    public var staleSeconds: Int
    public init(name: String, path: String, response: String, parameters: [String: PublicReadParameter] = [:], maxAgeSeconds: Int = 300, staleSeconds: Int = 3600) {
        self.name = name; self.path = path; self.response = response; self.parameters = parameters
        self.maxAgeSeconds = maxAgeSeconds; self.staleSeconds = staleSeconds
    }
    public func resolve(_ supplied: [String: String]) throws -> (path: String, query: [String: String]) {
        guard Set(supplied.keys) == Set(parameters.keys) else { throw ConnectionFailure.permissionRequired }
        var resolved = path; var query: [String: String] = [:]
        for (key, rule) in parameters {
            guard let value = supplied[key], rule.accepts(value) else { throw ConnectionFailure.permissionRequired }
            if rule.location == "path" { resolved = resolved.replacingOccurrences(of: "{" + key + "}", with: value) }
            else { query[key] = value }
        }
        guard resolved.utf8.count <= 512, PublicReadDeclaration.safePath(resolved) else { throw ConnectionFailure.deniedEgress }
        return (resolved, query)
    }
}

public struct PublicReadDeclaration: Codable, Equatable, Sendable {
    public var origin: String
    /// Native identifying User-Agent; no arbitrary headers or authentication are accepted.
    public var userAgent: String
    public var operations: [PublicReadOperation]
    public init(origin: String, userAgent: String = "Screenpunk/1 (public data reader)", operations: [PublicReadOperation]) {
        self.origin = origin; self.userAgent = userAgent; self.operations = operations
    }
    public var requiresDynamicPaths: Bool {
        operations.contains { $0.parameters.values.contains { $0.pathSegment != nil } }
    }
    public func validate(alias: String) throws {
        guard alias != "home", alias.range(of: "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil,
              let url = URLComponents(string: origin), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, origin == "https://" + host + (url.port == nil ? "" : ":443"),
              host.range(of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$", options: .regularExpression) != nil,
              AddressClassifier.classify(host: host) == .publicUnicast,
              (1...256).contains(userAgent.utf8.count), userAgent.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
              (1...16).contains(operations.count), Set(operations.map(\.name)).count == operations.count else { throw ConnectionFailure.validationFailed }
        for operation in operations {
            guard Self.safeComponent(operation.name), ["json", "raster"].contains(operation.response),
                  (1...86400).contains(operation.maxAgeSeconds), (0...604800).contains(operation.staleSeconds),
                  operation.parameters.count <= 12, operation.path.utf8.count <= 512 else { throw ConnectionFailure.validationFailed }
            if operation.parameters.values.contains(where: { $0.pathSegment != nil }) {
                // Require an approved literal top-level directory and raster decoding.
                let prefix = operation.path.split(separator: "/", omittingEmptySubsequences: false)
                guard operation.response == "raster", prefix.count >= 3,
                      Self.safePathComponent(String(prefix[1])) else { throw ConnectionFailure.validationFailed }
            }
            var sample: [String: String] = [:]
            for (key, rule) in operation.parameters {
                guard Self.safeComponent(key), !ConnectionAuthKeys.isOverride(key), !ConnectionAuthKeys.isDestination(key) else { throw ConnectionFailure.validationFailed }
                try rule.validate()
                let marker = "{" + key + "}"
                guard (rule.location == "path") == operation.path.contains(marker) else { throw ConnectionFailure.validationFailed }
                sample[key] = rule.pathSegment != nil ? "x" : (rule.values?.first ?? String(rule.minimum!))
            }
            _ = try operation.resolve(sample)
        }
    }
    static func safeComponent(_ s: String) -> Bool {
        (1...128).contains(s.utf8.count) && s != "." && s != ".." && s.range(of: "^[a-zA-Z0-9_.-]+$", options: .regularExpression) != nil
    }
    static func safePathComponent(_ s: String) -> Bool {
        (1...256).contains(s.utf8.count) && s != "." && s != ".." && s.range(of: "^[a-zA-Z0-9_.,~-]+\\z", options: .regularExpression) != nil
    }
    static func safePath(_ s: String) -> Bool {
        s.hasPrefix("/") && !s.hasPrefix("//") && s.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { safePathComponent(String($0)) }
    }
    public func grant(alias: String, operation: PublicReadOperation, parameters: [String: String]) throws -> (ConnectionGrant, [String: String]) {
        try validate(alias: alias)
        let resolved = try operation.resolve(parameters)
        return (.init(schemaVersion: 1, id: UUID(), alias: alias, origin: origin, transport: .http,
                      authRef: "public-no-auth", lan: false, allowInsecureHTTP: false,
                      operations: [.init(name: operation.name, kind: .http, method: .GET, path: resolved.path, idempotent: true, write: false)]), resolved.query)
    }
}

public struct PublicReadProvisioning: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var dashboardId: String
    public var revision: String
    public var connections: [ManifestConnection]
    public init(dashboardId: String, revision: String, connections: [ManifestConnection]) throws {
        self.dashboardId = dashboardId; self.revision = revision; self.connections = connections
        try validate()
    }
    public init(manifest: DashboardManifest) throws {
        dashboardId = manifest.dashboardId; revision = manifest.revision
        connections = manifest.connections.filter { $0.publicHTTP != nil }
        try validate()
    }
    public var requiresDynamicPaths: Bool { connections.contains { $0.publicHTTP?.requiresDynamicPaths == true } }
    public func validate() throws {
        guard schemaVersion == 1, !dashboardId.isEmpty, !revision.isEmpty, connections.count <= 8,
              Set(connections.map(\.alias)).count == connections.count else { throw ConnectionFailure.validationFailed }
        for connection in connections {
            guard let declaration = connection.publicHTTP, connection.serviceCalls == nil, connection.cameraEntities == nil,
                  connection.operations == nil else { throw ConnectionFailure.validationFailed }
            try declaration.validate(alias: connection.alias)
        }
    }
}
