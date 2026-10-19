import XCTest
import UIKit
@testable import Screenpunk

@MainActor
final class NativeEnrollmentDeviceTypeTests: XCTestCase {
    func testSystemReportedNameIsPreservedAsEditableSuggestion() {
        XCTAssertEqual(NativeEnrollmentDeviceMetadata.suggestedName(systemName: "Office iPad", profile: "iPad"), "Office iPad")
        XCTAssertEqual(NativeEnrollmentDeviceMetadata.suggestedName(systemName: "iPad", profile: "iPad"), "iPad")
        XCTAssertEqual(NativeEnrollmentDeviceMetadata.suggestedName(systemName: "Cafe\u{301} iPad", profile: "iPad"), "Cafe\u{301} iPad")
    }
    func testInvalidSystemNameUsesHonestDeviceTypeFallback() {
        for name in ["", "   ", "Office\n iPad", String(repeating: "x", count: 129)] {
            XCTAssertEqual(NativeEnrollmentDeviceMetadata.suggestedName(systemName: name, profile: "iPad"), "iPad")
        }
        XCTAssertEqual(NativeEnrollmentDeviceMetadata.suggestedName(systemName: String(repeating: "x", count: 128), profile: "iPad"), String(repeating: "x", count: 128))
    }
    func testPhoneAndPadReportNativeType() {
        XCTAssertEqual(NativeEnrollmentDeviceType.profile(idiom: .phone, isIOSAppOnMac: false), "iPhone")
        XCTAssertEqual(NativeEnrollmentDeviceType.profile(idiom: .pad, isIOSAppOnMac: false), "iPad")
    }
    func testMacIdiomAndIOSAppOnMacOverrideReportMac() {
        XCTAssertEqual(NativeEnrollmentDeviceType.profile(idiom: .mac, isIOSAppOnMac: false), "Mac")
        XCTAssertEqual(NativeEnrollmentDeviceType.profile(idiom: .pad, isIOSAppOnMac: true), "Mac")
        XCTAssertEqual(NativeEnrollmentDeviceType.profile(idiom: .phone, isIOSAppOnMac: true), "Mac")
        XCTAssertEqual(NativeEnrollmentDeviceType.profile(idiom: .unspecified, isIOSAppOnMac: true), "Mac")
    }
    func testUnsupportedIdiomsDoNotInventDeviceType() {
        for idiom in [UIUserInterfaceIdiom.unspecified, .tv, .carPlay] {
            XCTAssertNil(NativeEnrollmentDeviceType.profile(idiom: idiom, isIOSAppOnMac: false))
        }
    }
    func testCurrentProfileReportsActualUIKitPlatformWithoutAssumingPhone() {
        let expected: String?
        if ProcessInfo.processInfo.isiOSAppOnMac { expected = "Mac" }
        else {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: expected = "iPhone"
            case .pad: expected = "iPad"
            case .mac: expected = "Mac"
            default: expected = nil
            }
        }
        XCTAssertEqual(NativeEnrollmentDeviceType.currentProfile(), expected)
    }
}
