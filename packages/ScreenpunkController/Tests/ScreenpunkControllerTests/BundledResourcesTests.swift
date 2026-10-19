import XCTest
@testable import ScreenpunkController

final class BundledResourcesTests: XCTestCase {
    func testHomebrewLinksUseReleaseJSONForAllThreeExecutables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("Caskroom/screenpunk-cli/1.0.3/Screenpunk CLI 1.0.3")
        let resources = release.appendingPathComponent("Resources/help")
        let links = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        for name in ["help", "mcp-catalog"] {
            try Data("release-\(name)".utf8).write(to: resources.appendingPathComponent("\(name).json"))
        }
        // A resource bundle near the public link must not shadow the actual release.
        let decoy = links.appendingPathComponent("ScreenpunkController_ScreenpunkController.bundle")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        try Data("decoy".utf8).write(to: decoy.appendingPathComponent("help.json"))
        for relative in ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service"] {
            let executable = release.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: executable)
            let link = links.appendingPathComponent(executable.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
            for name in ["help", "mcp-catalog"] {
                let found = try XCTUnwrap(BundledResources.url(forResource: name, withExtension: "json",
                    executable: link, mainResourceURL: links, mainBundleURL: links, containingBundleURL: nil))
                XCTAssertEqual(found.path, resources.appendingPathComponent("\(name).json").path)
                XCTAssertEqual(try String(contentsOf: found), "release-\(name)")
            }
        }
    }

    func testAppAndAdjacentSwiftPMResourceBundlesRemainSupported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for relative in ["Screenpunk.app/Contents/Resources", "debug"] {
            let parent = root.appendingPathComponent(relative)
            let bundle = parent.appendingPathComponent("ScreenpunkController_ScreenpunkController.bundle")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let expected = bundle.appendingPathComponent("help.json")
            try Data("fixture".utf8).write(to: expected)
            let found = BundledResources.url(forResource: "help", withExtension: "json",
                executable: parent.appendingPathComponent("screenpunk"),
                mainResourceURL: parent, mainBundleURL: parent, containingBundleURL: nil)
            XCTAssertEqual(found?.path, expected.path)
        }
    }

    func testMissingResourcesReturnNilWithoutGeneratedAccessorTrap() {
        let missing = URL(fileURLWithPath: "/private/tmp/absent-screenpunk-resources-\(UUID().uuidString)")
        XCTAssertNil(BundledResources.url(forResource: "help", withExtension: "json",
            executable: missing.appendingPathComponent("bin/screenpunk"),
            mainResourceURL: missing, mainBundleURL: missing, containingBundleURL: nil))
    }

    func testSwiftPMTestsLoadActualCatalogAndHelpRatherThanFallback() {
        XCTAssertGreaterThan(MCPCatalog.load().tools.count, MCPCatalog.fallbackCatalog().tools.count)
        XCTAssertTrue(HelpCatalog.topic(id: "onboarding").body.contains("cryptographic guarantee"))
    }
}
