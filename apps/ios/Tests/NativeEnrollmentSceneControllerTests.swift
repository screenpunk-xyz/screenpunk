import XCTest
@_spi(NativeInstallation) import ScreenpunkApple
@testable import Screenpunk

final class NativeEnrollmentSceneControllerTests: XCTestCase {
    func testOriginalEnrollmentIntentSurvivesRestartWithUnassignedLocation() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let original = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Display", profile: "ios",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 390, height: 844))
        try journal.saveOriginal(original)
        let restarted = NativeEnrollmentIntentJournal(directory: journal.directory)
        XCTAssertEqual(try restarted.load(), original)
        XCTAssertNil(try restarted.load()?.proposal().claimInput.locationId)
        try restarted.saveOriginal(original)
        try restarted.markRecordedInstallation(original)
        XCTAssertEqual(try restarted.load()?.requestID, original.requestID)
        XCTAssertTrue(try XCTUnwrap(restarted.load()).restoreRecordedInstallation)
    }
    func testOriginalEnrollmentIntentRejectsReplacementAndCorruptRecord() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        func record() throws -> NativeEnrollmentIntentRecord {
            try .init(accountID: UUID(), locationID: nil, name: "Display", profile: "ios",
                origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 390, height: 844))
        }
        let original = try record(); try journal.saveOriginal(original)
        XCTAssertThrowsError(try journal.saveOriginal(record()))
        XCTAssertEqual(try journal.load(), original)
        try Data("invalid".utf8).write(to: journal.directory.appendingPathComponent("original.json"))
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.saveOriginal(original))
    }
    @MainActor func testDormantControllerDoesNotConstructAnEnrollment() {
        let controller = NativeEnrollmentSceneController()
        XCTAssertEqual(controller.state, .idle)
        controller.didEnterBackground()
        XCTAssertEqual(controller.state, .idle)
    }
    @MainActor func testMissingHumanSelectionFailsBeforeProductionConfigurationOrOwnerEffects() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let bootstrap = DeviceManagementBootstrap() // No start/task; deferred production owner is not constructed.
        let controller = NativeEnrollmentSceneController()
        controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: UUID(), locationID: UUID(), name: "Fixture", viewport: CGSize(width: 390, height: 844))
        XCTAssertEqual(controller.state, .needsAttention)
        XCTAssertNil(bootstrap.currentAuthority)
    }
    @MainActor func testRetiredHumanSceneCannotCreateEnrollment() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        lifecycle.retirePresentationContext()
        XCTAssertThrowsError(try lifecycle.enrollmentSelection(accountID: UUID(), locationID: UUID()))
    }
}
