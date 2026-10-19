import XCTest
@testable import ScreenpunkCore
final class CloudWorkspaceSetupOperationRecordTests: XCTestCase {
    private func pending(_ name: String = "Workspace") throws -> CloudWorkspaceSetupOperationRecord {
        try .init(userID: UUID(), request: .init(requestId: UUID(), workspaceName: name, locationName: "Location"))
    }
    private func receipt(_ requestID: UUID) throws -> CloudNativeWorkspaceSetupReceipt {
        let bytes = Data("{\"requestId\":\"\(requestID)\",\"accountId\":\"\(UUID())\",\"locationId\":\"\(UUID())\",\"createdAt\":\"2026-10-03T12:00:00.123456Z\"}".utf8)
        return try JSONDecoder().decode(CloudNativeWorkspaceSetupReceipt.self, from: bytes)
    }
    func testOperationReceiptLongFractionIsBoundedOnLinuxAndApple() throws {
        let value = try pending(), completed = try CloudWorkspaceSetupOperationRecord(userID: value.userID, request: value.request, receipt: receipt(value.request.requestId))
        let text = String(decoding: try completed.encoded(), as: UTF8.self)
        let long = "2026-10-03T12:00:00." + String(repeating: "1", count: 220) + "Z"
        let valid = Data(text.replacingOccurrences(of: "2026-10-03T12:00:00.123456Z", with: long).utf8)
        XCTAssertEqual(try CloudWorkspaceSetupOperationRecord.decode(valid).receipt?.createdAt, long)
        for count in [236, 4096] {
            let invalid = "2026-10-03T12:00:00." + String(repeating: "1", count: count) + "Z"
            XCTAssertThrowsError(try CloudWorkspaceSetupOperationRecord.decode(Data(text.replacingOccurrences(of: "2026-10-03T12:00:00.123456Z", with: invalid).utf8)))
        }
    }
    func testRoundTripAndExactUnicodeIdentity() throws {
        let value = try pending("é"); XCTAssertEqual(try .decode(value.encoded()), value)
        let other = try CloudWorkspaceSetupOperationRecord(userID: value.userID, request: .init(requestId: value.request.requestId, workspaceName: "e\u{301}", locationName: "Location"))
        XCTAssertNotEqual(value, other); XCTAssertFalse(value.permits(other, beginningSuccessor: false))
    }
    func testOnlyMatchingReceiptAndExplicitDifferentUUIDSuccessor() throws {
        let value = try pending(), completed = try CloudWorkspaceSetupOperationRecord(userID: value.userID, request: value.request, receipt: receipt(value.request.requestId))
        XCTAssertTrue(value.permits(completed, beginningSuccessor: false)); XCTAssertFalse(completed.permits(value, beginningSuccessor: false))
        let successor = try pending(); XCTAssertFalse(completed.permits(successor, beginningSuccessor: false)); XCTAssertTrue(completed.permits(successor, beginningSuccessor: true))
        XCTAssertFalse(completed.permits(value, beginningSuccessor: true))
        XCTAssertThrowsError(try CloudWorkspaceSetupOperationRecord(userID: value.userID, request: value.request, receipt: receipt(UUID())))
    }
    func testStrictVersionNestedKeysDuplicatesAndInvalidNames() throws {
        let value = try pending(), bytes = try value.encoded(), text = String(decoding: bytes, as: UTF8.self)
        for changed in [text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                        text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1"),
                        text.replacingOccurrences(of: "\"workspaceName\":\"Workspace\"", with: "\"workspaceName\":\"Workspace\",\"extra\":1"),
                        text.replacingOccurrences(of: "Workspace", with: "\\uD800"),
                        text.replacingOccurrences(of: "Workspace", with: " ") ] { XCTAssertThrowsError(try CloudWorkspaceSetupOperationRecord.decode(Data(changed.utf8))) }
        XCTAssertThrowsError(try CloudWorkspaceSetupOperationRecord.decode(Data(repeating: 32, count: 16 * 1024 + 1)))
    }
}
