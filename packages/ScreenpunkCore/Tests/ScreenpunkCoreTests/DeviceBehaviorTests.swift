import XCTest
@testable import ScreenpunkCore

final class DeviceBehaviorTests: XCTestCase {
    private let valid = TemporaryActivationConfiguration(entityId: "binary_sensor.delivery", activeState: "ready", inactiveState: "idle",
        idAttribute: "event", startedAtAttribute: "begin", expiresAtAttribute: "end", maxDurationSeconds: 45)

    func testExplicitPermissionsAndRoundTrip() throws {
        let omitted = try JSONDecoder().decode(DeviceBehavior.self, from: Data("{}".utf8))
        XCTAssertNil(omitted.temporaryActivation)
        XCTAssertFalse(omitted.allowsAudioAutoplay)
        let behavior = DeviceBehavior(temporaryActivation: valid, audio: .init(autoplay: true))
        try behavior.validate()
        XCTAssertEqual(try JSONDecoder().decode(DeviceBehavior.self, from: JSONEncoder().encode(behavior)), behavior)
        XCTAssertTrue(behavior.allowsAudioAutoplay)
        XCTAssertTrue(DeviceBehavior(audio: .init(autoplay: true)).allowsAudioAutoplay)
        XCTAssertFalse(DeviceBehavior(audio: .init(autoplay: false)).allowsAudioAutoplay)
    }

    func testRejectsUnsafeIncompleteAndAmbiguousConfiguration() throws {
        for entity in ["", "sensor.a/b", "sensor.a?x=1", "sensor.a%2fb", "sensor.a\n", String(repeating: "a", count: 256) + ".x"] {
            var config = valid; config.entityId = entity; XCTAssertThrowsError(try config.validate())
        }
        for duration in [0, -1, 3601] {
            var config = valid; config.maxDurationSeconds = duration; XCTAssertThrowsError(try config.validate())
        }
        var config = valid; config.inactiveState = config.activeState; XCTAssertThrowsError(try config.validate())
        config = valid; config.startedAtAttribute = config.idAttribute; XCTAssertThrowsError(try config.validate())
        config = valid; config.expiresAtAttribute = "nested.end"; XCTAssertThrowsError(try config.validate())
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceBehavior.self, from: Data("{\"temporaryActivation\":{\"source\":\"homeAssistant\"}}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceBehavior.self, from: Data("{\"audio\":{\"autoplay\":\"true\"}}".utf8)))
    }

    func testCustomContractAndEntityIsolation() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let formatter = ISO8601DateFormatter()
        var state: [String: Any] = ["entity_id": valid.entityId, "state": "ready", "attributes": ["event": "delivery-1",
            "begin": formatter.string(from: now), "end": formatter.string(from: now.addingTimeInterval(45))]]
        var engine = TemporaryActivationNavigation()
        state["entity_id"] = "binary_sensor.other"
        XCTAssertNil(engine.receive(state: state, configuration: valid, target: "delivery", selected: "clock", now: now))
        state["entity_id"] = valid.entityId
        XCTAssertEqual(engine.receive(state: state, configuration: valid, target: "delivery", selected: "clock", now: now), "delivery")
        state["state"] = "unknown"
        XCTAssertNil(engine.receive(state: state, configuration: valid, target: "delivery", selected: "delivery", now: now))
        state["state"] = "idle"
        XCTAssertEqual(engine.receive(state: state, configuration: valid, target: "delivery", selected: "delivery", now: now), "clock")
    }
}
