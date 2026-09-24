import XCTest
@testable import ScreenpunkCore

final class DeviceSettingsTests: XCTestCase {
    func testDeviceNameIsOptionalForLegacySettingsAndPersistsWhenSet() throws {
        let original = DeviceSettings(brightness: .init(mode: .fixed, fixedLevel: 0.4))
        let legacy = try JSONEncoder().encode(original)
        var decoded = try JSONDecoder().decode(DeviceSettings.self, from: legacy)
        XCTAssertNil(decoded.displayName)
        decoded.displayName = "Office iPad"
        try decoded.validate()
        let restored = try JSONDecoder().decode(DeviceSettings.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.displayName, "Office iPad")
        XCTAssertEqual(restored.brightness, original.brightness)
        decoded.displayName = "   "
        XCTAssertThrowsError(try decoded.validate())
    }

    func testCompetingEditsRejectStaleRevisionWithoutTimeOrdering() throws {
        let original = DeviceSettingsSnapshot()
        var value = original.value
        value.brightness = .init(mode: .fixed, fixedLevel: 0.8)
        let accepted = try original.replacing(with: .init(expectedRevision: original.revision, value: value))
        XCTAssertNotEqual(accepted.revision, original.revision)
        XCTAssertFalse(accepted.isApplied, "a durable configuration is not a runtime acknowledgement")
        XCTAssertThrowsError(try accepted.replacing(with: .init(expectedRevision: original.revision, value: .init()))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .conflict)
        }
        XCTAssertEqual(accepted.value.brightness.fixedLevel, 0.8)
    }

    func testPreferencesSurvivePersistenceAndLegacyStateDecodes() throws {
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let owner = PairingIdentityFactory.make(role: .controller)
        var state = DevicePersistedState(owner: owner, activeRevision: "r1", activeStoredRevision: nil, lastDeployment: nil)
        try store.save(state)
        XCTAssertNil(store.load()?.settings)
        let snapshot = DeviceSettingsSnapshot(value: .init(startingPageByDashboard: ["dashboard": "door"],
            brightness: .init(mode: .schedule, schedule: [.init(minuteOfDay: 0, level: 0.2), .init(minuteOfDay: 480, level: 0.8)])))
        state.settings = snapshot
        try store.save(state)
        XCTAssertEqual(store.load()?.settings, snapshot)
        XCTAssertEqual(store.load()?.owner, owner)
        XCTAssertEqual(store.load()?.activeRevision, "r1")
        try store.erase()
        XCTAssertNil(store.load())
    }

    func testInvalidBrightnessNeverProducesAcceptedRevision() throws {
        for brightness in [DeviceBrightnessSettings(mode: .fixed, fixedLevel: .nan),
                           .init(mode: .fixed, fixedLevel: 1.1),
                           .init(mode: .schedule),
                           .init(mode: .schedule, schedule: [.init(minuteOfDay: 1440, level: 0.2)]),
                           .init(mode: .schedule, schedule: [.init(minuteOfDay: 60, level: 0.2), .init(minuteOfDay: 60, level: 0.4)])] {
            let snapshot = DeviceSettingsSnapshot()
            XCTAssertThrowsError(try snapshot.replacing(with: .init(expectedRevision: snapshot.revision, value: .init(brightness: brightness)))) {
                XCTAssertEqual($0 as? DeviceSettingsFailure, .invalidSettings)
            }
        }
    }

    func testSettingsLANPayloadRoundTrip() throws {
        let snapshot = DeviceSettingsSnapshot(value: .init(brightness: .init(mode: .fixed, fixedLevel: 0.4)))
        let request = LANEnvelope(requestId: "settings-edit", method: LANMethod.settingsUpdate.rawValue,
            payloadJSON: try LANCodec.encodePayload(DeviceSettingsUpdate(expectedRevision: snapshot.revision, value: snapshot.value)))
        let decoded = try LANCodec.decode(LANCodec.encode(request))
        XCTAssertEqual(decoded.method, "settings.update")
        XCTAssertEqual(try LANCodec.decodePayload(DeviceSettingsUpdate.self, json: decoded.payloadJSON).expectedRevision, snapshot.revision)
    }
}
