import Foundation

/// A daily wall-clock schedule in the device's current time zone. A skipped hour
/// takes the latest level at the first existing minute after the gap. A repeated
/// hour repeats its levels. Travel and manual clock changes take effect at once.
public enum DeviceBrightnessSchedule {
    public static func level(for settings: DeviceBrightnessSettings, at date: Date,
                             calendar: Calendar = .autoupdatingCurrent) -> Double? {
        switch settings.mode {
        case .system: return nil
        case .fixed: return validLevel(settings.fixedLevel) ? settings.fixedLevel : nil
        case .schedule:
            let entries = settings.schedule
            guard !entries.isEmpty,
                  entries.allSatisfy({ (0..<1440).contains($0.minuteOfDay) && validLevel($0.level) }),
                  Set(entries.map(\.minuteOfDay)).count == entries.count else { return nil }
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let sorted = entries.sorted { $0.minuteOfDay < $1.minuteOfDay }
            return (sorted.last { $0.minuteOfDay <= minute } ?? sorted.last)?.level
        }
    }

    /// At most one foreground wake per minute, aligned to the local clock. Using
    /// actual calendar intervals handles both occurrences of a repeated minute.
    public static func nextEvaluation(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.end ?? date.addingTimeInterval(60)
    }

    private static func validLevel(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
}

@MainActor
public protocol DeviceBrightnessDisplay: AnyObject {
    var brightness: Double { get set }
}

/// Testable ownership of the foreground brightness override. Never changes the
/// OS Auto-Brightness preference. Release restores the level captured on entry.
@MainActor
public final class DeviceBrightnessSession {
    public private(set) var settings = DeviceBrightnessSettings()
    public private(set) var isActive = false
    public private(set) var isApplied = false
    private let display: any DeviceBrightnessDisplay
    private var previousBrightness: Double?
    private var observedBrightness: Double?
    private var isWriting = false
    private let tolerance = 0.005

    public init(display: any DeviceBrightnessDisplay) { self.display = display }

    public func update(settings: DeviceBrightnessSettings, at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.settings = settings
        refresh(at: date, calendar: calendar)
    }

    public func setActive(_ active: Bool, at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        isActive = active
        refresh(at: date, calendar: calendar)
    }

    public func refresh(at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        guard isActive else { release(); isApplied = false; return }
        guard let level = DeviceBrightnessSchedule.level(for: settings, at: date, calendar: calendar) else {
            release()
            isApplied = settings.mode == .system
            return
        }
        if previousBrightness == nil { previousBrightness = display.brightness }
        if abs(display.brightness - level) > tolerance { write(level) }
        observedBrightness = display.brightness
        isApplied = abs(display.brightness - level) <= tolerance
    }

    /// Suppress our own synchronous/async notifications, including a platform
    /// that clamps the requested value. An actual external change is reapplied.
    public func displayBrightnessDidChange(at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        guard isActive, !isWriting else { return }
        if let observedBrightness, abs(display.brightness - observedBrightness) <= tolerance { return }
        refresh(at: date, calendar: calendar)
    }

    private func release() {
        // Clear ownership before writing so a synchronous notification cannot
        // recapture our own override as the next baseline.
        let previous = previousBrightness
        previousBrightness = nil
        if let previous, abs(display.brightness - previous) > tolerance { write(previous) }
        observedBrightness = display.brightness
    }

    private func write(_ value: Double) {
        isWriting = true
        display.brightness = value
        isWriting = false
    }
}
