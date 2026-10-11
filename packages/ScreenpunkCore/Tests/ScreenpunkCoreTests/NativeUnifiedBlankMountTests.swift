import XCTest
@_spi(NativeInstallation) @testable import ScreenpunkCore

final class NativeUnifiedBlankMountTests: XCTestCase {
    func testBlankReceiptRequiresExactGenerationAndNullEntry() throws {
        let id = UUID()
        let observation = NativeUnifiedBlankMount(generationID: id, installationID: UUID(), validate: {})
        let valid: [String: Any] = ["schemaVersion": 1, "generationId": id.uuidString.lowercased(), "entryId": NSNull(), "accepted": true]
        try observation.validateReceipt(JSONSerialization.data(withJSONObject: valid))
        for replacement in [UUID().uuidString.lowercased(), "not-null"] {
            var wrong = valid
            wrong[replacement == "not-null" ? "entryId" : "generationId"] = replacement
            XCTAssertThrowsError(try observation.validateReceipt(JSONSerialization.data(withJSONObject: wrong)))
        }
        var booleanVersion = valid; booleanVersion["schemaVersion"] = true
        XCTAssertThrowsError(try observation.validateReceipt(JSONSerialization.data(withJSONObject: booleanVersion)))
        var numeric = valid; numeric["accepted"] = 1
        XCTAssertThrowsError(try observation.validateReceipt(JSONSerialization.data(withJSONObject: numeric)))
    }
    func testSupersededBlankCannotProduceOrAcceptObservation() throws {
        var current = true
        let id = UUID()
        let observation = NativeUnifiedBlankMount(generationID: id, installationID: UUID(), validate: {
            guard current else { throw NativeEnrollmentPromotionError.blocked }
        })
        _ = try observation.validatedBody()
        current = false
        XCTAssertThrowsError(try observation.validatedBody())
        XCTAssertThrowsError(try observation.validateReceipt(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "generationId": id.uuidString.lowercased(), "entryId": NSNull(), "accepted": true])))
    }
}
