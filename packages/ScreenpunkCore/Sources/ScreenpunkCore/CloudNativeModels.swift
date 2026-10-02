import Foundation

/// Native identity contract accepted at cloud commit 37c83d4560541e64c2dd5df8cd9bd085086d8b8c.
/// Timestamps remain strings to preserve the server's precision.
public enum CloudNativeSignInProvider: String, Codable, Sendable { case google = "google.com", apple = "apple.com" }

public struct CloudNativeUser: Decodable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let email: String?
    private enum CodingKeys: String, CodingKey { case id, displayName, email }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        email = try values.decode(String?.self, forKey: .email)
    }
}

public struct CloudNativeSignInResponse: Decodable, Equatable, Sendable {
    public let user: CloudNativeUser
    public let signInProvider: CloudNativeSignInProvider
    public let authTime: String
    public let tokenExpiresAt: String
}

public struct CloudNativeAccountCapabilities: Decodable, Equatable, Sendable {
    public let owner: Bool
    public let administrator: Bool
    public let canEnroll: Bool
}
public struct CloudNativeAccount: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let createdAt: String
    public let updatedAt: String
    public let capabilities: CloudNativeAccountCapabilities
}
public struct CloudNativeLocationCapabilities: Decodable, Equatable, Sendable {
    public let canView: Bool
    public let canOperate: Bool
    public let canEnroll: Bool
    private enum CodingKeys: String, CodingKey { case canView, canOperate, canEnroll }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        canView = try values.decode(Bool.self, forKey: .canView)
        guard canView else { throw DecodingError.dataCorruptedError(forKey: .canView, in: values, debugDescription: "Visible locations require canView") }
        canOperate = try values.decode(Bool.self, forKey: .canOperate)
        canEnroll = try values.decode(Bool.self, forKey: .canEnroll)
    }
}
public struct CloudNativeLocation: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let createdAt: String
    public let updatedAt: String
    public let capabilities: CloudNativeLocationCapabilities
}

public struct CloudNativePage<Item: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
    private enum CodingKeys: String, CodingKey { case items, nextCursor }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([Item].self, forKey: .items)
        nextCursor = try values.decode(String?.self, forKey: .nextCursor)
        guard items.count <= 200, nextCursor.map({ !$0.isEmpty && $0.count <= 2048 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: values, debugDescription: "Invalid native page bounds")
        }
    }
}

public struct CloudNativeAPIError: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let requestId: String
    /// Canonical optional `details` can be any JSON value.
    public let details: CloudNativeJSONValue?
}

public enum CloudNativeJSONValue: Decodable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([Self]), object([String: Self])
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([Self].self) { self = .array(item) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
}

/// No raw token or transport diagnostic is attached to these errors.
public enum CloudNativeFailure: Error, Equatable, Sendable {
    case invalidBaseURL, invalidPagination, tokenUnavailable, cancelled, transportUnavailable
    case responseTooLarge, invalidResponse, redirectRejected, paginationCycle
    case api(status: Int, error: CloudNativeAPIError)
    case http(status: Int)
}
