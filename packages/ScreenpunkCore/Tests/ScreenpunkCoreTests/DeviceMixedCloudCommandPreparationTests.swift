import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceMixedCloudCommandPreparationTests: XCTestCase {
    func testRetainedLocalPreparationPreservesGrantAndRejectsStaleOrChangedIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceMixedInventoryStore(root: root, rootID: UUID()); try store.initializeExplicit()
        let owner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let id = UUID(), content = String(repeating: "a", count: 64), packageRoot = UUID(), grantRoot = UUID()
        let package = DevicePreparedPackageReference(rootID: packageRoot, contentID: content,
            preparationOperationID: UUID(), directory: "package.staging-cas-v1-" + content)
        let revision = StoredRevision(revision: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "Local", digest: String(repeating: "b", count: 64), orientation: .landscape, width: 100, height: 100)
        let grant = DeviceMixedStructuralState.Grant(identity: .init(rootID: UUID(), revisionID: UUID()), preparationOperationID: UUID())
        let local = DeviceMixedStructuralState.Local(entry: .init(entryID: id, displayName: "Local", revision: revision,
            packageDirectory: package.directory), package: package, grant: grant,
            owner: .init(role: .controller, publicKey: Array(repeating: 1, count: PairingLimits.identityByteCount)))
        let state = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner,
            entries: [.retainedLocal(local)], configuredEntryID: id)
        let capture = try DeviceMixedInventoryQualificationHarness.scope(store) {
            try store.commitExact(operationID: UUID(), previous: nil, candidate: state, admissionEnabled: true, permit: $0).0
        }
        let plan = Data("reviewed immutable command".utf8)
        let set = try DeviceResultingSetCandidate.validating(entries: [.validating(entryID: id,
            provenance: .retainedLocal(retainedEntryID: id, manifestDigest: .validating(revision.digest)))], configuredEntryID: id)
        let a: [String: Any] = ["schemaVersion": 1, "operationId": UUID().uuidString.lowercased(), "planId": UUID().uuidString.lowercased(),
            "installationId": owner.installationID.uuidString.lowercased(), "accountId": owner.accountID.uuidString.lowercased(),
            "locationId": NSNull(), "transitionId": owner.transitionID.uuidString.lowercased(),
            "planDigest": try DeviceNativeDeliveryAttachmentCodec.hash(plan), "planByteLength": plan.count]
        let header = try JSONSerialization.data(withJSONObject: a).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var command = a
        command["sequence"] = "1"; command["executionExpiresAt"] = "2026-10-10T15:00:00Z"
        command["expectedInstalledSetGenerationId"] = state.generationID.uuidString.lowercased()
        command["desiredSetGenerationId"] = UUID().uuidString.lowercased()
        command["resultingSet"] = ["schemaVersion": 1, "entries": [["entryId": id.uuidString.lowercased(), "provenance": ["kind": "retainedLocal",
            "retainedEntryId": id.uuidString.lowercased(), "manifestDigest": revision.digest]]], "configuredEntryId": id.uuidString.lowercased()]
        command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(set)
        func prepare(_ command: [String: Any]) throws -> DeviceMixedPreparedCloudCommand {
            try .prepare(capture: capture, command: JSONSerialization.data(withJSONObject: command), associationHeader: header,
                rawPlan: plan, nativeOperationID: UUID(), journalRootID: UUID(), packageRootID: packageRoot,
                grantRootID: grantRoot, grantOperationID: UUID(), grantRevisionID: UUID(), archives: [])
        }
        let prepared = try prepare(command)
        XCTAssertEqual(prepared.candidate.entries, state.entries)
        XCTAssertTrue(prepared.capture === capture)
        XCTAssertTrue(prepared.packageInputs.isEmpty)
        XCTAssertTrue(prepared.grantInput.entries.isEmpty)
        XCTAssertNotEqual(prepared.candidate.generationID, state.generationID)
        // The original exclusive binder is deliberately unchanged.
        XCTAssertThrowsError(try DeviceNativeDeliveryCommandBinding.bind(command: JSONSerialization.data(withJSONObject: command),
            associationHeader: header, rawPlan: plan, nativeOperationID: UUID(), journalRootID: UUID()))
        command["expectedInstalledSetGenerationId"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try prepare(command))
        command["expectedInstalledSetGenerationId"] = state.generationID.uuidString.lowercased()
        command["accountId"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try prepare(command))
        command["accountId"] = owner.accountID.uuidString.lowercased()
        let wrongDigest = String(repeating: "c", count: 64)
        let forgedSet = try DeviceResultingSetCandidate.validating(entries: [.validating(entryID: id,
            provenance: .retainedLocal(retainedEntryID: id, manifestDigest: .validating(wrongDigest)))], configuredEntryID: id)
        command["resultingSet"] = ["schemaVersion": 1, "entries": [["entryId": id.uuidString.lowercased(), "provenance": ["kind": "retainedLocal",
            "retainedEntryId": id.uuidString.lowercased(), "manifestDigest": wrongDigest]]], "configuredEntryId": id.uuidString.lowercased()]
        command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(forgedSet)
        // Even an internally self-consistent wire digest cannot replace a retained Local resource.
        XCTAssertThrowsError(try prepare(command))
        let descriptor = try DeviceDeliveryPackageCandidate.validating(packageProfile: DeviceDeliveryPackageCandidate.profile,
            publicationID: UUID(), projectID: UUID(), packageID: UUID(), dashboardID: UUID(), revision: UUID(),
            manifestDigest: .validating(String(repeating: "a", count: 64)), manifestSHA256: .validating(String(repeating: "b", count: 64)),
            archiveSHA256: .validating(String(repeating: "c", count: 64)), compressedBytes: 1, expandedBytes: 1, archiveEntries: 1)
        let cloudID = UUID(), cloudEntry = try DeviceNativeStructuralEntry.validating(entryID: cloudID,
            displayName: "Cloud", package: descriptor, preparedPackage: package)
        let cloudState = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner,
            entries: [.retainedLocal(local), .cloud(cloudEntry, grant)], configuredEntryID: cloudID)
        let cloudCapture = try DeviceMixedInventoryQualificationHarness.scope(store) {
            try store.commitExact(operationID: UUID(), previous: capture, candidate: cloudState, admissionEnabled: true, permit: $0).0
        }
        let both = try DeviceResultingSetCandidate.validating(entries: [.validating(entryID: id,
            provenance: .retainedLocal(retainedEntryID: id, manifestDigest: .validating(revision.digest))),
            .validating(entryID: cloudID, provenance: .cloud(descriptor))], configuredEntryID: cloudID)
        let packageWire: [String: Any] = ["packageProfile": DeviceDeliveryPackageCandidate.profile, "publicationId": descriptor.publicationID.uuidString.lowercased(),
            "projectId": descriptor.projectID.uuidString.lowercased(), "packageId": descriptor.packageID.uuidString.lowercased(),
            "dashboardId": descriptor.dashboardID.uuidString.lowercased(), "revision": descriptor.revision.uuidString.lowercased(),
            "manifestDigest": descriptor.manifestDigest.text, "manifestSha256": descriptor.manifestSHA256.text,
            "archiveSha256": descriptor.archiveSHA256.text, "compressedBytes": 1, "expandedBytes": 1, "archiveEntries": 1]
        command["expectedInstalledSetGenerationId"] = cloudState.generationID.uuidString.lowercased()
        command["resultingSet"] = ["schemaVersion": 1, "entries": [["entryId": id.uuidString.lowercased(), "provenance": ["kind": "retainedLocal",
            "retainedEntryId": id.uuidString.lowercased(), "manifestDigest": revision.digest]],
            ["entryId": cloudID.uuidString.lowercased(), "provenance": ["kind": "cloud", "package": packageWire]]],
            "configuredEntryId": cloudID.uuidString.lowercased()]
        command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(both)
        let retainedCloud = try DeviceMixedPreparedCloudCommand.prepare(capture: cloudCapture,
            command: JSONSerialization.data(withJSONObject: command), associationHeader: header, rawPlan: plan,
            nativeOperationID: UUID(), journalRootID: UUID(), packageRootID: packageRoot, grantRootID: grantRoot,
            grantOperationID: UUID(), grantRevisionID: UUID(), archives: [])
        XCTAssertEqual(retainedCloud.candidate.entries, cloudState.entries)
        XCTAssertTrue(retainedCloud.packageInputs.isEmpty)
        XCTAssertTrue(retainedCloud.grantInput.entries.isEmpty)
        XCTAssertEqual(retainedCloud.candidate.configuredEntryID, cloudID)

        // Omission is destructive only with the exact explicit reviewed removal set.
        let onlyLocal = try DeviceResultingSetCandidate.validating(entries: [.validating(entryID: id,
            provenance: .retainedLocal(retainedEntryID: id, manifestDigest: .validating(revision.digest)))], configuredEntryID: id)
        command["resultingSet"] = ["schemaVersion": 1, "entries": [["entryId": id.uuidString.lowercased(),
            "provenance": ["kind": "retainedLocal", "retainedEntryId": id.uuidString.lowercased(), "manifestDigest": revision.digest]]],
            "configuredEntryId": id.uuidString.lowercased()]
        command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(onlyLocal)
        func bindRemoval(_ wire: [String: Any]) throws -> DeviceNativeDeliveryCommandBinding {
            try .bindMixed(command: JSONSerialization.data(withJSONObject: wire), associationHeader: header,
                rawPlan: plan, nativeOperationID: UUID(), journalRootID: UUID(), capture: cloudCapture)
        }
        XCTAssertThrowsError(try bindRemoval(command), "No implicit removal of a retained Cloud screen")
        command["removeEntryIds"] = [cloudID.uuidString.lowercased()]
        XCTAssertNoThrow(try bindRemoval(command))
        command["removeEntryIds"] = [cloudID.uuidString.lowercased(), cloudID.uuidString.lowercased()]
        XCTAssertThrowsError(try bindRemoval(command), "Duplicate removals are invalid")
        command["removeEntryIds"] = [cloudID.uuidString.lowercased(), UUID().uuidString.lowercased()]
        XCTAssertThrowsError(try bindRemoval(command), "Only baseline entries may be removed")
        command["removeEntryIds"] = [cloudID.uuidString.lowercased(), id.uuidString.lowercased()]
        XCTAssertThrowsError(try bindRemoval(command), "A retained entry cannot also be removed")

    }
}
