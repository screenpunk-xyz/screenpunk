import XCTest
@testable import Screenpunk

@MainActor
final class KioskCloudRequestTests: XCTestCase {
    func testConstructingKioskDoesNotDeliverCloudIntent() {
        var calls = 0
        let view = KioskLaunchView(onCloudAccountRequested: { calls += 1 })
        XCTAssertEqual(calls, 0)
        view.onCloudAccountRequested?()
        XCTAssertEqual(calls, 1)
    }
    func testExistingKioskCallerHasNoCloudFactory() {
        XCTAssertNil(KioskLaunchView().onCloudAccountRequested)
    }
}
