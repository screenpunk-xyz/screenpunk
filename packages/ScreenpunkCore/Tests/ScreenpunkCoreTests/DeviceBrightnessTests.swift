import XCTest
@testable import ScreenpunkCore

final class DeviceBrightnessTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private var schedule: DeviceBrightnessSettings {
        .init(mode: .schedule, schedule: [.init(minuteOfDay: 7 * 60, level: 0.8), .init(minuteOfDay: 22 * 60, level: 0.2)])
    }

    func testMidnightWrapAndExactBoundaryWithUnsortedEntries() {
        for (time, expected) in [("00:00", 0.2), ("06:59", 0.2), ("07:00", 0.8), ("21:59", 0.8), ("22:00", 0.2)] {
            XCTAssertEqual(DeviceBrightnessSchedule.level(for: schedule, at: date("2026-09-19T\(time):00Z"), calendar: calendar()), expected)
        }
        var reversed = schedule
        reversed.schedule.reverse()
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: reversed, at: date("2026-09-19T08:00:00Z"), calendar: calendar()), 0.8)
    }

    func testInvalidScheduleDoesNotWriteBrightness() {
        let now = date("2026-09-19T12:00:00Z")
        for invalid in [DeviceBrightnessSettings(mode: .schedule),
                        .init(mode: .schedule, schedule: [.init(minuteOfDay: -1, level: 0.2)]),
                        .init(mode: .schedule, schedule: [.init(minuteOfDay: 1440, level: 0.2)]),
                        .init(mode: .schedule, schedule: [.init(minuteOfDay: 0, level: 2)]),
                        .init(mode: .schedule, schedule: [.init(minuteOfDay: 0, level: 0.2), .init(minuteOfDay: 0, level: 0.8)]),
                        .init(mode: .fixed, fixedLevel: .nan)] {
            XCTAssertNil(DeviceBrightnessSchedule.level(for: invalid, at: now, calendar: calendar()))
        }
    }

    func testSpringGapTakesLastCrossedLevelAndFallHourRepeats() {
        let zone = calendar("America/New_York")
        let spring = DeviceBrightnessSettings(mode: .schedule, schedule: [.init(minuteOfDay: 0, level: 0.1), .init(minuteOfDay: 150, level: 0.7)])
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: spring, at: date("2026-03-08T06:59:00Z"), calendar: zone), 0.1)
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: spring, at: date("2026-03-08T07:00:00Z"), calendar: zone), 0.7)
        let fall = DeviceBrightnessSettings(mode: .schedule, schedule: [.init(minuteOfDay: 0, level: 0.1), .init(minuteOfDay: 90, level: 0.7)])
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: fall, at: date("2026-11-01T05:30:00Z"), calendar: zone), 0.7)
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: fall, at: date("2026-11-01T06:00:00Z"), calendar: zone), 0.1)
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: fall, at: date("2026-11-01T06:30:00Z"), calendar: zone), 0.7)
        XCTAssertEqual(DeviceBrightnessSchedule.nextEvaluation(after: date("2026-11-01T05:59:59Z"), calendar: zone), date("2026-11-01T06:00:00Z"))
    }

    func testTimeZoneChangeUsesNewLocalClock() {
        let now = date("2026-09-19T10:00:00Z")
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: schedule, at: now, calendar: calendar("Europe/London")), 0.8)
        XCTAssertEqual(DeviceBrightnessSchedule.level(for: schedule, at: now, calendar: calendar("America/Los_Angeles")), 0.2)
    }

    @MainActor func testActivationAppliesCurrentScheduleAndBackgroundRestoresFreshBaseline() async {
        let display = FakeBrightnessDisplay(0.6)
        let session = DeviceBrightnessSession(display: display)
        let morning = date("2026-09-19T08:00:00Z")
        session.update(settings: schedule, at: morning, calendar: calendar())
        XCTAssertEqual(display.brightness, 0.6)
        session.setActive(true, at: morning, calendar: calendar())
        XCTAssertEqual(display.brightness, 0.8)
        XCTAssertTrue(session.isApplied)
        session.setActive(false, at: morning, calendar: calendar())
        XCTAssertEqual(display.brightness, 0.6)
        XCTAssertFalse(session.isApplied)
        display.brightness = 0.4 // user/OS adjustment while Screenpunk is inactive
        session.setActive(true, at: date("2026-09-19T23:00:00Z"), calendar: calendar())
        XCTAssertEqual(display.brightness, 0.2)
        session.setActive(false, at: morning, calendar: calendar())
        XCTAssertEqual(display.brightness, 0.4)
    }

    @MainActor func testFixedModeReappliesExternalChangesAndSystemModeReleases() async {
        let display = FakeBrightnessDisplay(0.6)
        let session = DeviceBrightnessSession(display: display)
        let now = date("2026-09-19T08:00:00Z")
        session.update(settings: .init(mode: .fixed, fixedLevel: 0.9), at: now)
        session.setActive(true, at: now)
        let writes = display.writes
        session.displayBrightnessDidChange(at: now) // own delayed notification
        XCTAssertEqual(display.writes, writes)
        display.brightness = 0.3
        session.displayBrightnessDidChange(at: now)
        XCTAssertEqual(display.brightness, 0.9)
        session.update(settings: .init(), at: now)
        XCTAssertEqual(display.brightness, 0.6)
        display.brightness = 0.7
        session.displayBrightnessDidChange(at: now)
        XCTAssertEqual(display.brightness, 0.7)
        XCTAssertTrue(session.isApplied)
    }

    @MainActor func testClampedPlatformWriteIsNotClaimedAppliedAndDoesNotFeedback() async {
        let display = FakeBrightnessDisplay(0.5)
        display.maximum = 0.7
        let session = DeviceBrightnessSession(display: display)
        let now = date("2026-09-19T08:00:00Z")
        display.didWrite = { session.displayBrightnessDidChange(at: now) }
        session.update(settings: .init(mode: .fixed, fixedLevel: 0.9), at: now)
        session.setActive(true, at: now)
        XCTAssertFalse(session.isApplied)
        XCTAssertEqual(display.brightness, 0.7)
        let writes = display.writes
        for _ in 0..<10 { session.displayBrightnessDidChange(at: now) }
        XCTAssertEqual(display.writes, writes)
        session.setActive(false, at: now)
        XCTAssertEqual(display.brightness, 0.5)
    }

    @MainActor func testClockChangeAndSettingsEditPreserveOriginalBaseline() async {
        let display = FakeBrightnessDisplay(0.6)
        let session = DeviceBrightnessSession(display: display)
        let now = date("2026-09-19T08:00:00Z")
        session.update(settings: schedule, at: now, calendar: calendar())
        session.setActive(true, at: now, calendar: calendar())
        session.refresh(at: date("2026-09-19T23:00:00Z"), calendar: calendar())
        XCTAssertEqual(display.brightness, 0.2)
        session.update(settings: .init(mode: .fixed, fixedLevel: 0.4), at: now)
        XCTAssertEqual(display.brightness, 0.4)
        session.setActive(false, at: now)
        XCTAssertEqual(display.brightness, 0.6)
    }
}

@MainActor
private final class FakeBrightnessDisplay: DeviceBrightnessDisplay {
    private var value: Double
    var maximum = 1.0
    var writes = 0
    var didWrite: (() -> Void)?
    init(_ value: Double) { self.value = value }
    var brightness: Double {
        get { value }
        set { value = min(maximum, newValue); writes += 1; didWrite?() }
    }
}
