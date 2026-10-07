import XCTest
@testable import ScreenpunkController
import ScreenpunkCore

final class HelpCatalogTests: XCTestCase {
    func testPersistenceHelpMatchesFallbackAndBundledEntryPoint() {
        let fallback = HelpCatalog.fallbackTopics()["persistent-state"]
        let bundled = HelpCatalog.topic(id: "persistent-state")
        XCTAssertEqual(bundled.body, fallback?.body)
        XCTAssertTrue(bundled.body.contains("screenpunk.state.get/set/remove"))
        XCTAssertTrue(bundled.body.contains("persistentStateWritable"))
        XCTAssertTrue(bundled.body.contains("Never set defaults on load/update"))
        XCTAssertTrue(HelpCatalog.topic(id: "onboarding").body.contains("get_help(topic: persistent-state)"))
        XCTAssertTrue(HelpCatalog.fallbackTopics()["onboarding"]?.body.contains("get_help(topic: persistent-state)") == true)
    }

    func testAuthoringHelpTeachesLocalAssetsAndCurrentBrokerWorkflow() {
        for topic in [HelpCatalog.topic(id: "authoring"), HelpCatalog.fallbackTopics()["authoring"]!] {
            XCTAssertTrue(topic.body.contains("style-src 'self'"))
            XCTAssertTrue(topic.body.contains("script-src 'self'"))
            XCTAssertTrue(topic.body.contains("styles.css"))
            XCTAssertTrue(topic.body.contains("app.js"))
            XCTAssertTrue(topic.body.contains("patch_workspace_project"))
            XCTAssertTrue(topic.body.contains("run_workspace_build"))
            XCTAssertTrue(topic.body.contains("get_workspace_package_file"))
            XCTAssertFalse(topic.body.contains("update_screen_project"))
            XCTAssertTrue(topic.body.contains("Changed bytes need a new plan"))
        }
    }

    func testBothOnboardingSourcesPointAgentsToAuthoringPolicy() {
        XCTAssertTrue(HelpCatalog.topic(id: "onboarding").body.contains("get_help(topic: authoring)"))
        XCTAssertTrue(HelpCatalog.fallbackTopics()["onboarding"]!.body.contains("get_help(topic: authoring)"))
    }

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
