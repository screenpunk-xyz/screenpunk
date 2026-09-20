import Foundation

public enum EventNavigationError: Error, Equatable { case invalidConfiguration }

/// A deterministic state machine. The host owns transport and timer scheduling; all deadlines
/// are tagged with generation so obsolete callbacks cannot change a newer or manual page.
public struct EventNavigationEngine: Sendable {
    public private(set) var pageId: String
    public private(set) var activeRuleId: String?
    public private(set) var returnAt: Date?
    public private(set) var generation: UInt64 = 0
    private var pages: Set<String>
    private var rules: [String: ManifestEventRule]
    private var defaults: [String: EventRuleDefaults]
    private var conditions: [String: Bool] = [:]
    private var deduplicated: [String] = []
    private var previousPageId: String?
    private var activeCorrelationId: String?
    private var activeBehavior: EventReturnBehavior?

    public init(manifest: DashboardManifest, startingPageId: String? = nil,
                overrides: [String: EventRuleDefaults] = [:]) throws {
        try Self.validate(manifest: manifest, startingPageId: startingPageId, overrides: overrides)
        self.pages = Set(manifest.resolvedPages.map(\.id))
        self.rules = Dictionary(uniqueKeysWithValues: (manifest.eventRules ?? []).map { ($0.id, $0) })
        self.defaults = Dictionary(uniqueKeysWithValues: (manifest.eventRules ?? []).map { ($0.id, overrides[$0.id] ?? $0.defaults) })
        self.pageId = startingPageId ?? manifest.resolvedDefaultPageId
    }

    public static func validate(manifest: DashboardManifest, startingPageId: String? = nil,
                                overrides: [String: EventRuleDefaults] = [:]) throws {
        try validateManifest(manifest)
        let pages = Set(manifest.resolvedPages.map(\.id))
        guard pages.contains(startingPageId ?? manifest.resolvedDefaultPageId) else { throw EventNavigationError.invalidConfiguration }
        for (id, value) in overrides {
            guard let rule = manifest.eventRules?.first(where: { $0.id == id }), rule.userConfigurable,
                  pages.contains(value.pageId), ([rule.defaults.pageId] + rule.allowedPageIds).contains(value.pageId),
                  ([rule.defaults.returnBehavior] + rule.allowedReturnBehaviors).contains(value.returnBehavior),
                  (1...3600).contains(value.timeoutSeconds),
                  (rule.allowTimeoutOverride || value.timeoutSeconds == rule.defaults.timeoutSeconds),
                  (value.returnBehavior != .conditionClear || rule.condition != nil),
                  (!value.allowPayloadOverrides || rule.defaults.allowPayloadOverrides) else { throw EventNavigationError.invalidConfiguration }
        }
    }

    public static func validateManifest(_ manifest: DashboardManifest) throws {
        let pages = manifest.resolvedPages
        let pageIds = Set(pages.map(\.id))
        let files = Set(manifest.files.map(\.path))
        func validId(_ s: String) -> Bool { !s.isEmpty && s.count <= 128 && s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }
        func validPath(_ path: [String]) -> Bool { !path.isEmpty && path.count <= 16 && path.allSatisfy { !$0.isEmpty && $0.count <= 128 && !["__proto__", "constructor", "prototype"].contains($0) } }
        guard !pages.isEmpty, pages.count <= 64, pages.count == pageIds.count, pageIds.contains(manifest.resolvedDefaultPageId),
              pages.allSatisfy({ validId($0.id) && !$0.name.isEmpty && $0.name.count <= 128 && files.contains($0.path) && $0.path.hasSuffix(".html") && (try? PackagePath.normalize($0.path)) != nil }) else { throw EventNavigationError.invalidConfiguration }
        let rules = manifest.eventRules ?? []
        guard rules.count <= 64, Set(rules.map(\.id)).count == rules.count else { throw EventNavigationError.invalidConfiguration }
        for rule in rules {
            guard validId(rule.id), !rule.name.isEmpty, rule.name.count <= 128, (-100...100).contains(rule.priority),
                  pageIds.contains(rule.defaults.pageId), rule.allowedPageIds.allSatisfy(pageIds.contains),
                  Set(rule.allowedPageIds).count == rule.allowedPageIds.count,
                  Set(rule.allowedReturnBehaviors.map(\.rawValue)).count == rule.allowedReturnBehaviors.count,
                  (1...3600).contains(rule.defaults.timeoutSeconds),
                  (rule.defaults.returnBehavior != .conditionClear && !rule.allowedReturnBehaviors.contains(.conditionClear)) || rule.condition != nil,
                  let connection = manifest.connections.first(where: { $0.alias == rule.source.alias }),
                  let operation = connection.operations?.first(where: { $0.name == rule.source.operation }),
                  operation.kind == (rule.source.mode == .live ? "ws" : "http"),
                  rule.source.parameters.count <= 32,
                  rule.source.parameters.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 128 && !["authorization", "x-api-key", "token", "password"].contains($0.key.lowercased()) }),
                  rule.source.mode != .poll || (rule.condition != nil && (15...86400).contains(rule.source.pollIntervalSeconds ?? 30)),
                  rule.condition != nil || rule.payload?.occurredAt != nil
            else { throw EventNavigationError.invalidConfiguration }
            if let refresh = rule.source.refreshOperation,
               manifest.connections.first(where: { $0.alias == (rule.source.refreshAlias ?? rule.source.alias) })?.operations?.contains(where: { $0.name == refresh && $0.kind == "http" }) != true { throw EventNavigationError.invalidConfiguration }
            for c in [rule.filter, rule.condition].compactMap({ $0 }) { guard validPath(c.field) else { throw EventNavigationError.invalidConfiguration } }
            if let p = rule.payload {
                for path in [p.pageId, p.returnBehavior, p.timeoutSeconds, p.eventId, p.correlationId, p.occurredAt].compactMap({ $0 }) {
                    guard validPath(path) else { throw EventNavigationError.invalidConfiguration }
                }
            }
        }
    }

    @discardableResult public mutating func manualNavigate(pageId: String) -> Bool {
        guard pages.contains(pageId) else { return false }
        let changed = self.pageId != pageId
        self.pageId = pageId
        cancelReturn()
        return changed
    }

    @discardableResult public mutating func receive(ruleId: String, payload: [String: Any], now: Date, isBaseline: Bool = false, notBefore: Date? = nil) -> Bool {
        guard let rule = rules[ruleId], var selected = defaults[ruleId], selected.enabled else { return false }
        if let filter = rule.filter, filter.evaluate(payload) != true { return false }
        func field(_ path: [String]?) -> Any? { path.flatMap { EventPayloadFields.value(at: $0, in: payload) } }
        if rule.condition == nil, let notBefore {
            let raw = field(rule.payload?.occurredAt)
            let timestamp: Date?
            if let raw, case .number(let seconds)? = EventScalar.from(raw), seconds.isFinite {
                timestamp = Date(timeIntervalSince1970: seconds)
            } else if let text = raw as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                timestamp = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            } else { timestamp = nil }
            guard let timestamp, timestamp >= notBefore, timestamp <= now.addingTimeInterval(5) else { return false }
        }
        let correlation = field(rule.payload?.correlationId) as? String
        if let correlation, correlation.isEmpty || correlation.count > 256 { return false }
        // A configured correlation must actually be present; do not let an unrelated clear match nil.
        if rule.payload?.correlationId != nil && correlation == nil { return false }
        if let eventId = field(rule.payload?.eventId) as? String {
            guard !eventId.isEmpty, eventId.count <= 256 else { return false }
            let id = ruleId + "\u{1f}" + eventId
            if deduplicated.contains(id) { return false }
            deduplicated.append(id)
            if deduplicated.count > 256 { deduplicated.removeFirst(deduplicated.count - 256) }
        }
        let key = ruleId + "\u{1f}" + (correlation ?? "")
        let previousCondition = conditions[key]
        if let condition = rule.condition {
            guard let active = condition.evaluate(payload) else { return false }
            conditions[key] = active
            if conditions.count > 256 { conditions = [key: active] }
            if !active {
                if activeRuleId == ruleId, activeBehavior == .conditionClear, activeCorrelationId == correlation { return restore() }
                return false
            }
            if isBaseline || previousCondition == true { return false }
        } else if isBaseline { return false }
        if let current = activeRuleId, let activeRule = rules[current], rule.priority < activeRule.priority { return false }
        if selected.allowPayloadOverrides {
            if let value = field(rule.payload?.pageId) as? String, pages.contains(value),
               ([rule.defaults.pageId] + rule.allowedPageIds).contains(value) { selected.pageId = value }
            if let value = field(rule.payload?.returnBehavior) as? String, let behavior = EventReturnBehavior(rawValue: value),
               ([rule.defaults.returnBehavior] + rule.allowedReturnBehaviors).contains(behavior),
               behavior != .conditionClear || rule.condition != nil { selected.returnBehavior = behavior }
            if rule.allowTimeoutOverride, let raw = field(rule.payload?.timeoutSeconds), case .number(let value)? = EventScalar.from(raw),
               value.isFinite, value.rounded() == value, (1...3600).contains(value) { selected.timeoutSeconds = Int(value) }
        }
        if activeRuleId == nil { previousPageId = pageId }
        let changed = pageId != selected.pageId
        pageId = selected.pageId
        activeRuleId = ruleId; activeCorrelationId = correlation; activeBehavior = selected.returnBehavior
        generation &+= 1
        returnAt = selected.returnBehavior == .timeout ? now.addingTimeInterval(Double(selected.timeoutSeconds)) : nil
        return changed
    }

    @discardableResult public mutating func advance(now: Date, generation expected: UInt64? = nil) -> Bool {
        guard expected == nil || expected == generation, let deadline = returnAt, now >= deadline else { return false }
        return restore()
    }

    private mutating func restore() -> Bool {
        let previous = previousPageId ?? pageId
        let changed = pageId != previous
        pageId = previous
        cancelReturn()
        return changed
    }
    private mutating func cancelReturn() {
        generation &+= 1; activeRuleId = nil; returnAt = nil; previousPageId = nil
        activeCorrelationId = nil; activeBehavior = nil
    }
}
