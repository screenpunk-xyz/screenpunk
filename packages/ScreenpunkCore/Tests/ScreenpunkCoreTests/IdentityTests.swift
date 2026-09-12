import XCTest
@testable import ScreenpunkCore

final class IdentityTests: XCTestCase {
    func testApprovedIdentity() {
        XCTAssertEqual(BrandIdentity.sootHex, "#15191C")
        XCTAssertEqual(BrandIdentity.porcelainHex, "#F4EFE5")
        XCTAssertEqual(BrandIdentity.logomarkRevision, "8-bevel")
        XCTAssertEqual(BrandIdentity.wordmarkRevision, "v1-modular")
        XCTAssertEqual(BrandIdentity.defaultLockup, "stacked")
        XCTAssertEqual(BrandIdentity.styleGuideURL, "https://screenpunk-style-guide.gsuter.chatgpt.site")
    }

    func testGuideTokensAndOfflineDanger() {
        XCTAssertEqual(SemanticTokens.Light.danger, "#A52C42")
        XCTAssertEqual(SemanticTokens.Dark.danger, "#FF8BA0")
        XCTAssertEqual(SemanticTokens.Light.canvas, "#F7F8FA")
        XCTAssertFalse(OfflineOverlaySpec.usesSystemRed)
        XCTAssertEqual(OfflineOverlaySpec.lightDangerHex, SemanticTokens.Light.danger)
        XCTAssertEqual(OfflineOverlaySpec.darkDangerHex, SemanticTokens.Dark.danger)
        XCTAssertEqual(PlatformRequirements.iosMinimum, "16.0")
        XCTAssertEqual(PlatformRequirements.macOSMinimum, "26.0")
        XCTAssertFalse(PlatformRequirements.ios27RequiredToRun)
        XCTAssertEqual(PlatformRequirements.preferredControls, "ios27-style-guide")
        XCTAssertEqual(PackageLimits.schemaMajor, 1)
    }
}
