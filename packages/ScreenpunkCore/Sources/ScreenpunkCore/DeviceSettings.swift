import Foundation

public enum DeviceBrightnessMode: String, Codable, CaseIterable, Sendable {
    case system, fixed, schedule
}

/// Schedule times are wall-clock minutes in the device's current local time zone.
public struct DeviceBrightnessScheduleEntry: Codable, Equatable, Sendable {
    public var minuteOfDay: Int
    public var level: Double
    public init(minuteOfDay: Int, level: Double) {
        self.minuteOfDay = minuteOfDay
        self.level = level
    }
}

public struct DeviceBrightnessSettings: Codable, Equatable, Sendable {
    public var mode: DeviceBrightnessMode
    public var fixedLevel: Double
    public var schedule: [DeviceBrightnessScheduleEntry]
    public init(mode: DeviceBrightnessMode = .system, fixedLevel: Double = 0.5,
                schedule: [DeviceBrightnessScheduleEntry] = []) {
        self.mode = mode; self.fixedLevel = fixedLevel; self.schedule = schedule
    }
    public func validate() throws {
        guard fixedLevel.isFinite, (0...1).contains(fixedLevel), schedule.count <= 48,
              Set(schedule.map(\.minuteOfDay)).count == schedule.count,
              schedule.allSatisfy({ (0..<1440).contains($0.minuteOfDay) && $0.level.isFinite && (0...1).contains($0.level) }),
              mode != .schedule || !schedule.isEmpty else { throw DeviceSettingsFailure.invalidSettings }
    }
}

/// Device-owned preferences survive dashboard deployments and Mac disconnection.
/// Event overrides are grouped by dashboard, then by author-declared rule ID.
public struct DeviceSettings: Codable, Equatable, Sendable {
    public var displayName: String?
    public var startingPageByDashboard: [String: String]
    public var brightness: DeviceBrightnessSettings
    public var eventRuleOverrides: [String: [String: EventRuleDefaults]]
    public init(displayName: String? = nil, startingPageByDashboard: [String: String] = [:],
                brightness: DeviceBrightnessSettings = .init(),
                eventRuleOverrides: [String: [String: EventRuleDefaults]] = [:]) {
        self.displayName = displayName
        self.startingPageByDashboard = startingPageByDashboard
        self.brightness = brightness
        self.eventRuleOverrides = eventRuleOverrides
    }
    public func validate() throws {
        try brightness.validate()
        if let displayName, DeviceDisplayName.sanitize(displayName) != displayName { throw DeviceSettingsFailure.invalidSettings }
        guard startingPageByDashboard.count <= 128, eventRuleOverrides.count <= 128,
              startingPageByDashboard.allSatisfy({ Self.validID($0.key) && Self.validID($0.value) }),
              eventRuleOverrides.allSatisfy({ Self.validID($0.key) && $0.value.count <= 128 && $0.value.allSatisfy({
                  Self.validID($0.key) && Self.validID($0.value.pageId) && (1...3600).contains($0.value.timeoutSeconds)
              }) }) else { throw DeviceSettingsFailure.invalidSettings }
    }
    private static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }
}

public enum DeviceSettingsFailure: String, Error, Codable, Sendable {
    case conflict = "settings.conflict"
    case invalidSettings = "settings.invalid"
    case persistenceFailed = "settings.persistenceFailed"
}

/// `revision` acknowledges durable configuration. `appliedRevision` is an
/// in-process runtime acknowledgement, cleared on relaunch, not a sensor reading.
public struct DeviceSettingsSnapshot: Codable, Equatable, Sendable {
    public var revision: String
    public var value: DeviceSettings
    public var appliedRevision: String?
    public var isApplied: Bool { appliedRevision == revision }
    public init(revision: String = UUID().uuidString, value: DeviceSettings = .init(), appliedRevision: String? = nil) {
        self.revision = revision; self.value = value; self.appliedRevision = appliedRevision
    }
    public func replacing(with update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        guard update.expectedRevision == revision else { throw DeviceSettingsFailure.conflict }
        try update.value.validate()
        return .init(value: update.value)
    }
}

public struct DeviceSettingsUpdate: Codable, Equatable, Sendable {
    public var expectedRevision: String
    public var value: DeviceSettings
    public init(expectedRevision: String, value: DeviceSettings) {
        self.expectedRevision = expectedRevision; self.value = value
    }
}
