import XCTest
@testable import ScreenpunkCore

final class DeviceManagementFormatHistoryTests: XCTestCase {
    func testRoundTripPreservesAllLegacyBindingsAndFences() throws {
        var h = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "old-a")
        h = try h.appendingCredential(credentialGenerationID: UUID(), credentialReference: "old-b").fenced()
        h = try h.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "old-c")
        let formatted = try DeviceManagementFormatHistory(legacy: h)
        XCTAssertEqual(formatted.transitions, h.transitions)
        XCTAssertEqual(formatted.credentials.map(\.credentialReference), h.credentials.map(\.credentialReference))
        XCTAssertEqual(formatted.credentials.map(\.credentialGenerationID), h.credentials.map(\.credentialGenerationID))
        XCTAssertTrue(formatted.credentials.allSatisfy { $0.format == .legacyLocal32 })
        XCTAssertEqual(try JSONDecoder().decode(DeviceManagementFormatHistory.self, from: JSONEncoder().encode(formatted)), formatted)
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: JSONEncoder().encode(formatted)))
    }
    func testMixedFormatsStrictKeysAndLimits() throws {
        let id = UUID()
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: id, credentialReference: "native", format: .nativeInstallationV1)
        let h = try DeviceManagementFormatHistory(transitions: [.init(transitionID: id, phase: .intent)], credentials: [binding])
        let bytes = try JSONEncoder().encode(h)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementFormatHistory.self, from: Data(text.replacingOccurrences(of: "nativeInstallationV1", with: "unknown").utf8)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["operations"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementFormatHistory.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try DeviceManagementFormatHistory(transitions: [], credentials: []))
        XCTAssertThrowsError(try DeviceManagementFormatHistory(transitions: h.transitions, credentials: [binding, binding]))
        let bindings = try (0..<129).map { try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: id, credentialReference: "ref-\($0)", format: .legacyLocal32) }
        XCTAssertThrowsError(try DeviceManagementFormatHistory(transitions: h.transitions, credentials: bindings))
        let transitions = (0..<65).map { _ in DeviceManagementTransitionEntry(transitionID: UUID(), phase: .locallyFenced) }
        XCTAssertThrowsError(try DeviceManagementFormatHistory(transitions: transitions, credentials: [binding]))
    }
}
