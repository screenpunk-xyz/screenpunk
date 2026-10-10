import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceCommandIntentCoordinatorTests: XCTestCase {
    func testAutomationFenceRequiresActualExplicitCommitAndRejectsNewPendingIntentAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeviceCommandIntentCoordinator(root: root), inventory = UUID()
        let initial = try coordinator.checkpoint()
        XCTAssertThrowsError(try coordinator.automationCheckpoint(baseGenerationID: inventory))
        try coordinator.recordCommittedInventory(checkpoint: initial, generationID: inventory)
        XCTAssertEqual(try coordinator.automationCheckpoint(baseGenerationID: inventory), initial)
        let restored = DeviceCommandIntentCoordinator(root: root)
        XCTAssertEqual(try restored.automationCheckpoint(baseGenerationID: inventory), initial)
        try restored.acceptLocalIntent()
        XCTAssertThrowsError(try restored.automationCheckpoint(baseGenerationID: inventory))
        XCTAssertThrowsError(try restored.requireUnchanged(initial))
        XCTAssertThrowsError(try restored.recordCommittedInventory(checkpoint: initial, generationID: inventory))
        let fresh = try restored.checkpoint(), next = UUID()
        try restored.recordCommittedInventory(checkpoint: fresh, generationID: next)
        XCTAssertEqual(try restored.automationCheckpoint(baseGenerationID: next), fresh)
        XCTAssertThrowsError(try restored.automationCheckpoint(baseGenerationID: inventory))
    }
    func testRejectsSymlinkJournalAndPhysicalRootReplacement() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("intent"), coordinator = DeviceCommandIntentCoordinator(root: root)
        _ = try coordinator.checkpoint()
        let journal = root.appendingPathComponent("command-intent.json")
        let bytes = try Data(contentsOf: journal), outside = parent.appendingPathComponent("outside.json")
        try bytes.write(to: outside); try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        XCTAssertThrowsError(try coordinator.checkpoint())
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        try FileManager.default.removeItem(at: journal); try bytes.write(to: journal)
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try coordinator.checkpoint())
    }
    func testCloudAcceptanceKeepsOriginalFenceAcrossDuplicateTransportAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeviceCommandIntentCoordinator(root: root)
        let original = try coordinator.checkpoint()
        let operation = UUID(), key = "cloud:installation:" + operation.uuidString, digest = String(repeating: "a", count: 64)
        let accepted = try coordinator.acceptCloudDeployment(operationID: operation, key: key, digest: digest)
        XCTAssertNotEqual(original, accepted)
        XCTAssertEqual(try coordinator.acceptCloudDeployment(operationID: operation, key: key, digest: digest), accepted)
        let restarted = DeviceCommandIntentCoordinator(root: root)
        XCTAssertEqual(try restarted.acceptCloudDeployment(operationID: operation, key: key, digest: digest), accepted)
        XCTAssertThrowsError(try restarted.acceptCloudDeployment(operationID: operation, key: key, digest: String(repeating: "b", count: 64)))
        XCTAssertEqual(try restarted.checkpoint(), accepted)
        let newer = try restarted.acceptCloudDeployment(operationID: UUID(), key: "cloud:newer", digest: digest)
        XCTAssertNotEqual(newer, accepted)
        XCTAssertThrowsError(try coordinator.requireUnchanged(accepted))
        XCTAssertThrowsError(try restarted.acceptCloudDeployment(operationID: operation, key: key, digest: digest))
        XCTAssertEqual(try restarted.checkpoint(), newer)
        try restarted.acceptLocalIntent()
        XCTAssertThrowsError(try coordinator.requireUnchanged(newer))
    }
    func testRestartPreservesFenceAndLocalIntentRequiresCloudReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeviceCommandIntentCoordinator(root: root)
        let cloud = try coordinator.checkpoint()
        let restarted = DeviceCommandIntentCoordinator(root: root)
        try restarted.requireUnchanged(cloud)
        try restarted.acceptLocalIntent()
        XCTAssertThrowsError(try coordinator.requireUnchanged(cloud)) { error in
            guard case DeviceCommandIntentCoordinator.Failure.needsReview = error else { return XCTFail("Unexpected failure: \(error)") }
        }
        try coordinator.requireUnchanged(restarted.checkpoint())
    }
    func testCorruptHistoryCannotRegenerateGenesis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeviceCommandIntentCoordinator(root: root)
        _ = try coordinator.checkpoint()
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("command-intent.json"))
        XCTAssertThrowsError(try coordinator.checkpoint())
        XCTAssertThrowsError(try coordinator.acceptLocalIntent())
    }
    func testRemovedDeploymentCannotReplayAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeviceCommandIntentCoordinator(root: root)
        let digest = String(repeating: "a", count: 64)
        try coordinator.acceptLocalDeployment(key: "controller:deployment", digest: digest)
        try coordinator.acceptLocalIntent() // explicit removal preserves deployment history
        let restarted = DeviceCommandIntentCoordinator(root: root)
        XCTAssertThrowsError(try restarted.acceptLocalDeployment(key: "controller:deployment", digest: digest))
        XCTAssertThrowsError(try restarted.acceptLocalDeployment(key: "controller:deployment", digest: String(repeating: "b", count: 64)))
    }

}
