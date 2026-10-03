import XCTest
import Foundation
@testable import WorkbenchCommand
import ScreenpunkController

final class WorkbenchSnapshotOptionsCLITests: XCTestCase {
    func testSnapshotFlagsReachClosedRequest() throws {
        let routed = try XCTUnwrap(WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "snapshot", "--out", "/private/tmp/snapshot",
            "--include-external", "--allow-incomplete"]))
        XCTAssertEqual(routed.method, .snapshotCreate)
        guard case .snapshotCreate(let path, let include, let allow) =
            try WorkbenchAuthoringRecoveryRequest.parse(method: routed.method,
                params: routed.params) else { return XCTFail("Expected snapshot request") }
        XCTAssertEqual(path, "/private/tmp/snapshot")
        XCTAssertTrue(include)
        XCTAssertTrue(allow)
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryCLI.route([
            "workspace", "snapshot", "--out", "/private/tmp/snapshot",
            "--include-external", "--include-external"]))
    }
}
