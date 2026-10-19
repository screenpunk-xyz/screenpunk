import XCTest
import Foundation
@testable import ScreenpunkBuildService

final class BuildRequestValidationTests: XCTestCase {
    func testRejectsPathBearingAndOversizedRequests() throws {
        let valid = """
        {"version":1,"projectID":"demo","jobID":"job-1","kitDirectory":"approved-kit","expectedSourceVersion":"\(String(repeating: "a", count: 64))"}
        """
        XCTAssertEqual(try BuildRequestValidation.decode(Data(valid.utf8)).jobID, "job-1")
        for hostile in ["../kit", "/absolute", "kit/path", "kit..other"] {
            let bytes = Data(valid.replacingOccurrences(of: "approved-kit", with: hostile).utf8)
            XCTAssertThrowsError(try BuildRequestValidation.decode(bytes))
        }
        XCTAssertThrowsError(try BuildRequestValidation.decode(Data(repeating: 65, count: BuildRequestValidation.maximumMessageBytes + 1)))
        XCTAssertFalse(BuildRequestValidation.sourceMember("TSConfig.JSON"))
        XCTAssertTrue(BuildRequestValidation.sourceMember(Array(repeating: "d", count: 31).joined(separator: "/") + "/main.tsx"))
        XCTAssertFalse(BuildRequestValidation.sourceMember(Array(repeating: "d", count: 32).joined(separator: "/") + "/main.tsx"))
    }
}
