import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceGeneralNameTests: XCTestCase {
    func testBlankNameRestoresDefaultAndOuterSpacesAreTrimmed() throws {
        XCTAssertNil(DeviceGeneralName.savedValue("   "))
        XCTAssertEqual(DeviceGeneralName.savedValue("  Kitchen  "), "Kitchen")
        try DeviceSettings(displayName: DeviceGeneralName.savedValue("  Kitchen  ")).validate()
    }

    func testInvalidNameRemainsInvalidRatherThanSilentlyDefaultingOrTruncating() {
        for raw in [String(repeating: "a", count: DeviceDisplayName.maxLength + 1), "\n", "Kitchen\nDisplay", "\u{0000}"] {
            let value = DeviceGeneralName.savedValue(raw)
            XCTAssertNotNil(value)
            XCTAssertThrowsError(try DeviceSettings(displayName: value).validate())
        }
    }
}
