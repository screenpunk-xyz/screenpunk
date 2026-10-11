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

/// Exact user-approved inputs for native first-workspace setup. Valid names are never normalized or trimmed.
/// Contract: cloud commit eda8d5091d80a04c448e7a30ec0bb5a5248d97ef.
public struct CloudNativeWorkspaceSetupRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let workspaceName: String
    public let locationName: String
    private enum CodingKeys: String, CodingKey { case requestId, workspaceName, locationName }

    public init(requestId: UUID, workspaceName: String, locationName: String) throws {
        self.requestId = requestId
        self.workspaceName = workspaceName
        self.locationName = locationName
        try validate()
    }
    public static func == (left: Self, right: Self) -> Bool {
        // Swift String equality folds canonically equivalent Unicode; setup retries require exact original names.
        left.requestId == right.requestId && left.workspaceName.utf8.elementsEqual(right.workspaceName.utf8)
            && left.locationName.utf8.elementsEqual(right.locationName.utf8)
    }
    public func validate() throws {
        for name in [workspaceName, locationName] {
            let scalars = name.unicodeScalars
            guard (1...128).contains(scalars.count),
                  scalars.contains(where: { !$0.properties.isWhitespace && $0.value != 0xFEFF }),
                  !scalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw CloudNativeFailure.invalidWorkspaceSetup
            }
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestId: values.decode(UUID.self, forKey: .requestId),
                      workspaceName: values.decode(String.self, forKey: .workspaceName),
                      locationName: values.decode(String.self, forKey: .locationName))
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try values.encode(workspaceName, forKey: .workspaceName)
        try values.encode(locationName, forKey: .locationName)
    }
}

/// This is a setup operation receipt, never enrollment or device-management authority.
public struct CloudNativeWorkspaceSetupReceipt: Codable, Equatable, Sendable {
    /// Saved setup operation UUID; CloudNativeAPIError.requestId is instead an HTTP tracing ID.
    public let requestId: UUID
    public let accountId: UUID
    public let locationId: UUID
    public let createdAt: String
    private enum CodingKeys: String, CodingKey { case requestId, accountId, locationId, createdAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try values.decode(UUID.self, forKey: .requestId)
        accountId = try values.decode(UUID.self, forKey: .accountId)
        locationId = try values.decode(UUID.self, forKey: .locationId)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        do { _ = try boundedRFC3339Time(createdAt, acceptsLowercaseSeparators: true) }
        catch {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: values, debugDescription: "Invalid setup receipt timestamp")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try values.encode(accountId.uuidString.lowercased(), forKey: .accountId)
        try values.encode(locationId.uuidString.lowercased(), forKey: .locationId)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

public struct CloudNativeAccountCapabilities: Decodable, Equatable, Sendable {
    public let owner: Bool
    public let administrator: Bool
    public let canEnroll: Bool
    public var canEnrollUnassigned: Bool { canEnroll && (owner || administrator) }
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
    /// HTTP tracing ID, distinct from a workspace setup operation UUID.
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
    case invalidWorkspaceSetup, requestTooLarge, workspaceSetupReceiptMismatch
    case api(status: Int, error: CloudNativeAPIError)
    case http(status: Int)
}
