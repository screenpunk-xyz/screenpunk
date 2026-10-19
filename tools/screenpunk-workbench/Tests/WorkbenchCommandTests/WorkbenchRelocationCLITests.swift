import XCTest
@testable import WorkbenchCommand
import ScreenpunkController

final class WorkbenchRelocationCLITests: XCTestCase {
    func testRelocationRequiresExactDestinationForm() throws {
        let route = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "relocate", "--to", "/private/tmp/new-library"]))
        XCTAssertEqual(route.method, .workspaceRelocate)
        XCTAssertEqual(route.params["path"] as? String, "/private/tmp/new-library")
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "relocate", "/private/tmp/new-library"]))
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "relocate", "--to", "relative"] ))
    }
}
