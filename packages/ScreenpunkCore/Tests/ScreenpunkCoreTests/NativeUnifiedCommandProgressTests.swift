import XCTest
@testable @_spi(NativeInstallation) import ScreenpunkCore

final class NativeUnifiedCommandProgressTests: XCTestCase {
    func testProgressRetainsExactCommandAndRejectsActivationReceipt() throws {
        let operation = UUID(), generation = UUID()
        var checks = 0
        let progress = NativeUnifiedCommandProgress(operationID: operation, expectedGenerationID: generation, validate: { checks += 1 })
        let body = try JSONSerialization.jsonObject(with: progress.validatedBody(phase: .preparing)) as! [String: String]
        XCTAssertEqual(body, ["operationId": operation.uuidString.lowercased(), "expectedGenerationId": generation.uuidString.lowercased(), "phase": "preparing"])
        let receipt = try JSONSerialization.data(withJSONObject: ["operationId": operation.uuidString.lowercased(), "phase": "preparing", "accepted": true])
        try progress.validateReceipt(receipt, phase: .preparing)
        XCTAssertEqual(checks, 2)
        XCTAssertThrowsError(try progress.validateReceipt(receipt, phase: .superseded))
        let wrong = try JSONSerialization.data(withJSONObject: ["operationId": UUID().uuidString.lowercased(), "phase": "preparing", "accepted": true])
        XCTAssertThrowsError(try progress.validateReceipt(wrong, phase: .preparing))
        let activation = try JSONSerialization.data(withJSONObject: ["operationId": operation.uuidString.lowercased(), "phase": "preparing", "accepted": true, "outcome": "activated"])
        XCTAssertThrowsError(try progress.validateReceipt(activation, phase: .preparing))
        let numeric = try JSONSerialization.data(withJSONObject: ["operationId": operation.uuidString.lowercased(), "phase": "preparing", "accepted": 1])
        XCTAssertThrowsError(try progress.validateReceipt(numeric, phase: .preparing))
    }
    func testRetiredProofFailsBeforeBodyOrReceipt() throws {
        var valid = true
        let progress = NativeUnifiedCommandProgress(operationID: UUID(), expectedGenerationID: UUID(), validate: { if !valid { throw NativeDeliveryExecutionError.association } })
        _ = try progress.validatedBody(phase: .superseded)
        valid = false
        XCTAssertThrowsError(try progress.validatedBody(phase: .preparing))
        XCTAssertThrowsError(try progress.validateReceipt(Data("{}".utf8), phase: .superseded))
    }
    func testMountFailurePreservesCommittedGenerationAndRejectsLateProof() throws {
        let operation = UUID(), expected = UUID(), committed = UUID()
        var current = true
        var acknowledgments = 0
        let failure = NativeUnifiedCommandMountFailure(operationID: operation, expectedGenerationID: expected,
            committedGenerationID: committed, validate: { if !current { throw NativeDeliveryExecutionError.association } }, acknowledge: { _ in acknowledgments += 1 })
        let body = try JSONSerialization.jsonObject(with: failure.validatedBody(code: .navigationFailed)) as! [String: String]
        XCTAssertEqual(body["phase"], "failed"); XCTAssertEqual(body["committedGenerationId"], committed.uuidString.lowercased())
        XCTAssertEqual(body["expectedGenerationId"], expected.uuidString.lowercased()); XCTAssertEqual(body["failureCode"], "navigation_failed")
        let receipt = try JSONSerialization.data(withJSONObject: ["operationId": operation.uuidString.lowercased(), "phase": "failed", "accepted": true])
        let wrongReceipt = try JSONSerialization.data(withJSONObject: ["operationId": UUID().uuidString.lowercased(), "phase": "failed", "accepted": true])
        XCTAssertThrowsError(try failure.validateReceipt(wrongReceipt))
        XCTAssertEqual(acknowledgments, 0)
        try failure.validateReceipt(receipt)
        XCTAssertEqual(acknowledgments, 1)
        current = false
        XCTAssertThrowsError(try failure.validatedBody(code: .renderProcessTerminated))
        XCTAssertThrowsError(try failure.validateReceipt(receipt))
        XCTAssertEqual(acknowledgments, 1)
    }

}
