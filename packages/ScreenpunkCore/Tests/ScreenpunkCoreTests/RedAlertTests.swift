import XCTest
@testable import ScreenpunkCore

final class RedAlertTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1800000000)
    func state(_ id: String = "run-1", _ active: Bool = true, start: TimeInterval = 0, duration: TimeInterval = 300) -> [String: Any] {
        ["entity_id": RedAlertNavigation.entityId, "state": active ? "on" : "off", "attributes": ["alert_id": id,
            "started_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(start)),
            "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(start + duration))]]
    }
    func testSnapshotJoinsActiveAndMatchingClearRestores() {
        var engine = RedAlertNavigation()
        XCTAssertEqual(engine.receive(state: state(), target: "red", selected: "weather", now: now.addingTimeInterval(100)), "red")
        XCTAssertNil(engine.receive(state: state("older", false), target: "red", selected: "red", now: now))
        XCTAssertEqual(engine.receive(state: state("run-1", false), target: "red", selected: "red", now: now), "weather")
        XCTAssertNil(engine.receive(state: state(), target: "red", selected: "weather", now: now))
    }
    func testOverlappingRunPreservesOriginalAndRejectsOldReplay() {
        var engine = RedAlertNavigation()
        _ = engine.receive(state: state(), target: "red", selected: "weather", now: now)
        XCTAssertNil(engine.receive(state: state("run-2", start: 30), target: "red", selected: "red", now: now.addingTimeInterval(30)))
        XCTAssertNil(engine.receive(state: state(), target: "red", selected: "red", now: now.addingTimeInterval(31)))
        XCTAssertNil(engine.expire(selected: "red", now: now.addingTimeInterval(300)))
        XCTAssertEqual(engine.expire(selected: "red", now: now.addingTimeInterval(330)), "weather")
    }
    func testRepeatedStartDoesNotExtendAndManualNavigationWins() {
        var engine = RedAlertNavigation()
        _ = engine.receive(state: state(), target: "red", selected: "weather", now: now)
        _ = engine.receive(state: state(start: 30), target: "red", selected: "red", now: now.addingTimeInterval(30))
        XCTAssertEqual(engine.expiresAt, now.addingTimeInterval(300))
        engine.manualSelection()
        XCTAssertNil(engine.receive(state: state(), target: "red", selected: "cameras", now: now))
        XCTAssertNil(engine.expire(selected: "cameras", now: now.addingTimeInterval(301)))
    }
    func testInvalidExpiredAndFutureStatesDoNotNavigate() {
        for value in [state(duration: 301), state(duration: -1), state(start: 10), state(start: -400)] {
            var engine = RedAlertNavigation()
            XCTAssertNil(engine.receive(state: value, target: "red", selected: "weather", now: now))
        }
    }
    func testCheckpointRoundTripRestoresAfterRelaunchOffline() throws {
        var engine = RedAlertNavigation()
        _ = engine.receive(state: state(), target: "red", selected: "weather", now: now)
        engine = try JSONDecoder().decode(RedAlertNavigation.self, from: JSONEncoder().encode(engine))
        XCTAssertEqual(engine.expire(selected: "red", now: now.addingTimeInterval(301)), "weather")
    }
}
