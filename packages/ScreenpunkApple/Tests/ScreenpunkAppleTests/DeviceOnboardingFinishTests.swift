import XCTest
@testable import ScreenpunkApple

final class DeviceOnboardingFinishTests: XCTestCase {
    func testDoneWithAppliedScreenShowsDashboard() {
        let covered = DeviceOnboardingFinish.done(screenApplied: true, coverPresented: true)
        XCTAssertFalse(covered.showSettings)
        XCTAssertTrue(covered.dismissCover)
        XCTAssertFalse(covered.presentSettingsAfterDismiss)

        let inline = DeviceOnboardingFinish.done(screenApplied: true, coverPresented: false)
        XCTAssertFalse(inline.showSettings)
        XCTAssertFalse(inline.dismissCover)
        XCTAssertFalse(inline.presentSettingsAfterDismiss)
    }

    func testDoneWithoutAScreenStillOpensSettings() {
        let covered = DeviceOnboardingFinish.done(screenApplied: false, coverPresented: true)
        XCTAssertFalse(covered.showSettings)
        XCTAssertTrue(covered.dismissCover)
        XCTAssertTrue(covered.presentSettingsAfterDismiss)
        XCTAssertTrue(DeviceOnboardingFinish.settingsOnCoverDismiss(presentSettingsAfterDismiss: true, screenApplied: false))

        let inline = DeviceOnboardingFinish.done(screenApplied: false, coverPresented: false)
        XCTAssertTrue(inline.showSettings)
        XCTAssertFalse(inline.dismissCover)
        XCTAssertFalse(inline.presentSettingsAfterDismiss)
    }

    func testScreenArrivingBeforeCoverDismissSkipsSettings() {
        XCTAssertFalse(DeviceOnboardingFinish.settingsOnCoverDismiss(presentSettingsAfterDismiss: true, screenApplied: true))
        XCTAssertFalse(DeviceOnboardingFinish.settingsOnCoverDismiss(presentSettingsAfterDismiss: false, screenApplied: false))
    }

    func testLocalRouteDoesNotHideAnAppliedScreen() {
        XCTAssertFalse(DeviceOnboardingFinish.hidesDashboard(localRoute: true, screenApplied: true))
        XCTAssertTrue(DeviceOnboardingFinish.hidesDashboard(localRoute: true, screenApplied: false))
        XCTAssertFalse(DeviceOnboardingFinish.hidesDashboard(localRoute: false, screenApplied: true))
    }

    func testCompletedLocalStepRevealsAnAppliedScreen() {
        XCTAssertTrue(DeviceOnboardingFinish.revealAppliedScreen(localRoute: true, pairingCompleted: true, screenApplied: true))
        XCTAssertFalse(DeviceOnboardingFinish.revealAppliedScreen(localRoute: true, pairingCompleted: false, screenApplied: true))
        XCTAssertFalse(DeviceOnboardingFinish.revealAppliedScreen(localRoute: true, pairingCompleted: true, screenApplied: false))
        XCTAssertFalse(DeviceOnboardingFinish.revealAppliedScreen(localRoute: false, pairingCompleted: true, screenApplied: true))
    }
}
