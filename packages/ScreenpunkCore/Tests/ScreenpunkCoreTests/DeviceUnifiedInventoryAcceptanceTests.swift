import Foundation
import XCTest
@testable import ScreenpunkCore

/// The durable fence is a prerequisite, not command admission. These assertions
/// deliberately do not manufacture controller/cloud authority or activation receipts.
final class DeviceUnifiedInventoryAcceptanceTests: XCTestCase {
    func testCloudPreparationBeforeTwoLocalIntentsRemainsStaleAfterRestartAndDuplicateDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = DeviceCommandIntentCoordinator(root: root)
        let cloudBeforeOffline = try fence.checkpoint()
        let controllerA = "controller-a:" + UUID().uuidString, controllerB = "controller-b:" + UUID().uuidString
        let digestA = String(repeating: "a", count: 64), digestB = String(repeating: "b", count: 64)
        try fence.acceptLocalDeployment(key: controllerA, digest: digestA)
        let cloudBetweenControllers = try fence.checkpoint()
        try fence.acceptLocalDeployment(key: controllerB, digest: digestB)
        let current = try fence.checkpoint()
        XCTAssertThrowsError(try fence.requireUnchanged(cloudBeforeOffline)) {
            guard case DeviceCommandIntentCoordinator.Failure.needsReview = $0 else { return XCTFail("stale cloud preparation must require review") }
        }
        XCTAssertThrowsError(try fence.requireUnchanged(cloudBetweenControllers))
        XCTAssertNoThrow(try fence.requireUnchanged(current))
        let reopened = DeviceCommandIntentCoordinator(root: root)
        XCTAssertNoThrow(try reopened.requireUnchanged(current))
        XCTAssertThrowsError(try reopened.requireUnchanged(cloudBeforeOffline))
        // Alternate transport cannot turn the same previously accepted deployment
        // into a new explicit intent after restart. Content receipts answer live retries.
        XCTAssertThrowsError(try reopened.acceptLocalDeployment(key: controllerA, digest: digestA)) {
            guard case DeviceCommandIntentCoordinator.Failure.needsReview = $0 else { return XCTFail("duplicate needs prior receipt/review") }
        }
        XCTAssertNoThrow(try reopened.requireUnchanged(current))
        XCTAssertThrowsError(try reopened.acceptLocalDeployment(key: controllerB, digest: digestA)) {
            guard case DeviceCommandIntentCoordinator.Failure.conflictingOperation = $0 else { return XCTFail("changed retry must fail closed") }
        }
        XCTAssertNoThrow(try reopened.requireUnchanged(current))
        // Explicit reapplication gets a new identity. Its accepted intent fences
        // every older slow preparation; background reads alone retain the fence.
        try reopened.acceptLocalIntent(operationID: UUID())
        XCTAssertThrowsError(try reopened.requireUnchanged(current))
        let reapplied = try reopened.checkpoint()
        XCTAssertEqual(try reopened.checkpoint(), reapplied)
        XCTAssertNoThrow(try DeviceCommandIntentCoordinator(root: root).requireUnchanged(reapplied))
    }
}
