import XCTest
@testable import WorkbenchCommand

final class WorkbenchConfigAliasTests: XCTestCase {
    func testClosedPortableConfigAlias() throws {
        let parsed = try Options.parse(["config", "set", "theme", "dark", "2",
            "--scope", "workspace"], environment: [:])
        let routed = try WorkbenchCommand.workspaceConfigAlias(parsed.words)
        XCTAssertEqual(routed, ["workspace", "config", "set", "theme", "dark", "2"])
        XCTAssertEqual(try WorkbenchAuthoringRecoveryCLI.route(routed)?.method,
            .workspaceConfigSet)
        XCTAssertEqual(try WorkbenchCommand.workspaceConfigAlias([
            "config", "get", "--scope", "machine"]),
            ["config", "get", "--scope", "machine"])
        XCTAssertThrowsError(try WorkbenchCommand.workspaceConfigAlias([
            "config", "get", "--scope", "workspace", "unexpected"]))
    }
}
