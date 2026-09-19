import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class NavigationAuthoringTests: XCTestCase {
    func testDeclarationsSurviveEditsAndDevicePreparationAndCanBeCleared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        let target = ManifestTarget(profileId: "phone", width: 390, height: 844, scale: 1, orientation: "portrait")
        let files = [DashboardFileInput(path: "index.html", text: "<html>Home</html>"), DashboardFileInput(path: "door.html", text: "<html>Door</html>")]
        let pages = [DashboardPage(id: "home", name: "Home", path: "index.html"), DashboardPage(id: "door", name: "Door", path: "door.html")]
        let connections = [ManifestConnection(alias: "events", required: false, operations: [.init(name: "read", kind: "http")])]
        let rules = [ManifestEventRule(id: "door", name: "Door", source: .init(mode: .poll, alias: "events", operation: "read"), condition: .init(field: ["active"], equals: .bool(true)), defaults: .init(pageId: "door", returnBehavior: .conditionClear))]
        let first = try store.putDashboard(dashboardId: nil, name: "House", baseRevision: nil, target: target, connections: connections, files: files, pages: pages, defaultPageId: "home", eventRules: rules)
        let edit = try store.putDashboard(dashboardId: first.manifest.dashboardId, name: "House", baseRevision: first.manifest.revision, target: target, connections: connections, files: files)
        XCTAssertEqual(edit.manifest.pages, pages)
        XCTAssertEqual(edit.manifest.eventRules, rules)
        let loaded = try store.getRevision(dashboardId: first.manifest.dashboardId, revision: nil)
        let prepared = try ScreenPackagePreparation.prepare(loaded, for: .init(deviceId: "ipad", name: "iPad", width: 768, height: 1024), orientation: .portrait, root: root)
        XCTAssertEqual(prepared.manifest.eventRules, rules)
        XCTAssertEqual(prepared.manifest.defaultPageId, "home")
        let clear = try store.putDashboard(dashboardId: edit.manifest.dashboardId, name: "House", baseRevision: edit.manifest.revision, target: target, connections: [], files: files, pages: [], eventRules: [])
        XCTAssertNil(clear.manifest.pages)
        XCTAssertEqual(clear.manifest.eventRules, [])
        XCTAssertEqual(clear.manifest.resolvedDefaultPageId, "default")
    }

    func testJSONNumbersDoNotBecomeBooleanConditionValues() throws {
        let value = try JSONValue.parse(Data("{\"one\":1,\"zero\":0,\"yes\":true}".utf8))
        XCTAssertEqual(value["one"], .int(1))
        XCTAssertEqual(value["zero"], .int(0))
        XCTAssertEqual(value["yes"], .bool(true))
    }
}
