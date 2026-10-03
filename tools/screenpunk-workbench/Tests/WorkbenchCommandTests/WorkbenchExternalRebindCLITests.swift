import XCTest
@testable import WorkbenchCommand
import ScreenpunkController

final class WorkbenchExternalRebindCLITests: XCTestCase {
    func testRequiresExplicitExternalDestinationAndFullSourceVersion() throws {
        let id = UUID().uuidString.lowercased()
        let hash = String(repeating: "a", count: 64)
        let route = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "project", "relocate", id, "--source-version", hash,
            "--to", "/private/tmp/external-new", "--external"]))
        XCTAssertEqual(route.method, .projectRelocateExternal)
        XCTAssertEqual(route.params["explicitExternal"] as? Bool, true)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "relocate", id, "--source-version", hash,
            "--to", "/private/tmp/external-new"]))
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "relocate", id, "--source-version", "short",
            "--to", "/private/tmp/external-new", "--external"]))
    }
}
