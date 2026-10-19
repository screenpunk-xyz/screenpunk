import XCTest
import Foundation
@testable import WorkbenchCommand
import ScreenpunkController

final class WorkbenchPortableSourceCLITests: XCTestCase {
    func testPortableSourceRoutesStayTypedAndExplicit() throws {
        let id = UUID().uuidString.lowercased()
        let hash = String(repeating: "a", count: 64)
        let archive = "/private/tmp/source-export"
        let export = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "project", "export-source", id, "--source-version", hash, "--out", archive]))
        XCTAssertEqual(export.method, .projectSourceExport)
        XCTAssertNoThrow(try WorkbenchAuthoringRecoveryRequest.parse(method: export.method,
            params: export.params))
        let imported = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "project", "import-source", archive, "--to", "Screens/recovered"]))
        XCTAssertEqual(imported.method, .projectSourceImport)
        XCTAssertEqual(imported.params["name"] as? String, "recovered")
        let external = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "project", "open-external", "/private/tmp/external", "--external"]))
        XCTAssertEqual(external.method, .projectOpenExternal)
        XCTAssertEqual(external.params["explicitExternal"] as? Bool, true)
        let adopted = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "project", "adopt", id, "--source-version", hash, "--to", "Screens/adopted"]))
        XCTAssertEqual(adopted.method, .projectAdoptExternal)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "open-external", "/private/tmp/external"]))
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "project", "adopt", id, "--source-version", hash, "--to", "/private/tmp/outside"]))
    }
}
