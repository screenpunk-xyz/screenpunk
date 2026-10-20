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

    private func fixtureCoordinator(root: URL, home: URL) -> DeviceCommandIntentCoordinator {
        DeviceCommandIntentCoordinator(root: root, contextFactory: { currentRoot, heldRoot in
            try DevicePersistedFilesystemContext.syntheticCurrentAppHomeForTesting(
                currentRoot: currentRoot, heldRoot: heldRoot, systemHome: home.path, physicalHome: home.path)
        })
    }
    /// The fixture retains a historical device value, not a pretend physical remount.
    /// Command records have no filesystem epoch fields; exercise actual coordinator history.
    private func retainHistoricalRootDevice(_ root: URL) throws -> Data {
        let file = root.appendingPathComponent("command-root.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let current = try XCTUnwrap(value["device"] as? NSNumber).uint64Value
        value["device"] = NSNumber(value: current ^ 0x4000)
        let original = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try original.write(to: file)
        return original
    }
    func testHistoricalRootDevicePreservesFenceDedupAndCommittedHistoryAcrossReopens() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("intent"), seed = DeviceCommandIntentCoordinator(root: root)
        let digest = String(repeating: "a", count: 64), operation = UUID(), key = "cloud:" + operation.uuidString
        try seed.acceptLocalDeployment(key: "controller:old", digest: digest)
        let accepted = try seed.acceptCloudDeployment(operationID: operation, key: key, digest: digest)
        let inventory = UUID()
        try seed.recordCommittedInventory(checkpoint: accepted, generationID: inventory)
        let originalBinding = try retainHistoricalRootDevice(root)
        let journal = root.appendingPathComponent("command-intent.json"), before = try Data(contentsOf: journal)
        let first = fixtureCoordinator(root: root, home: home)
        XCTAssertEqual(try first.checkpoint(), accepted)
        XCTAssertEqual(try first.acceptCloudDeployment(operationID: operation, key: key, digest: digest), accepted)
        XCTAssertEqual(try first.automationCheckpoint(baseGenerationID: inventory), accepted)
        XCTAssertTrue(try first.knownDeployment(key: "controller:old", digest: digest))
        XCTAssertThrowsError(try first.acceptLocalDeployment(key: "controller:old", digest: digest))
        XCTAssertEqual(try Data(contentsOf: journal), before, "Read/retry must preserve the exact durable history")
        try first.acceptLocalIntent()
        XCTAssertThrowsError(try first.requireUnchanged(accepted))
        XCTAssertThrowsError(try first.acceptCloudDeployment(operationID: operation, key: key, digest: digest))
        let latest = try first.checkpoint(), nextInventory = UUID()
        try first.recordCommittedInventory(checkpoint: latest, generationID: nextInventory)
        let written = try Data(contentsOf: journal)
        let second = fixtureCoordinator(root: root, home: home)
        XCTAssertEqual(try second.automationCheckpoint(baseGenerationID: nextInventory), latest)
        XCTAssertThrowsError(try second.automationCheckpoint(baseGenerationID: inventory))
        XCTAssertThrowsError(try second.acceptLocalDeployment(key: "controller:old", digest: digest))
        XCTAssertThrowsError(try second.acceptCloudDeployment(operationID: operation, key: key, digest: digest))
        XCTAssertEqual(try Data(contentsOf: journal), written)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("command-root.json")), originalBinding,
            "No root identity/schema/history rewrite after genuine normal writes and repeated reopen")
    }
    func testHistoricalRootPolicyStaysConfinedAndRejectsReplacedRootAndSymlinkJournal() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("intent"), seed = DeviceCommandIntentCoordinator(root: root)
        let checkpoint = try seed.checkpoint(), binding = try retainHistoricalRootDevice(root)
        let journal = root.appendingPathComponent("command-intent.json"), bytes = try Data(contentsOf: journal)
        #if !os(iOS)
        XCTAssertThrowsError(try DeviceCommandIntentCoordinator(root: root).checkpoint(), "Non-iOS production must remain strict")
        #endif
        let outsideHome = home.appendingPathComponent("different-home")
        try FileManager.default.createDirectory(at: outsideHome, withIntermediateDirectories: false)
        XCTAssertThrowsError(try fixtureCoordinator(root: root, home: outsideHome).checkpoint())
        let admitted = fixtureCoordinator(root: root, home: home)
        try admitted.requireUnchanged(checkpoint)
        let outside = home.appendingPathComponent("outside.json")
        try bytes.write(to: outside); try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        XCTAssertThrowsError(try admitted.checkpoint())
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        try FileManager.default.removeItem(at: journal); try bytes.write(to: journal)
        try FileManager.default.moveItem(at: root, to: home.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try binding.write(to: root.appendingPathComponent("command-root.json"))
        try bytes.write(to: root.appendingPathComponent("command-intent.json"))
        XCTAssertThrowsError(try admitted.checkpoint(), "Same process raw pin must reject root replacement")
        XCTAssertThrowsError(try fixtureCoordinator(root: root, home: home).checkpoint(), "Historical inode remains exact")
    }

    func testFilesystemContextCaptureKeepsPublicFailureCategories() throws {
        enum CaptureFailure: Error { case unavailable }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("intent")
        let coordinator = DeviceCommandIntentCoordinator(root: root, contextFactory: { _, _ in
            throw CaptureFailure.unavailable
        })
        // An absent journal first reaches save/root capture: preserve persistence failure.
        XCTAssertThrowsError(try coordinator.checkpoint()) { error in
            guard case DeviceCommandIntentCoordinator.Failure.persistence = error else {
                return XCTFail("Capture leaked an unexpected error: \(error)")
            }
        }
        // Existing-root reads retain load()'s established fail-closed journal category.
        XCTAssertThrowsError(try coordinator.checkpoint()) { error in
            guard case DeviceCommandIntentCoordinator.Failure.corruptJournal = error else {
                return XCTFail("Read leaked an unexpected error: \(error)")
            }
        }
    }

}
