import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class PackageConnectionValidationTests: XCTestCase {
    private let tv = "screenpunk.connections.request('googleTV','status',{})"
    func testCleanFlatAndSwiftPMLayoutsResolveWithoutGeneratedModuleAccessor() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("release/bin/screenpunk-mcp")
        let resources = temporary.appendingPathComponent("release/Resources")
        let absent = temporary.appendingPathComponent("absent")
        func discover() -> URL? {
            BundledResources.connectionValidator(executable: executable, mainResourceURL: absent,
                mainBundleURL: absent, containingBundleURL: absent)
        }
        XCTAssertNil(discover())
        for relative in ["ConnectionValidator", "ScreenpunkController_ScreenpunkController.bundle/ConnectionValidator"] {
            let helper = resources.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: helper.appendingPathComponent("validate.cjs"))
            XCTAssertEqual(discover()?.standardizedFileURL, helper.standardizedFileURL)
            try FileManager.default.removeItem(at: helper)
        }
        XCTAssertNil(discover())
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: ["APP.JS": Data(tv.utf8)], connections: [], root: absent))
    }
    func testExternalAndInlineCallsRequireDeclarationWithoutAuthoringKit() throws {
        for files in [["app.js": Data(tv.utf8)], ["APP.JS": Data(tv.utf8)], ["index.html": Data(("<html>\n<script>" + tv + "</script>").utf8)]] {
            XCTAssertThrowsError(try PackageConnectionValidation.validate(files: files, connections: [])) { error in
                XCTAssertTrue(String(describing: error).contains("googleTV"))
            }
            try PackageConnectionValidation.validate(files: files, connections: [.init(alias: "googleTV", required: false)])
        }
    }
    func testMarkupDataAndShadowedObjectsDoNotTriggerRequirements() throws {
        let html = "<!-- <script>" + tv + "</script> --><script type='application/json'>{\"googleTV\":true}</script><script>const screenpunk={connections:{request(){}}};" + tv + "</script>"
        try PackageConnectionValidation.validate(files: ["index.html": Data(html.utf8)], connections: [])
    }
    func testUnavailableCancelledOversizedAndInvalidUTF8FailClosed() throws {
        let files = ["app.js": Data(tv.utf8)]
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: files, connections: [], root: URL(fileURLWithPath: "/missing-validator")))
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: files, connections: [], cancelled: { true }))
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: ["app.js": Data([255])], connections: []))
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: ["index.html": Data(repeating: 32, count: 5*1024*1024+1)], connections: []))
    }
    func testScreenCodeIsNeverExecuted() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let code = "require('node:fs').writeFileSync(" + String(data: try JSONEncoder().encode(marker.path), encoding: .utf8)! + ", 'executed');"
        try PackageConnectionValidation.validate(files: ["app.js": Data(code.utf8)], connections: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testRunningHelperTimeoutAndCancellationAreBounded() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ScreenpunkController_ScreenpunkController.bundle/ConnectionValidator/node")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.linkItem(at: helper, to: root.appendingPathComponent("node"))
        try Data("while(true) {}".utf8).write(to: root.appendingPathComponent("validate.cjs"))
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: ["app.js": Data("const x=1".utf8)], connections: [], root: root))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 7)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PackageConnectionValidation.validate(files: ["app.js": Data("const x=1".utf8)], connections: [], root: root,
            cancelled: { ProcessInfo.processInfo.systemUptime - cancelStart > 0.15 }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelStart, 2)
    }

    func testLegacyWriteRetainsPreviousRevisionOnMissingDeclaration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ControllerService(store: try DashboardPackageStore(root: root))
        let target = ManifestTarget(profileId: "phone", width: 390, height: 844, scale: 3, orientation: "portrait", safeArea: nil)
        let first = try service.store.putDashboard(dashboardId: nil, name: "TV", baseRevision: nil, target: target,
            connections: [.init(alias: "googleTV", required: false)], files: [.init(path: "index.html", text: #"<script src="app.js"></script>"#), .init(path: "app.js", text: tv)])
        let args: [String: JSONValue] = ["dashboardId": .string(first.manifest.dashboardId), "baseRevision": .string(first.manifest.revision), "name": .string("TV"), "target": try JSONValue.parse(JSONEncoder().encode(target)), "connections": .array([]), "files": .array([.object(["path": .string("index.html"), "text": .string(#"<script src="app.js"></script>"#)]), .object(["path": .string("app.js"), "text": .string(tv)])])]
        XCTAssertThrowsError(try service.updateDashboard(arguments: .object(args)))
        XCTAssertEqual(try service.getDashboard(dashboardId: first.manifest.dashboardId, revision: nil).manifest.revision, first.manifest.revision)
    }
}
