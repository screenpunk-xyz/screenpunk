import XCTest
import SwiftUI
import ScreenpunkCore
@testable import ScreenpunkApple

final class UnlinkPanelTests: XCTestCase {
    func testActionMeetsMinimumTapHeight() {
        XCTAssertGreaterThanOrEqual(UnlinkPanelLayout.actionMinimumHeight, 44)
    }

    func testPressedStateIsDistinctFromIdle() {
        XCTAssertEqual(UnlinkPanelLayout.pressedDim(false), 0)
        XCTAssertGreaterThanOrEqual(UnlinkPanelLayout.pressedDim(true), 0.2)
        XCTAssertEqual(UnlinkPanelLayout.pressedScale(false), 1)
        XCTAssertLessThan(UnlinkPanelLayout.pressedScale(true), 1)
    }

    func testHoldGateIsUnchanged() {
        XCTAssertEqual(UnlinkGestureSpec.fingers, 2)
        XCTAssertEqual(NativeChromeHost.holdSeconds, 10)
        XCTAssertEqual(NativeChromeHost.unlinkActionCount, 1)
    }

    func testPanelAndStyleConstruct() {
        var unlinked = 0
        var dismissed = 0
        let panel = UnlinkPanelView(onUnlink: { unlinked += 1 }, onDismiss: { dismissed += 1 })
        panel.onUnlink()
        panel.onDismiss()
        XCTAssertEqual(unlinked, 1)
        XCTAssertEqual(dismissed, 1)
        _ = UnlinkActionButtonStyle(fill: .red, label: .white)
    }
}
