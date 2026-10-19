import XCTest
@testable import Screenpunk

@MainActor
final class KioskCloudRequestTests: XCTestCase {
    func testConstructingKioskDoesNotDeliverCloudIntent() {
        var calls = 0
        let view = KioskLaunchView(onCloudAccountRequested: { calls += 1 })
        XCTAssertFalse(view.hasUnfinishedCloudEnrollment)
        XCTAssertEqual(calls, 0)
        view.onCloudAccountRequested?()
        XCTAssertEqual(calls, 1)
    }
    func testConstructingKioskDoesNotDeliverLocalIntent() async {
        var localCalls = 0
        var cloudCalls = 0
        let view = KioskLaunchView(onCloudAccountRequested: { cloudCalls += 1 }, onLocalStartupRequested: {
            localCalls += 1
            return "Actual local attempt failed"
        })
        XCTAssertEqual(localCalls, 0)
        let failure = await view.onLocalStartupRequested?()
        XCTAssertEqual(failure, "Actual local attempt failed")
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(cloudCalls, 0)
    }
    func testExistingKioskCallerHasNoCloudFactory() {
        XCTAssertNil(KioskLaunchView().onCloudAccountRequested)
        XCTAssertNil(KioskLaunchView().onLocalStartupRequested)
    }
}
