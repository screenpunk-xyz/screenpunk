import XCTest
@testable import ScreenpunkController
import ScreenpunkCore

final class HelpCatalogTests: XCTestCase {
    func testUnlinkTopicIncludesTwoFingerTenSecondGesture() {
        let topic = HelpCatalog.topic(id: "unlink")
        XCTAssertTrue(topic.body.lowercased().contains("two fingers"))
        XCTAssertTrue(topic.body.contains("ten seconds") || topic.body.contains("10 seconds"))
        XCTAssertTrue(topic.body.contains("Unlink"))
        XCTAssertTrue(topic.body.contains("Dashboard, credentials, and pairing are erased")
            || topic.body.lowercased().contains("pairing are erased"))
        XCTAssertTrue(topic.body.contains(HelpCatalog.forgetDoesNotErase)
            || topic.body.lowercased().contains("does not erase"))
        XCTAssertEqual(HelpCatalog.unlinkFingers, 2)
        XCTAssertEqual(HelpCatalog.unlinkHoldsSeconds, 10)
        XCTAssertEqual(UnlinkGestureSpec.actionCount, 1)
    }

    func testOnboardingIncludesUnlinkAndHiddenHelper() {
        let onboarding = HelpCatalog.topic(id: "onboarding").body.lowercased()
        XCTAssertTrue(onboarding.contains("two fingers") || onboarding.contains("unlink"))
        XCTAssertTrue(onboarding.contains("helper") || onboarding.contains("workbench"))
        XCTAssertTrue(onboarding.contains("live"))
    }

    func testCatalogMarksPreviewLiveAndHiddenHelper() {
        let catalog = MCPCatalog.load()
        XCTAssertTrue(catalog.previewLiveDefault)
        XCTAssertTrue(catalog.helperStartsAutomatically)
        XCTAssertFalse(catalog.workbenchMustBeVisible)
        XCTAssertTrue(catalog.neverPathOnlyPreview)
        XCTAssertTrue(catalog.neverPlaceholderImage)
        XCTAssertTrue(catalog.tools.contains { $0.name == "preview_dashboard" })
        XCTAssertTrue(catalog.tools.contains { $0.name == "get_help" })
        XCTAssertTrue(catalog.errors.contains("render_timeout"))
        let preview = catalog.tools.first { $0.name == "preview_dashboard" }
        XCTAssertTrue(preview?.description.contains("Live preview") == true)
    }
}
