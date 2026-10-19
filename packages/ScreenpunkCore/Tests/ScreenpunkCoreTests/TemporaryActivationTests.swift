import XCTest
@testable import ScreenpunkCore

final class TemporaryActivationTests: XCTestCase {
    let configuration = TemporaryActivationConfiguration(entityId: "sensor.notice", activeState: "on", inactiveState: "off", idAttribute: "notice_id", startedAtAttribute: "begin", expiresAtAttribute: "end", maxDurationSeconds: 300)
    let now = Date(timeIntervalSince1970: 1800000000)
    func state(_ id: String = "run-1", _ active: Bool = true, start: TimeInterval = 0, duration: TimeInterval = 300) -> [String: Any] {
        ["entity_id": configuration.entityId, "state": active ? "on" : "off", "attributes": ["notice_id": id,
            "begin": ISO8601DateFormatter().string(from: now.addingTimeInterval(start)),
            "end": ISO8601DateFormatter().string(from: now.addingTimeInterval(start + duration))]]
    }
    func testSnapshotJoinsActiveAndMatchingClearRestores() {
        var engine = TemporaryActivationNavigation()
        XCTAssertEqual(engine.receive(state: state(), configuration: configuration, target: "notice", selected: "weather", now: now.addingTimeInterval(100)), "notice")
        XCTAssertNil(engine.receive(state: state("older", false), configuration: configuration, target: "notice", selected: "notice", now: now))
        XCTAssertEqual(engine.receive(state: state("run-1", false), configuration: configuration, target: "notice", selected: "notice", now: now), "weather")
        XCTAssertNil(engine.receive(state: state(), configuration: configuration, target: "notice", selected: "weather", now: now))
    }
    func testOverlappingRunPreservesOriginalAndRejectsOldReplay() {
        var engine = TemporaryActivationNavigation()
        _ = engine.receive(state: state(), configuration: configuration, target: "notice", selected: "weather", now: now)
        XCTAssertNil(engine.receive(state: state("run-2", start: 30), configuration: configuration, target: "notice", selected: "notice", now: now.addingTimeInterval(30)))
        XCTAssertNil(engine.receive(state: state(), configuration: configuration, target: "notice", selected: "notice", now: now.addingTimeInterval(31)))
        XCTAssertNil(engine.expire(selected: "notice", now: now.addingTimeInterval(300)))
        XCTAssertEqual(engine.expire(selected: "notice", now: now.addingTimeInterval(330)), "weather")
    }
    func testRepeatedStartDoesNotExtendAndManualNavigationWins() {
        var engine = TemporaryActivationNavigation()
        _ = engine.receive(state: state(), configuration: configuration, target: "notice", selected: "weather", now: now)
        _ = engine.receive(state: state(start: 30), configuration: configuration, target: "notice", selected: "notice", now: now.addingTimeInterval(30))
        XCTAssertEqual(engine.expiresAt, now.addingTimeInterval(300))
        engine.manualSelection()
        XCTAssertNil(engine.receive(state: state(), configuration: configuration, target: "notice", selected: "cameras", now: now))
        XCTAssertNil(engine.expire(selected: "cameras", now: now.addingTimeInterval(301)))
    }
    func testInvalidExpiredAndFutureStatesDoNotNavigate() {
        for value in [state(duration: 301), state(duration: -1), state(start: 10), state(start: -400)] {
            var engine = TemporaryActivationNavigation()
            XCTAssertNil(engine.receive(state: value, configuration: configuration, target: "notice", selected: "weather", now: now))
        }
    }
    func testCheckpointRoundTripRestoresAfterRelaunchOffline() throws {
        var engine = TemporaryActivationNavigation()
        _ = engine.receive(state: state(), configuration: configuration, target: "notice", selected: "weather", now: now)
        engine = try JSONDecoder().decode(TemporaryActivationNavigation.self, from: JSONEncoder().encode(engine))
        XCTAssertEqual(engine.expire(selected: "notice", now: now.addingTimeInterval(301)), "weather")
    }
}
