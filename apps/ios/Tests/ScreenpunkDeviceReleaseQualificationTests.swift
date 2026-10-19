import XCTest
@testable import Screenpunk

final class ScreenpunkDeviceReleaseQualificationTests: XCTestCase {
    private var info: [String: Any] {
        let callback = "com.googleusercontent.apps.fixture"
        return ["ScreenpunkCloudFirebaseProjectID": "screenpunk-stg-6f6e615a",
                "ScreenpunkCloudFirebaseAPIKey": "fixture-key", "ScreenpunkCloudFirebaseAppID": "1:123:ios:fixture",
                "ScreenpunkCloudFirebaseSenderID": "123", "ScreenpunkCloudGoogleClientID": "fixture.apps.googleusercontent.com",
                "ScreenpunkCloudGoogleCallbackScheme": callback, "ScreenpunkCloudBundleID": "xyz.screenpunk.ios",
                "ScreenpunkCloudAPIOrigin": "https://staging.screenpunk.xyz",
                "ScreenpunkInternalConcurrentControlCandidate": "internal-staging-concurrent-v1",
                "ScreenpunkConcurrentControlCompileFlag": "SCREENPUNK_INTERNAL_STAGING_CONCURRENT_CANDIDATE",
                "ScreenpunkConcurrentControlBuildMode": "internal-staging-candidate",
                "CFBundleURLTypes": [["CFBundleURLName": "Screenpunk Cloud OAuth", "CFBundleURLSchemes": [callback]]]]
    }
    func testInternalCandidateRequiresExactStagingAndCompleteNativeConfiguration() {
        XCTAssertTrue(ScreenpunkDeviceReleaseQualification.candidateAllows(info: info, bundleID: "xyz.screenpunk.ios"))
        for key in ["ScreenpunkInternalConcurrentControlCandidate", "ScreenpunkConcurrentControlBuildMode", "ScreenpunkConcurrentControlCompileFlag", "ScreenpunkCloudFirebaseAPIKey", "CFBundleURLTypes"] {
            var missing = info; missing.removeValue(forKey: key)
            XCTAssertFalse(ScreenpunkDeviceReleaseQualification.candidateAllows(info: missing, bundleID: "xyz.screenpunk.ios"))
        }
        for (key, value) in [("ScreenpunkCloudFirebaseProjectID", "screenpunk-prod-2c99c8b7"),
                             ("ScreenpunkCloudAPIOrigin", "https://screenpunk.xyz"),
                             ("ScreenpunkInternalConcurrentControlCandidate", "true"),
                             ("ScreenpunkConcurrentControlBuildMode", "ordinary")] {
            var wrong = info; wrong[key] = value
            XCTAssertFalse(ScreenpunkDeviceReleaseQualification.candidateAllows(info: wrong, bundleID: "xyz.screenpunk.ios"))
        }
        XCTAssertFalse(ScreenpunkDeviceReleaseQualification.candidateAllows(info: info, bundleID: "other"))
    }
    func testOrdinaryBuildDoesNotEnableConcurrentControlFromInfoOrSignIn() {
        #if !SCREENPUNK_CONCURRENT_CONTROL_QUALIFIED && !SCREENPUNK_INTERNAL_STAGING_CONCURRENT_CANDIDATE
        XCTAssertFalse(ScreenpunkDeviceReleaseQualification.concurrentControl)
        #endif
    }
}
