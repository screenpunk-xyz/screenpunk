import XCTest
import UIKit
@testable import Screenpunk

final class CloudNativeIdentityTests: XCTestCase {
    private var configured: [String: Any] {
        ["ScreenpunkCloudFirebaseProjectID": "fixture-cloud-project",
         "ScreenpunkCloudFirebaseAPIKey": "fixture-api-key",
         "ScreenpunkCloudFirebaseAppID": "1:123456:ios:fixture",
         "ScreenpunkCloudFirebaseSenderID": "123456",
         "ScreenpunkCloudGoogleClientID": "fixture-client.apps.googleusercontent.com",
         "ScreenpunkCloudGoogleCallbackScheme": "com.googleusercontent.apps.fixture-client",
         "ScreenpunkCloudBundleID": "test.screenpunk",
         "ScreenpunkCloudAPIOrigin": "https://cloud.example.invalid",
         "CFBundleURLTypes": [["CFBundleURLName": "Screenpunk Cloud OAuth", "CFBundleURLSchemes": ["com.googleusercontent.apps.fixture-client"]]]]
    }
    func testMissingAndUnexpandedConfigurationFailsClosed() {
        XCTAssertThrowsError(try CloudNativeConfiguration.load(info: [:], bundleID: "test.screenpunk"))
        for key in configured.keys.filter({ $0.hasPrefix("ScreenpunkCloud") }) {
            for value in ["", "$(UNSUPPLIED)"] {
                var info = configured; info[key] = value
                XCTAssertThrowsError(try CloudNativeConfiguration.load(info: info, bundleID: "test.screenpunk"), key)
            }
        }
    }
    func testDedicatedCallbackRejectsCalendarAndUnexpectedPaths() throws {
        let configuration = try CloudNativeConfiguration.load(info: configured, bundleID: "test.screenpunk")
        XCTAssertTrue(configuration.acceptsGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback?code=fixture")!))
        for url in ["calendar:/oauth2redirect", "com.googleusercontent.apps.fixture-client:/oauth2redirect", "com.googleusercontent.apps.fixture-client://unexpected/oauth2callback", "https://cloud.example.invalid/oauth2callback"] {
            XCTAssertFalse(configuration.acceptsGoogleCallback(URL(string: url)!))
        }
    }
    func testBundleOriginAndCalendarSchemeCollisionFailClosed() {
        XCTAssertThrowsError(try CloudNativeConfiguration.load(info: configured, bundleID: "other.bundle"))
        for origin in ["http://cloud.example.invalid", "https://user@cloud.example.invalid", "https://cloud.example.invalid/path", "https://cloud.example.invalid?secret=fixture"] {
            var info = configured; info["ScreenpunkCloudAPIOrigin"] = origin
            XCTAssertThrowsError(try CloudNativeConfiguration.load(info: info, bundleID: "test.screenpunk"))
        }
        var info = configured
        var types = info["CFBundleURLTypes"] as! [[String: Any]]
        types.append(["CFBundleURLName": "Google Calendar OAuth", "CFBundleURLSchemes": ["com.googleusercontent.apps.fixture-client"]])
        info["CFBundleURLTypes"] = types
        XCTAssertThrowsError(try CloudNativeConfiguration.load(info: info, bundleID: "test.screenpunk"))
    }
    @MainActor func testUnconfiguredAppleSignInFailsBeforeInteractiveAuthorization() async {
        let identity = CloudNativeIdentity()
        do {
            try await identity.signInWithApple(presentationAnchor: UIWindow())
            XCTFail("Unconfigured Apple sign-in must fail before presenting a provider")
        } catch {
            XCTAssertEqual(error as? CloudNativeIdentityError, .notConfigured)
        }
        XCTAssertThrowsError(try identity.tokenProvider())
    }

    @MainActor func testUnconfiguredServiceCannotIssueSessionProviderOrHandleCallbacks() {
        let identity = CloudNativeIdentity()
        XCTAssertThrowsError(try identity.tokenProvider())
        XCTAssertFalse(identity.handleGoogleCallback(URL(string: "com.googleusercontent.apps.fixture-client:/oauth2callback")!))
        identity.cancelActiveFlow()
        XCTAssertThrowsError(try identity.tokenProvider())
    }
}
