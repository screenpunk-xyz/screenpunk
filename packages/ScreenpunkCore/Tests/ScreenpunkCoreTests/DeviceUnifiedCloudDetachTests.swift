#if DEBUG || SCREENPUNK_CORE_TESTING
import Foundation
import XCTest
@_spi(NativeInstallation) @testable import ScreenpunkCore

/// Journal/resource qualification only. Synthetic records never mint a genuine
/// server-revocation observation or credential-retirement capability.
final class DeviceUnifiedCloudDetachTests: XCTestCase {
    private final class Ledger {
        let root: URL, rootID = UUID()
        let owner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let store: DeviceMixedInventoryStore
        let initialOperation = UUID()
        var current: DeviceMixedInventoryStore.Capture!
        init(entries: [DeviceMixedStructuralState.Entry] = []) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("logout-ledger-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            store = DeviceMixedInventoryStore(root: root, rootID: rootID)
            try store.initializeExplicit()
            let initial = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner,
                entries: entries, configuredEntryID: entries.first?.entryID)
            current = try DeviceMixedInventoryQualificationHarness.scope(store) {
                try store.commitExact(operationID: initialOperation, previous: nil, candidate: initial, admissionEnabled: true, permit: $0).0
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func append(_ candidate: DeviceMixedStructuralState, operationID: UUID, currentInstalled: Bool, receiptInstalled: Bool) throws {
            let bytes = try DeviceMixedStructuralStateCodec.encode(candidate)
            let intent = DeviceMixedInventoryStore.Intent(operationID: operationID, previous: current.bytes, candidate: bytes)
            try DeviceLocalCompleteSetBounds.encode(intent, maximum: 384 * 1024).write(to: root.appendingPathComponent(operationID.uuidString.lowercased() + ".mixed-intent.json"))
            if currentInstalled { try bytes.write(to: root.appendingPathComponent("mixed-current.json")) }
            if receiptInstalled {
                let receipt = DeviceMixedInventoryStore.Receipt(operationID: operationID, generationID: candidate.generationID,
                    digest: try DeviceNativeDeliveryAttachmentCodec.hash(bytes))
                try DeviceLocalCompleteSetBounds.encode(receipt, maximum: 8192).write(to: root.appendingPathComponent(operationID.uuidString.lowercased() + ".mixed-receipt.json"))
            }
        }
        func reopen() throws {
            let reopened = DeviceMixedInventoryStore(root: root, rootID: rootID)
            try reopened.recommitPendingCloudAttachmentExact()
            current = try XCTUnwrap(reopened.readCurrent())
        }
    }
    private func localEntry() -> DeviceMixedStructuralState.Entry {
        let digest = String(repeating: "a", count: 64), directory = "package.staging-cas-v1-" + digest
        let revision = StoredRevision(revision: "retained-original", dashboardId: UUID().uuidString.lowercased(), name: "Local screen",
            digest: digest, orientation: .landscape, width: 1280, height: 720)
        return .retainedLocal(.init(entry: .init(entryID: UUID(), displayName: "Local screen", revision: revision, packageDirectory: directory),
            package: .init(rootID: UUID(), contentID: digest, preparationOperationID: UUID(), directory: directory),
            grant: .init(identity: .init(rootID: UUID(), revisionID: UUID()), preparationOperationID: UUID()),
            owner: .init(role: .controller, publicKey: Array(repeating: 7, count: PairingLimits.identityByteCount))))
    }
    func testLegacySchemaRemainsByteExactAndDetachedCodecPreservesLocalOwnersAndSelection() throws {
        let entry = localEntry(), f = try Ledger(entries: [entry])
        let old = f.current.bytes
        XCTAssertEqual(try DeviceMixedStructuralStateCodec.encode(DeviceMixedStructuralStateCodec.decode(old)), old)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: old) as? [String: Any])?["schemaVersion"] as? Int, 3)
        XCTAssertTrue(try DeviceUnifiedInventorySession.peekLocalSourceMetadata(commonRoot: f.root, commonRootID: f.rootID).legacyLocalRoots.isEmpty)
        let detached = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [entry], configuredEntryID: entry.entryID,
            detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data("synthetic-nonsecret-capture".utf8)))
        let restored = try DeviceMixedStructuralStateCodec.decode(DeviceMixedStructuralStateCodec.encode(detached))
        XCTAssertEqual(restored.entries, [entry]); XCTAssertEqual(restored.configuredEntryID, entry.entryID)
        XCTAssertEqual(restored.installationOwner, f.owner)
        XCTAssertNotEqual(try DeviceMixedStructuralStateCodec.encode(restored), old)
    }
    func testLogoutIntentDetachAndNewOwnerAttachReplayExactCASAtEachCrashBoundary() throws {
        for boundary in 0..<3 {
            let entry = localEntry(), f = try Ledger(entries: [entry])
            let rootBinding = try Data(contentsOf: f.root.appendingPathComponent("mixed-root.json"))
            let legacyRoots = ["packages", "grants", "structural", "provisioning"].map {
                DeviceMixedInventoryStore.LocalSourceRoot(rootID: UUID(), path: f.root.appendingPathComponent($0).path)
            }
            try DeviceMixedInventoryQualificationHarness.scope(f.store) { try f.store.initializeCloudObservationCheckpointExact(UUID(), permit: $0) }
            let oldOutbox = try Data(contentsOf: f.root.appendingPathComponent("mixed-cloud-observations.json"))
            let detachOperation = UUID(), detachGeneration = UUID(), retirement = Data("synthetic-nonsecret-capture".utf8)
            let pending = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
                entries: [entry], configuredEntryID: entry.entryID,
                logoutIntent: .init(detachOperationID: detachOperation, detachGenerationID: detachGeneration, retirementMetadata: retirement), legacyLocalRoots: legacyRoots)
            let startOperation = UUID()
            try f.append(pending, operationID: startOperation, currentInstalled: boundary > 0, receiptInstalled: boundary > 1)
            if boundary < 2 { XCTAssertThrowsError(try f.store.readCurrent()) }
            try f.reopen(); XCTAssertEqual(f.current.snapshot, pending)
            let pendingBytes = f.current.bytes
            let detached = try DeviceMixedStructuralState.validating(generationID: detachGeneration, installationOwner: f.owner,
                entries: [entry], configuredEntryID: entry.entryID,
                detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: retirement), legacyLocalRoots: legacyRoots)
            try f.append(detached, operationID: detachOperation, currentInstalled: boundary > 0, receiptInstalled: boundary > 1)
            try f.reopen(); XCTAssertEqual(f.current.snapshot, detached)
            XCTAssertFalse(try DeviceUnifiedInventorySession.peekDetachedMetadata(commonRoot: f.root, commonRootID: f.rootID)!.cleanupCompleted)
            let uncleanStore = DeviceMixedInventoryStore(root: f.root, rootID: f.rootID)
            let uncleanCapture = try XCTUnwrap(uncleanStore.readCurrent())
            let deniedOwner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
            let deniedAttach = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: deniedOwner,
                entries: [entry], configuredEntryID: entry.entryID, legacyLocalRoots: legacyRoots, cloudObservationEpoch: deniedOwner.installationID)
            XCTAssertThrowsError(try DeviceMixedInventoryQualificationHarness.scope(uncleanStore) {
                try uncleanStore.commitCloudAttachmentExact(operationID: UUID(), previous: uncleanCapture, candidate: deniedAttach, permit: $0)
            })
            // A partially completed credential/directory cleanup cannot enable a
            // new attachment. Only its independently confirmed CAS completion can.
            let cleaned = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
                entries: [entry], configuredEntryID: entry.entryID,
                detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: retirement, cleanupCompleted: true), legacyLocalRoots: legacyRoots)
            try f.append(cleaned, operationID: UUID(), currentInstalled: boundary > 0, receiptInstalled: boundary > 1)
            try f.reopen(); XCTAssertTrue(f.current.snapshot.detachment!.cleanupCompleted)
            let freshOwner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
            let attached = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: freshOwner,
                entries: [entry], configuredEntryID: entry.entryID, legacyLocalRoots: legacyRoots, cloudObservationEpoch: freshOwner.installationID)
            try f.append(attached, operationID: UUID(), currentInstalled: boundary > 0, receiptInstalled: boundary > 1)
            try f.reopen(); XCTAssertEqual(f.current.snapshot, attached)
            XCTAssertEqual(f.current.snapshot.entries, [entry]); XCTAssertEqual(f.current.snapshot.configuredEntryID, entry.entryID)
            let sourceMetadata = try DeviceUnifiedInventorySession.peekLocalSourceMetadata(commonRoot: f.root, commonRootID: f.rootID)
            XCTAssertEqual(sourceMetadata.legacyLocalRoots.map(\.rootID), legacyRoots.map(\.rootID))
            XCTAssertEqual(sourceMetadata.legacyLocalRoots.map(\.path), legacyRoots.map(\.path))
            let activeStore = DeviceMixedInventoryStore(root: f.root, rootID: f.rootID)
            let authenticatedNewBaseline = UUID()
            try DeviceMixedInventoryQualificationHarness.scope(activeStore) { try activeStore.initializeCloudObservationCheckpointExact(authenticatedNewBaseline, permit: $0) }
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("mixed-cloud-observations.json")), oldOutbox)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("mixed-cloud-observations." + freshOwner.installationID.uuidString.lowercased() + ".json").path))
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("mixed-root.json")), rootBinding)
            let start = try JSONDecoder().decode(DeviceMixedInventoryStore.Intent.self,
                from: Data(contentsOf: f.root.appendingPathComponent(startOperation.uuidString.lowercased() + ".mixed-intent.json")))
            XCTAssertEqual(start.candidate, pendingBytes)
        }
    }
    func testOrdinaryWriterCannotForgeLogoutOrRebindOwner() throws {
        let f = try Ledger(), retired = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data([1])))
        XCTAssertThrowsError(try DeviceMixedInventoryQualificationHarness.scope(f.store) {
            try f.store.commitExact(operationID: UUID(), previous: f.current, candidate: retired, admissionEnabled: true, permit: $0)
        })
        let foreign = try DeviceMixedStructuralState.validating(generationID: UUID(),
            installationOwner: .init(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID()), entries: [], configuredEntryID: nil)
        XCTAssertThrowsError(try DeviceMixedInventoryQualificationHarness.scope(f.store) {
            try f.store.commitExact(operationID: UUID(), previous: f.current, candidate: foreign, admissionEnabled: true, permit: $0)
        })
        let pendingDetach = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data([1])))
        XCTAssertThrowsError(try DeviceMixedInventoryQualificationHarness.scope(f.store) {
            try f.store.commitCloudAttachmentExact(operationID: UUID(), previous: f.current, candidate: foreign, permit: $0)
        })
        XCTAssertFalse(pendingDetach.detachment!.cleanupCompleted)
        let unauthorizedEpoch = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, cloudObservationEpoch: f.owner.installationID)
        XCTAssertThrowsError(try DeviceMixedInventoryQualificationHarness.scope(f.store) {
            try f.store.commitExact(operationID: UUID(), previous: f.current, candidate: unauthorizedEpoch, admissionEnabled: true, permit: $0)
        })
    }
    func testChangedReceiptAndChangedRetirementMetadataCannotBeRecommitted() throws {
        let f = try Ledger(), op = UUID(), generation = UUID()
        let pending = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, logoutIntent: .init(detachOperationID: op, detachGenerationID: generation, retirementMetadata: Data([1])))
        try f.append(pending, operationID: UUID(), currentInstalled: true, receiptInstalled: true); try f.reopen()
        let bad = try DeviceMixedStructuralState.validating(generationID: generation, installationOwner: f.owner,
            entries: [], configuredEntryID: nil, detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data([2])))
        try f.append(bad, operationID: op, currentInstalled: false, receiptInstalled: false)
        XCTAssertThrowsError(try f.store.recommitPendingCloudAttachmentExact())
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("mixed-current.json")), f.current.bytes)
        let g = try Ledger(), start = UUID()
        let accepted = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: g.owner,
            entries: [], configuredEntryID: nil, logoutIntent: .init(detachOperationID: UUID(), detachGenerationID: UUID(), retirementMetadata: Data([3])))
        try g.append(accepted, operationID: start, currentInstalled: true, receiptInstalled: true)
        try Data("{}".utf8).write(to: g.root.appendingPathComponent(start.uuidString.lowercased() + ".mixed-receipt.json"))
        XCTAssertThrowsError(try g.store.recommitPendingCloudAttachmentExact())
    }
    func testOldOwnerPendingReportsRemainInertAfterExplicitReattachment() throws {
        let f = try Ledger(), firstBytes = f.current.bytes, detachOperation = UUID(), detachGeneration = UUID()
        let oldOperation = f.initialOperation.uuidString.lowercased()
        let accepted: [String: Any] = ["command": Data([0]).base64EncodedString(), "plan": Data([0]).base64EncodedString(),
            "previous": firstBytes.base64EncodedString(), "nativeOperationID": UUID().uuidString, "journalRootID": UUID().uuidString]
        let acceptedBytes = try JSONSerialization.data(withJSONObject: accepted, options: [.sortedKeys, .withoutEscapingSlashes])
        try acceptedBytes.write(to: f.root.appendingPathComponent(oldOperation + ".mixed-cloud-accepted.json"))
        try Data([0]).write(to: f.root.appendingPathComponent(oldOperation + ".mixed-static-grant.json"))
        try Data([0]).write(to: f.root.appendingPathComponent(oldOperation + ".mixed-rejection-outcome.json"))
        let pending = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, logoutIntent: .init(detachOperationID: detachOperation, detachGenerationID: detachGeneration, retirementMetadata: Data([1])))
        try f.append(pending, operationID: UUID(), currentInstalled: true, receiptInstalled: true); try f.reopen()
        XCTAssertTrue(try f.store.pendingCloudRejectionsExact().isEmpty)
        XCTAssertTrue(try f.store.pendingIncomingOutcomesExact().isEmpty)
        let detached = try DeviceMixedStructuralState.validating(generationID: detachGeneration, installationOwner: f.owner,
            entries: [], configuredEntryID: nil, detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data([1])))
        try f.append(detached, operationID: detachOperation, currentInstalled: true, receiptInstalled: true); try f.reopen()
        let cleaned = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data([1]), cleanupCompleted: true))
        try f.append(cleaned, operationID: UUID(), currentInstalled: true, receiptInstalled: true); try f.reopen()
        let nextOwner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let attached = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: nextOwner,
            entries: [], configuredEntryID: nil, cloudObservationEpoch: nextOwner.installationID)
        try f.append(attached, operationID: UUID(), currentInstalled: true, receiptInstalled: true); try f.reopen()
        XCTAssertTrue(try f.store.pendingCloudRejectionsExact().isEmpty)
        XCTAssertTrue(try f.store.pendingIncomingOutcomesExact().isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(oldOperation + ".mixed-cloud-accepted.json")), acceptedBytes)
    }
    func testDetachedEmptyLocalSessionRestoresWithoutNativeAndCannotMintCredentialCleanupFromOpaqueMetadata() throws {
        let f = try Ledger(), op = UUID(), generation = UUID()
        let accepted = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: f.owner,
            entries: [], configuredEntryID: nil, logoutIntent: .init(detachOperationID: op, detachGenerationID: generation, retirementMetadata: Data([1])))
        try f.append(accepted, operationID: UUID(), currentInstalled: true, receiptInstalled: true); try f.reopen()
        let detached = try DeviceMixedStructuralState.validating(generationID: generation, installationOwner: f.owner,
            entries: [], configuredEntryID: nil, detachment: .init(revokedAt: "2026-10-15T12:00:00Z", retirementMetadata: Data([1])))
        try f.append(detached, operationID: op, currentInstalled: true, receiptInstalled: true); try f.reopen()
        let session = try DeviceUnifiedInventorySession.restoreDetached(commonRoot: f.root, commonRootID: f.rootID,
            validateOriginal: {}, validateMutation: {})
        let association = try session.detachedAssociation(); try association.validateCurrent()
        XCTAssertEqual(association.metadata.retiredInstallationID, f.owner.installationID)
        XCTAssertTrue(try session.validatedAssociation().entries.isEmpty)
        let before = try Data(contentsOf: f.root.appendingPathComponent("mixed-current.json"))
        let display = try session.validatedDisplayMetadata()
        XCTAssertEqual(display.association.commonRootID, f.rootID)
        XCTAssertEqual(display.association.generationID, generation)
        XCTAssertTrue(display.association.entries.isEmpty)
        XCTAssertNil(display.association.configuredEntryID)
        XCTAssertTrue(display.manifests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("mixed-current.json")), before)
        XCTAssertThrowsError(try association.credentialRetirement())
    }
}

#endif
