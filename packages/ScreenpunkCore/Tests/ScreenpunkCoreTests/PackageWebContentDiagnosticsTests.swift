import XCTest
@testable import ScreenpunkCore

final class PackageWebContentDiagnosticsTests: XCTestCase {
    private func inspect(_ html: String) -> [PackageWebContentDiagnostics.Issue] {
        PackageWebContentDiagnostics.inspect(files: ["index.html": Data(html.utf8)])
    }

    func testPackagedCSSAndJSHaveNoInlineDiagnostics() {
        XCTAssertTrue(inspect("<link rel='stylesheet' href='styles.css'><script src='app.js'></script><p class='counter'>0</p>").isEmpty)
    }

    func testCountdownInlineStyleAndScriptAreActionable() {
        let issues = inspect("<!doctype html>\n<style>body{background:black}</style>\n<p>000 days</p>\n<script>setInterval(tick,1000)</script>")
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.map(\.line), [2, 4])
        XCTAssertTrue(issues[0].message.contains("index.html:2"))
        XCTAssertTrue(issues[0].reason.contains("styles.css"))
        XCTAssertTrue(issues[1].reason.contains("app.js"))
    }

    func testMixedCaseQuotedAttributesAndEventHandlers() {
        let issues = inspect("<P title='a > b' STYLE = \"color:red\" OnClick='go()'>Hi</P>")
        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues[1].reason.contains("addEventListener"))
    }

    func testUnquotedStyleAndHandlersAreDetected() {
        XCTAssertEqual(inspect("<div style=color:red onload=go()></div>").count, 2)
    }

    func testCommentsAndTextDoNotBecomeExecutableTags() {
        XCTAssertTrue(inspect("<!-- <style>bad</style><script>bad()</script> -->&lt;style&gt;example&lt;/style&gt;").isEmpty)
    }

    func testJSONDataAndRawTextDoNotBecomeInlineCode() {
        XCTAssertTrue(inspect("<script type='application/json'>{\"html\":\"<style>not CSS</style>\"}</script><textarea><style>example</style></textarea><title><script>example</script></title>").isEmpty)
    }

    func testScriptStringsAreNotScannedAsHTML() {
        let issues = inspect("<script src='app.js'>const x = '<style>example</style>';</script><p class='ok'>Hello</p>")
        XCTAssertTrue(issues.isEmpty, "Content of a script with src is ignored by HTML, rather than becoming style markup")
    }

    func testRawTextClosingTagRequiresBoundary() {
        XCTAssertTrue(inspect("<script type='application/json'>\"</scripted><style>example</style>\"</script>").isEmpty)
    }

    func testInertScriptDoesNotHideFollowingExecutableContent() {
        XCTAssertEqual(inspect("<script type='application/ld+json'>{}</script><script type='module'>run()</script>").count, 1)
    }

    func testDuplicateAttributesUseFirstValueLikeHTML() {
        XCTAssertTrue(inspect("<script type='application/json' type='module'>{}</script>").isEmpty)
        XCTAssertEqual(inspect("<script type='module' type='application/json'>run()</script>").count, 1)
    }

    func testDiagnosticsAreDeterministicAndBoundedAcrossFiles() {
        let files = ["z.html": Data("<style>x{}</style>".utf8), "a.html": Data(String(repeating: "<script>run()</script>", count: 30).utf8)]
        let issues = PackageWebContentDiagnostics.inspect(files: files)
        XCTAssertEqual(issues.count, 16)
        XCTAssertTrue(issues.allSatisfy { $0.path == "a.html" })
    }

    func testNonHTMLAndEmptyBlocksAreNotRejected() {
        XCTAssertTrue(PackageWebContentDiagnostics.inspect(files: ["app.js": Data("const x='<style>x</style>';".utf8)]).isEmpty)
        XCTAssertTrue(inspect("<style> \n </style><script>\n</script><div data-onclick='annotation'></div>").isEmpty)
    }
}
