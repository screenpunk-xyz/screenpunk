import Foundation
import CoreFoundation

/// Pages are packaged documents inside one installed dashboard, never saved dashboards.
public struct DashboardPage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public init(id: String, name: String, path: String) { self.id = id; self.name = name; self.path = path }
}

public enum EventReturnBehavior: String, Codable, Sendable, Equatable, CaseIterable {
    case stay, timeout, conditionClear
}

public enum EventScalar: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let x): try c.encode(x); case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x); case .null: try c.encodeNil() }
    }
    public var foundationValue: Any {
        switch self { case .string(let x): return x; case .number(let x): return x
        case .bool(let x): return x; case .null: return NSNull() }
    }
    public static func from(_ value: Any) -> EventScalar? {
        // JSONSerialization represents both booleans and numbers with NSNumber.
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        if let value = value as? String { return .string(value) }
        if value is NSNull { return .null }
        return nil
    }
}

/// Exact scalar equality on an object-key path. No expressions, scripts or wildcard evaluation.
public struct EventCondition: Codable, Sendable, Equatable {
    public var field: [String]
    public var equals: EventScalar
    public init(field: [String], equals: EventScalar) { self.field = field; self.equals = equals }
    public func evaluate(_ payload: [String: Any]) -> Bool? {
        guard let value = EventPayloadFields.value(at: field, in: payload), let scalar = EventScalar.from(value) else { return nil }
        return scalar == equals
    }
}

public struct EventPayloadFields: Codable, Sendable, Equatable {
    public var pageId: [String]?
    public var returnBehavior: [String]?
    public var timeoutSeconds: [String]?
    public var occurredAt: [String]?
    public var eventId: [String]?
    public var correlationId: [String]?
    public init(pageId: [String]? = nil, returnBehavior: [String]? = nil, timeoutSeconds: [String]? = nil,
                eventId: [String]? = nil, correlationId: [String]? = nil, occurredAt: [String]? = nil) {
        self.pageId = pageId; self.returnBehavior = returnBehavior; self.timeoutSeconds = timeoutSeconds
        self.eventId = eventId; self.correlationId = correlationId; self.occurredAt = occurredAt
    }
    public static func value(at path: [String], in payload: [String: Any]) -> Any? {
        guard !path.isEmpty, path.count <= 16 else { return nil }
        var value: Any = payload
        for key in path { guard let next = (value as? [String: Any])?[key] else { return nil }; value = next }
        return value
    }
}

public struct EventRuleDefaults: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var pageId: String
    public var returnBehavior: EventReturnBehavior
    public var timeoutSeconds: Int
    public var allowPayloadOverrides: Bool
    public init(enabled: Bool = true, pageId: String, returnBehavior: EventReturnBehavior = .stay,
                timeoutSeconds: Int = 30, allowPayloadOverrides: Bool = true) {
        self.enabled = enabled; self.pageId = pageId; self.returnBehavior = returnBehavior
        self.timeoutSeconds = timeoutSeconds; self.allowPayloadOverrides = allowPayloadOverrides
    }
}

public struct EventSource: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case live, poll }
    public var mode: Mode
    public var alias: String
    public var operation: String
    public var parameters: [String: EventScalar]
    public var pollIntervalSeconds: Int?
    /// Optional approved HTTP read used to establish current condition after reconnect.
    public var refreshOperation: String?
    public var refreshAlias: String?
    public init(mode: Mode, alias: String, operation: String, parameters: [String: EventScalar] = [:],
                pollIntervalSeconds: Int? = nil, refreshOperation: String? = nil, refreshAlias: String? = nil) {
        self.mode = mode; self.alias = alias; self.operation = operation; self.parameters = parameters
        self.pollIntervalSeconds = pollIntervalSeconds; self.refreshOperation = refreshOperation; self.refreshAlias = refreshAlias
    }
}

public struct ManifestEventRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var source: EventSource
    /// Restrict a shared subscription to this subject (for example event.entity_id).
    public var filter: EventCondition?
    /// Required for polling and return-on-clear. Missing data is not a clear signal.
    public var condition: EventCondition?
    public var defaults: EventRuleDefaults
    public var priority: Int
    public var userConfigurable: Bool
    public var allowedPageIds: [String]
    public var allowedReturnBehaviors: [EventReturnBehavior]
    public var allowTimeoutOverride: Bool
    public var payload: EventPayloadFields?
    public init(id: String, name: String, source: EventSource, filter: EventCondition? = nil,
                condition: EventCondition? = nil, defaults: EventRuleDefaults, priority: Int = 0,
                userConfigurable: Bool = false, allowedPageIds: [String] = [],
                allowedReturnBehaviors: [EventReturnBehavior] = [], allowTimeoutOverride: Bool = false,
                payload: EventPayloadFields? = nil) {
        self.id = id; self.name = name; self.source = source; self.filter = filter; self.condition = condition
        self.defaults = defaults; self.priority = priority; self.userConfigurable = userConfigurable
        self.allowedPageIds = allowedPageIds; self.allowedReturnBehaviors = allowedReturnBehaviors
        self.allowTimeoutOverride = allowTimeoutOverride; self.payload = payload
    }
}

public extension DashboardManifest {
    var resolvedPages: [DashboardPage] { pages ?? [DashboardPage(id: "default", name: name, path: entrypoint)] }
    var resolvedDefaultPageId: String { defaultPageId ?? resolvedPages.first?.id ?? "default" }
}
