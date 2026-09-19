import Foundation
import CoreFoundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try from(json)
    }

    public func jsonObject() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.jsonObject() }
        case .object(let values): return values.mapValues { $0.jsonObject() }
        }
    }

    public func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(), options: [.sortedKeys])
    }

    public static func from(_ any: Any) throws -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        // Foundation numbers 0 and 1 also cast to Bool. Inspect NSNumber's
        // actual CF type before any permissive Swift scalar cast.
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if floor(value.doubleValue) == value.doubleValue {
                return .int(value.intValue)
            }
            return .double(value.doubleValue)
        case let value as Double:
            return .double(value)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(try value.map { try from($0) })
        case let value as [String: Any]:
            return .object(try value.mapValues { try from($0) })
        default:
            throw ControllerError.validationFailed(detail: "unsupported JSON value")
        }
    }
}
