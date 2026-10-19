import XCTest
@testable import WorkbenchCommand
import ScreenpunkController

final class WorkbenchProjectCloneCLITests: XCTestCase {
    func testRequiresExactSourceHashAndContainedDestination() throws {
        let id = UUID().uuidString.lowercased()
        let hash = String(repeating: "a", count: 64)
        let route = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "project", "clone", id, "--source-version", hash,
            "--to", "Screens/copied"]))
        XCTAssertEqual(route.method, .projectClone)
        XCTAssertEqual(route.params["name"] as? String, "copied")
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "clone", id, "--source-version", hash])?.method, .projectClone)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "clone", id, "--source-version", hash,
            "--to", "/private/tmp/outside"]))
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "clone", id, "--source-version", "short"]))
    }
}
