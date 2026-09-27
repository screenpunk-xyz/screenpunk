import Foundation

/// Device-level, state-driven navigation. No service calls or credentials.
public struct RedAlertNavigation: Codable, Equatable, Sendable {
    public static let entityId = "sensor.screenpunk_red_alert"
    public var alertId: String?
    public var expiresAt: Date?
    public var startedAt: Date?
    public var previousScreen: String?
    public var targetScreen: String?
    public var dismissed = false
    public init() {}

    /// Returning a selection is a proposal: callers persist this value before selecting.
    public mutating func receive(state: [String: Any], target: String, selected: String, now: Date) -> String? {
        guard state["entity_id"] as? String == Self.entityId,
              let attributes = state["attributes"] as? [String: Any],
              let id = attributes["alert_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return nil }
        if state["state"] as? String == "off" {
            guard id == alertId else { return nil }
            return finish(selected: selected)
        }
        guard state["state"] as? String == "on",
              let start = Self.date(attributes["started_at"]), let end = Self.date(attributes["expires_at"]),
              start <= now.addingTimeInterval(5), end > start, end.timeIntervalSince(start) <= 300,
              end > now else { return expire(selected: selected, now: now) }
        if id == alertId { return nil } // Repeated starts never extend the deadline or undo a manual dismissal.
        if let startedAt, start <= startedAt { return nil }
        let prior = previousScreen ?? selected
        alertId = id; startedAt = start; expiresAt = end; previousScreen = prior; targetScreen = target; dismissed = false
        return selected == target ? nil : target
    }

    public mutating func expire(selected: String, now: Date) -> String? {
        guard let expiresAt, now >= expiresAt else { return nil }
        return finish(selected: selected)
    }

    public mutating func manualSelection() { dismissed = true; previousScreen = nil }

    private mutating func finish(selected: String) -> String? {
        let restore = !dismissed && selected == targetScreen ? previousScreen : nil
        // Retain the ID/deadline as a tombstone, so a stale reconnect cannot restart it.
        dismissed = true; previousScreen = nil
        return restore == selected ? nil : restore
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
