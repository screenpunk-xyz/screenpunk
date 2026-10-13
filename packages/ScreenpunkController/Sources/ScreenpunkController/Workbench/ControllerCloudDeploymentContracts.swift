import Foundation
#if os(macOS)
/// Lossless JSON preserves reviewed server fields when submitting the exact plan.
public enum ControllerCloudJSON: Codable, Sendable, Equatable {
    case object([String: ControllerCloudJSON]), array([ControllerCloudJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int64.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([ControllerCloudJSON].self) { self = .array(result) }
        else { self = .object(try value.decode([String: ControllerCloudJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .integer(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }
    public var prettyPrinted: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
public struct ControllerCloudDeploymentReview: Codable, Sendable, Equatable, Identifiable {
    public var id: String { operationId }
    public let schemaVersion: Int
    public let publicationId: String
    public let installationId: String
    public let operationId: String
    public let removeEntryIds: [String]
    public let expectedGenerationId: String
    public let resultingSet: ControllerCloudJSON
    public let resultingSetDigest: String
    public func validate() throws {
        guard schemaVersion == 1,
              [publicationId, installationId, operationId].allSatisfy({ UUID(uuidString: $0) != nil }),
              !expectedGenerationId.isEmpty, !resultingSetDigest.isEmpty,
              removeEntryIds.count <= 2_000 else { throw ControllerCloudError.invalidResponse }
    }
    public var summary: String {
        "Installation: \(installationId)\nPublication: \(publicationId)\nOperation: \(operationId)\nReviewed generation: \(expectedGenerationId)\nExplicit removals: \(removeEntryIds.count)\n\(resultingSet.prettyPrinted)"
    }
}
#endif
