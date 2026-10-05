import XCTest
@_spi(NativeInstallation) import ScreenpunkApple
@testable import Screenpunk

final class NativeEnrollmentSceneControllerTests: XCTestCase {
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
        controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: UUID(), locationID: UUID(), name: "Fixture", profile: "Fixture", viewport: CGSize(width: 390, height: 844))
        XCTAssertEqual(controller.state, .needsAttention)
        XCTAssertNil(bootstrap.currentAuthority)
    }
    @MainActor func testRetiredHumanSceneCannotCreateEnrollment() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        lifecycle.retirePresentationContext()
        XCTAssertThrowsError(try lifecycle.enrollmentSelection(accountID: UUID(), locationID: UUID()))
    }
}
