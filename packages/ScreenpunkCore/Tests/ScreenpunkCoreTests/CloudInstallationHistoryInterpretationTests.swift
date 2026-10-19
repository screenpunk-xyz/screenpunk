import XCTest
@testable import ScreenpunkCore

final class CloudInstallationHistoryInterpretationTests: XCTestCase {
    func testPreservesCompleteOrderedHistoryAndEveryFenceWithoutChangingInput() throws {
        var history = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy-first")
        history = try history.appendingCredential(credentialGenerationID: UUID(), credentialReference: "legacy-second")
        history = try history.fenced()
        history = try history.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "legacy-third")
        let original = try JSONEncoder().encode(history)
        for candidate in [history, try history.fenced()] {
            let view = try CloudInstallationHistoryInterpretation(version2: candidate)
            XCTAssertEqual(view.sourceSchemaVersion, 2)
            XCTAssertEqual(view.transitions, candidate.transitions)
            XCTAssertEqual(view.bindings.map(\.localCredentialBindingID), candidate.credentials.map(\.credentialGenerationID))
            XCTAssertEqual(view.bindings.map(\.transitionID), candidate.credentials.map(\.transitionID))
            XCTAssertEqual(view.bindings.map(\.credentialReference), candidate.credentials.map(\.credentialReference))
            XCTAssertTrue(view.bindings.allSatisfy { $0.format == .legacyLocal32 })
            XCTAssertEqual(view, try CloudInstallationHistoryInterpretation(version2: candidate))
        }
        XCTAssertEqual(try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: original), history)
    }

    func testExistingValidationRejectsInvalidHistoryBeforeInterpretation() throws {
        let id = UUID()
        let binding = try DeviceManagementCredentialBinding(credentialGenerationID: UUID(), transitionID: id, credentialReference: "legacy")
        XCTAssertThrowsError(try DeviceManagementTransitionHistory(transitions: [], credentials: [binding]))
        XCTAssertThrowsError(try DeviceManagementTransitionHistory(transitions: [.init(transitionID: id, phase: .intent)], credentials: [binding, binding]))
        XCTAssertThrowsError(try DeviceManagementTransitionHistory(transitions: [.init(transitionID: UUID(), phase: .locallyFenced)], credentials: [binding]))
        // The history exposes only validated construction and decoding: no invalid public memberwise initializer.
        let unsupported = Data("{\"schemaVersion\":3,\"transitions\":[],\"credentials\":[]}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceManagementTransitionHistory.self, from: unsupported))
    }
}
