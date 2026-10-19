import Foundation
import XCTest
@testable import ScreenpunkCore
final class NativeExcludedResetRootPathTests: XCTestCase {
    func testExistingAndFutureExcludedPathsRequirePhysicalComponents() throws {
        let supplied = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: supplied, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supplied) }
        let physical = try XCTUnwrap(realpath(supplied.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical))
        XCTAssertTrue(try NativeEnrollmentJournalStore.isPhysicalExcludedPath(root.path))
        XCTAssertTrue(try NativeEnrollmentJournalStore.isPhysicalExcludedPath(root.path + "/missing/reset"))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertFalse(try NativeEnrollmentJournalStore.isPhysicalExcludedPath(link.path + "/missing"))
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertFalse(try NativeEnrollmentJournalStore.isPhysicalExcludedPath(file.path + "/missing"))
        XCTAssertFalse(try NativeEnrollmentJournalStore.isPhysicalExcludedPath(root.path + "/../reset"))
    }
}
