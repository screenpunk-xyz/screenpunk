import XCTest
@testable import WorkbenchCommand
import ScreenpunkController

final class WorkbenchWorkspaceConfigurationCLITests: XCTestCase {
    func testClosedWorkspaceConfigurationRoutes() throws {
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route(["workspace", "config", "get"])?.method,
            .workspaceConfigGet)
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route(["workspace", "config", "path"])?.method,
            .workspaceConfigPath)
        let set = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "config", "set", "theme", "dark", "2"]))
        XCTAssertEqual(set.method, .workspaceConfigSet)
        XCTAssertEqual(set.params["expectedGeneration"] as? Int, 2)
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "config", "unset", "theme", "3"])?.method,
            .workspaceConfigUnset)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "config", "set", "credential", "secret", "2"]))
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "config", "unset", "theme", "-1"]))
    }
}
