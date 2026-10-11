import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceMixedInventoryStoreTests: XCTestCase {
    func testExactAttachmentDigestMatchesSHA256VectorsAndStreamingBytes() throws {
        let vectors: [(Data, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        ]
        for (bytes, expected) in vectors {
            XCTAssertEqual(try DeviceNativeDeliveryAttachmentCodec.hash(bytes), expected)
            var portable = NativeJournalSHA256()
            for byte in bytes { try portable.update([byte]) }
            XCTAssertEqual(portable.finalized().map { String(format: "%02x", $0) }.joined(), expected)
        }
        let emptySet = try DeviceResultingSetCandidate.validating(entries: [], configuredEntryID: nil)
        XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetDigest(emptySet),
            "7efdd4c8adef942abf0785ef0134406d55cb6a340db7b19ddea6c20a82412dbd")
        let bytes = Data((0..<32768).map { UInt8(truncatingIfNeeded: $0) })
        var portable = NativeJournalSHA256(); try portable.update(bytes)
        XCTAssertEqual(try DeviceNativeDeliveryAttachmentCodec.hash(bytes),
            portable.finalized().map { String(format: "%02x", $0) }.joined())
        XCTAssertNotEqual(try DeviceNativeDeliveryAttachmentCodec.hash(bytes),
            try DeviceNativeDeliveryAttachmentCodec.hash(bytes + Data([0])))
    }

    private func scope<T>(_ store: DeviceMixedInventoryStore, _ body: (DeviceLocalResourcePermit) throws -> T) throws -> T {
        try DeviceMixedInventoryQualificationHarness.scope(store, body: body)
    }

    // Resource journal qualification only; authenticated acceptance is exercised
    // by the genuine Apple fixed-owner integration fixture, not this harness.
    func testUnactivatedRejectionPreservesHeadRestartsAndCannotRejectCommittedCAS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), store = DeviceMixedInventoryStore(root: root, rootID: id); try store.initializeExplicit()
        let owner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let state = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner, entries: [], configuredEntryID: nil)
        let capture = try scope(store) { try store.commitExact(operationID: UUID(), previous: nil, candidate: state, admissionEnabled: true, permit: $0).0 }
        let plan = Data("fixed reviewed plan".utf8), nativeOperation = UUID(), desired = UUID()
        let set = try DeviceResultingSetCandidate.validating(entries: [], configuredEntryID: nil)
        let association: [String: Any] = ["schemaVersion": 1, "operationId": UUID().uuidString.lowercased(), "planId": UUID().uuidString.lowercased(),
            "installationId": owner.installationID.uuidString.lowercased(), "accountId": owner.accountID.uuidString.lowercased(), "locationId": NSNull(),
            "transitionId": owner.transitionID.uuidString.lowercased(), "planDigest": try DeviceNativeDeliveryAttachmentCodec.hash(plan), "planByteLength": plan.count]
        var wire = association
        wire["sequence"] = "1"; wire["executionExpiresAt"] = "2026-10-10T20:00:00Z"
        wire["expectedInstalledSetGenerationId"] = state.generationID.uuidString.lowercased(); wire["desiredSetGenerationId"] = desired.uuidString.lowercased()
        wire["resultingSet"] = ["schemaVersion": 1, "entries": [], "configuredEntryId": NSNull()]
        wire["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(set)
        let header = try JSONSerialization.data(withJSONObject: association).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let binding = try DeviceNativeDeliveryCommandBinding.bindMixed(command: JSONSerialization.data(withJSONObject: wire),
            associationHeader: header, rawPlan: plan, nativeOperationID: nativeOperation, journalRootID: UUID(), capture: capture)
        try scope(store) { try store.retainCloudAcceptedExact(binding: binding, previous: capture, permit: $0) }
        let outcome = try DeviceNativeDeliveryHTTPCodec.notActivatedRequest(binding: binding)
        XCTAssertTrue(try scope(store) { try store.retainCloudRejectionExact(binding: binding, bytes: outcome, acknowledgment: false, permit: $0) })
        XCTAssertEqual(try store.readCurrent()?.bytes, capture.bytes)
        let reopened = DeviceMixedInventoryStore(root: root, rootID: id)
        let pending = try reopened.pendingCloudRejectionsExact()
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending[0].outcome, outcome)
        XCTAssertTrue(try scope(reopened) { try reopened.retainCloudRejectionExact(binding: pending[0].binding, bytes: Data("typed fixed receipt".utf8), acknowledgment: true, permit: $0) })
        XCTAssertTrue(try reopened.pendingCloudRejectionsExact().isEmpty)
        XCTAssertTrue(try reopened.isCloudRejectedExact(operationID: binding.association.operationID))
        let next = try DeviceMixedStructuralState.validating(generationID: desired, installationOwner: owner, entries: [], configuredEntryID: nil)
        _ = try scope(store) { try store.commitExact(operationID: nativeOperation, previous: capture, candidate: next, admissionEnabled: true, permit: $0) }
        XCTAssertFalse(try scope(store) { try store.retainCloudRejectionExact(binding: binding, bytes: outcome, acknowledgment: false, permit: $0) }, "Never claim an already committed generation was unactivated")
    }
    func testStagedRootPromotionRetainsPhysicalBindingThroughParentAlias() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let staged = parent.appendingPathComponent("staged", isDirectory: true)
        let final = parent.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        let id = UUID()
        try DeviceMixedInventoryStore(root: staged, rootID: id).initializeExplicit(recordedFinalRoot: final)
        try FileManager.default.moveItem(at: staged, to: final)
        let reopened = DeviceMixedInventoryStore(root: final, rootID: id)
        try reopened.initializeExplicit()
        XCTAssertNil(try reopened.readCurrent())
        XCTAssertThrowsError(try DeviceMixedInventoryStore(root: final, rootID: UUID()).initializeExplicit())
    }
    func testOfflineObservationsCoalesceUnsentStatesAndPreserveIssuedCAS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceMixedInventoryStore(root: root, rootID: UUID()); try store.initializeExplicit()
        let owner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let serverGeneration = UUID()
        var capture: DeviceMixedInventoryStore.Capture?
        func commitAndEnqueue() throws -> DeviceMixedInventoryStore.CloudObservation {
            let candidate = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner, entries: [], configuredEntryID: nil)
            capture = try scope(store) { try store.commitExact(operationID: UUID(), previous: capture, candidate: candidate, admissionEnabled: true, permit: $0).0 }
            let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "installationId": owner.installationID.uuidString.lowercased(),
                "transitionId": owner.transitionID.uuidString.lowercased(), "generationId": candidate.generationID.uuidString.lowercased(),
                "entries": [], "configuredEntryId": NSNull()], options: [.sortedKeys])
            return try scope(store) { permit in
                try store.initializeCloudObservationCheckpointExact(serverGeneration, permit: permit)
                return try store.enqueueCloudObservationExact(capture!, stateBytes: bytes, permit: permit)
            }
        }
        let obsolete = try commitAndEnqueue()
        let latestOffline = try commitAndEnqueue()
        XCTAssertNotEqual(obsolete.generationID, latestOffline.generationID)
        XCTAssertEqual(latestOffline.previousGenerationID, serverGeneration)
        XCTAssertEqual(try store.nextCloudObservationExact(), latestOffline)
        let obsoleteTail = try commitAndEnqueue()
        let latestTail = try commitAndEnqueue()
        XCTAssertNotEqual(obsoleteTail.generationID, latestTail.generationID)
        XCTAssertEqual(try store.nextCloudObservationExact(), latestOffline)
        try store.acknowledgeCloudObservationExact(latestOffline)
        XCTAssertEqual(try store.nextCloudObservationExact(), latestTail)
        XCTAssertEqual(latestTail.previousGenerationID, latestOffline.generationID)
        XCTAssertEqual(try DeviceMixedInventoryStore(root: root, rootID: store.rootID).readCurrent()?.snapshot.generationID, latestTail.generationID)
    }
    func testDurableCASReplayRollbackAndCorruptReceiptFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID(), store = DeviceMixedInventoryStore(root: root, rootID: rootID)
        try store.initializeExplicit()
        let owner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let first = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner, entries: [], configuredEntryID: nil)
        let operation = UUID()
        let committed = try scope(store) { try store.commitExact(operationID: operation, previous: nil, candidate: first, admissionEnabled: true, permit: $0) }
        let retry = try scope(store) { try store.commitExact(operationID: operation, previous: nil, candidate: first, admissionEnabled: true, permit: $0) }
        XCTAssertEqual(committed.1, retry.1)
        try scope(store) { try store.retainMountedEmptyExact(committed.0, permit: $0) }
        let blank = try DeviceMixedInventoryStore(root: root, rootID: rootID).mountedExact()
        XCTAssertEqual(blank?.generationID, first.generationID)
        XCTAssertNil(blank?.entryID)
        XCTAssertNil(blank?.manifestDigest)
        let baseline = UUID()
        let state = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "installationId": owner.installationID.uuidString.lowercased(), "transitionId": owner.transitionID.uuidString.lowercased(),
            "generationId": first.generationID.uuidString.lowercased(), "entries": [], "configuredEntryId": NSNull()], options: [.sortedKeys])
        let queued = try scope(store) { permit in
            try store.initializeCloudObservationCheckpointExact(baseline, permit: permit)
            return try store.enqueueCloudObservationExact(committed.0, stateBytes: state, permit: permit)
        }
        XCTAssertEqual(queued.previousGenerationID, baseline)
        XCTAssertEqual(try DeviceMixedInventoryStore(root: root, rootID: rootID).nextCloudObservationExact(), queued)
        try store.acknowledgeCloudObservationExact(queued)
        try store.acknowledgeCloudObservationExact(queued)
        XCTAssertNil(try store.nextCloudObservationExact())
        let receiptPath = root.appendingPathComponent(operation.uuidString.lowercased() + ".mixed-receipt.json")
        try FileManager.default.removeItem(at: receiptPath)
        XCTAssertThrowsError(try store.readCurrent())
        let recovered = try scope(store) { try store.commitExact(operationID: operation, previous: nil, candidate: first, admissionEnabled: true, permit: $0) }
        XCTAssertEqual(recovered.1, committed.1)
        let reopened = DeviceMixedInventoryStore(root: root, rootID: rootID)
        XCTAssertEqual(try reopened.readCurrent()?.snapshot, first)
        let next = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner, entries: [], configuredEntryID: nil)
        XCTAssertThrowsError(try scope(store) { try store.commitExact(operationID: UUID(), previous: committed.0, candidate: next, admissionEnabled: false, permit: $0) })
        XCTAssertEqual(try reopened.readCurrent()?.snapshot, first)
        XCTAssertThrowsError(try scope(store) { try store.commitExact(operationID: UUID(), previous: nil, candidate: next, admissionEnabled: true, permit: $0) })
        try Data("{}".utf8).write(to: root.appendingPathComponent(operation.uuidString.lowercased() + ".mixed-receipt.json"))
        XCTAssertThrowsError(try reopened.readCurrent())
    }
}
