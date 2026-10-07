import XCTest
@testable import ScreenpunkController
import ScreenpunkCore

final class HelpCatalogTests: XCTestCase {
    func testDisconnectHelpRequiresFiveSecondMenuAndSeparateConfirmation() {
        let topic = HelpCatalog.topic(id: "unlink")
        XCTAssertTrue(topic.body.lowercased().contains("two fingers"))
        XCTAssertTrue(topic.body.contains("five seconds") || topic.body.contains("5 seconds"))
        XCTAssertTrue(topic.body.contains("Disconnect"))
        XCTAssertTrue(topic.body.contains("Opening the menu does not erase anything"))
        XCTAssertTrue(topic.body.contains("Confirming Disconnect erases screens, credentials, and pairing"))
        XCTAssertTrue(topic.body.contains(HelpCatalog.forgetDoesNotErase)
            || topic.body.lowercased().contains("does not erase"))
        XCTAssertEqual(HelpCatalog.unlinkFingers, 2)
        XCTAssertEqual(HelpCatalog.unlinkHoldsSeconds, 5)
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
