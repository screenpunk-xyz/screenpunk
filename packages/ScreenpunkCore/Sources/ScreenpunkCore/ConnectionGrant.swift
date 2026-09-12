import Foundation

public enum ConnectionTransport: String, Sendable, Codable, Equatable {
    case http
    case ws
}

public enum ConnectionMethod: String, Sendable, Codable, Equatable {
    case GET
    case POST
    case PUT
    case PATCH
    case DELETE
}

public struct ConnectionOperation: Sendable, Codable, Equatable {
    public var name: String
    public var kind: ConnectionTransport
    public var method: ConnectionMethod
    public var path: String
    public var idempotent: Bool
    public var write: Bool
    public var maxAgeSeconds: Int?

    public init(
        name: String,
        kind: ConnectionTransport,
        method: ConnectionMethod,
        path: String,
        idempotent: Bool,
        write: Bool,
        maxAgeSeconds: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.method = method
        self.path = path
        self.idempotent = idempotent
        self.write = write
        self.maxAgeSeconds = maxAgeSeconds
    }
}

/// Trusted Mac-side grant. Secrets stay in the credential store, never here.
public struct ConnectionGrant: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var id: UUID
    public var alias: String
    public var origin: String
    public var transport: ConnectionTransport
    public var authRef: String
    public var lan: Bool
    public var allowInsecureHTTP: Bool
    public var operations: [ConnectionOperation]

    public init(
        schemaVersion: Int,
        id: UUID,
        alias: String,
        origin: String,
        transport: ConnectionTransport,
        authRef: String,
        lan: Bool,
        allowInsecureHTTP: Bool,
        operations: [ConnectionOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.alias = alias
        self.origin = origin
        self.transport = transport
        self.authRef = authRef
        self.lan = lan
        self.allowInsecureHTTP = allowInsecureHTTP
        self.operations = operations
    }
}

public enum ConnectionAuthPlacement: String, Sendable, Codable, Equatable {
    case none
    case bearer
    case header
    case query
}

/// Trusted host metadata describing how to apply a Keychain secret. Not a secret.
public struct ConnectionAuthBinding: Sendable, Codable, Equatable {
    public var authRef: String
    public var placement: ConnectionAuthPlacement
    public var fieldName: String?

    public init(authRef: String, placement: ConnectionAuthPlacement, fieldName: String? = nil) {
        self.authRef = authRef
        self.placement = placement
        self.fieldName = fieldName
    }
}

public enum ConnectionBounds {
    public static let parameterBytes = 8 * 1024
    public static let httpTimeoutSeconds = RuntimeBounds.httpTimeoutSeconds
    public static let httpResponseBytes = RuntimeBounds.httpResponseBytes
    public static let websocketMessageBytes = RuntimeBounds.websocketMessageBytes
    public static let backoffCapSeconds = RuntimeBounds.backoffCapSeconds
}

public enum ConnectionFailure: String, Error, Sendable, Equatable {
    case validationFailed = "validation_failed"
    case permissionRequired = "permission_required"
    case deniedEgress = "denied_egress"
    case sizeLimit = "size_limit"
    case timeout
    case deviceOffline = "device_offline"
}

public enum ConnectionGrantValidator {
    public static func validate(_ grant: ConnectionGrant) throws {
        if grant.schemaVersion != 1 {
            throw ConnectionFailure.validationFailed
        }
        if !isAlias(grant.alias) {
            throw ConnectionFailure.validationFailed
        }
        if !isOrigin(grant.origin) {
            throw ConnectionFailure.validationFailed
        }
        if !isAuthRef(grant.authRef) {
            throw ConnectionFailure.validationFailed
        }
        if looksLikeSecret(grant.authRef) || looksLikeSecret(grant.origin) {
            throw ConnectionFailure.validationFailed
        }
        if grant.operations.isEmpty || grant.operations.count > 32 {
            throw ConnectionFailure.validationFailed
        }
        var names = Set<String>()
        for operation in grant.operations {
            if operation.name.isEmpty || operation.name.count > 64 || names.contains(operation.name) {
                throw ConnectionFailure.validationFailed
            }
            names.insert(operation.name)
            if operation.kind != grant.transport {
                throw ConnectionFailure.validationFailed
            }
            if !isPath(operation.path) {
                throw ConnectionFailure.validationFailed
            }
            if looksLikeSecret(operation.path) || looksLikeSecret(operation.name) {
                throw ConnectionFailure.validationFailed
            }
        }
    }

    public static func decode(_ data: Data) throws -> ConnectionGrant {
        let grant = try JSONDecoder().decode(ConnectionGrant.self, from: data)
        try validate(grant)
        return grant
    }

    private static func isAlias(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter else { return false }
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func isAuthRef(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        if value.lowercased().hasPrefix("bearer ") { return false }
        return value.unicodeScalars.contains(where { $0 == " " || $0 == "\n" || $0 == "\t" }) == false
    }

    private static func isOrigin(_ value: String) -> Bool {
        let prefix: String
        if value.hasPrefix("https://") {
            prefix = "https://"
        } else if value.hasPrefix("http://") {
            prefix = "http://"
        } else {
            return false
        }
        let rest = String(value.dropFirst(prefix.count))
        guard rest.isEmpty == false, rest.contains("/") == false, rest.contains("@") == false else {
            return false
        }
        return rest.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
        }
    }

    private static func isPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._~:/?#[]@!$&'()*+,;=%-")
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func looksLikeSecret(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.hasPrefix("bearer ") { return true }
        if lower.contains("sk-") { return true }
        if lower.contains("password=") || lower.contains("token=") { return true }
        return false
    }
}
