import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceNativeStructuralStateTests: XCTestCase {
    private let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var owner: DeviceNativeInstallationContentOwner {
        .init(installationID: generation, accountID: UUID(), locationID: UUID(), transitionID: UUID())
    }
    private func entry(name: String = "Screen") throws -> DeviceNativeStructuralEntry {
        let digest = try DeviceDeliveryCandidateHash.validating(String(repeating: "a", count: 64))
        let manifest = try DeviceDeliveryCandidateHash.validating(String(repeating: "b", count: 64))
        let archive = try DeviceDeliveryCandidateHash.validating(String(repeating: "c", count: 64))
        let package = try DeviceDeliveryPackageCandidate.validating(packageProfile: DeviceDeliveryPackageCandidate.profile,
            publicationID: UUID(), projectID: UUID(), packageID: UUID(), dashboardID: UUID(), revision: UUID(),
            manifestDigest: digest, manifestSHA256: manifest, archiveSHA256: archive,
            compressedBytes: 1, expandedBytes: 2, archiveEntries: 1)
        let content = String(repeating: "d", count: 64)
        return try .validating(entryID: UUID(), displayName: name, package: package,
            preparedPackage: .init(rootID: UUID(), contentID: content, preparationOperationID: UUID(), directory: "package.staging-cas-v1-" + content))
    }
    private func state(_ entries: [DeviceNativeStructuralEntry] = []) throws -> DeviceNativeStructuralState {
        try .validating(generationID: generation, owner: .nativeInstallation(owner), entries: entries, configuredEntryID: entries.last?.entryID)
    }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func mutate(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&body); return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
    func testEmptyExplicitOwnerAndCanonicalRoundTrip() throws {
        let value = try state(), encoded = try DeviceNativeStructuralStateCodec.encode(value)
        XCTAssertEqual(try DeviceNativeStructuralStateCodec.decode(encoded), value)
        XCTAssertEqual(try DeviceNativeStructuralStateCodec.encode(DeviceNativeStructuralStateCodec.decode(encoded)), encoded)
        XCTAssertNil(value.configuredEntryID)
        // UUID role equality is not silently prohibited or reinterpreted.
        XCTAssertEqual(value.owner.installationID, value.generationID)
    }
    func testOrderSelectionAndIndependentIdentitiesPreserved() throws {
        let first = try entry(), second = try entry(name: "Renamed household screen")
        let value = try state([first, second])
        let decoded = try DeviceNativeStructuralStateCodec.decode(DeviceNativeStructuralStateCodec.encode(value))
        XCTAssertEqual(decoded.entries, [first, second]); XCTAssertEqual(decoded.configuredEntryID, second.entryID)
        XCTAssertEqual(decoded.entries[0].package.manifestDigest.text, String(repeating: "a", count: 64))
        XCTAssertEqual(decoded.entries[0].package.manifestSHA256.text, String(repeating: "b", count: 64))
        XCTAssertEqual(decoded.entries[0].package.archiveSHA256.text, String(repeating: "c", count: 64))
        XCTAssertEqual(decoded.entries[0].preparedPackage.contentID, String(repeating: "d", count: 64))
    }
    func testSelectionDuplicateAndTypedCapacityFailClosed() throws {
        let e = try entry()
        XCTAssertThrowsError(try DeviceNativeStructuralState.validating(generationID: generation, owner: .nativeInstallation(owner), entries: [e], configuredEntryID: nil))
        XCTAssertThrowsError(try DeviceNativeStructuralState.validating(generationID: generation, owner: .nativeInstallation(owner), entries: [], configuredEntryID: e.entryID))
        XCTAssertThrowsError(try state([e,e]))
        XCTAssertThrowsError(try state((0..<13).map { _ in try entry() }))
        XCTAssertThrowsError(try entry(name: String(repeating: "é", count: 513)))
    }
    func testOldLocalAndRetainedImportAreNotPromoted() throws {
        let data = try DeviceNativeStructuralStateCodec.encode(state([entry()]))
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(mutate(data) { $0["schemaVersion"] = 1 }))
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(mutate(data) {
            $0["owner"] = ["kind": "localController", "role": "controller", "publicKey": String(repeating: "a", count: 32)]
        }))
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(mutate(data) {
            var entries = $0["entries"] as! [[String: Any]]; entries[0]["provenance"] = "retainedLocal"; $0["entries"] = entries
        }))
    }
    func testUnknownNestedFieldsAndCredentialGenerationReject() throws {
        let data = try DeviceNativeStructuralStateCodec.encode(state([entry()]))
        for key in ["credentialGenerationID", "lease", "operationID"] {
            XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(mutate(data) { $0[key] = generation.uuidString }))
        }
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(mutate(data) {
            var owner = $0["owner"] as! [String: Any]; owner["nativePublicKey"] = String(repeating: "a", count: 48); $0["owner"] = owner
        }))
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(mutate(data) {
            var entries = $0["entries"] as! [[String: Any]], package = entries[0]["package"] as! [String: Any]
            package["unknown"] = true; entries[0]["package"] = package; $0["entries"] = entries
        }))
    }
    func testEscapedDuplicatesInvalidUnicodeAndTrailingSyntax() throws {
        for raw in ["{\"owner\":1,\"\\u006fwner\":2}", "{\"x\":{\"é\":1,\"\\u00e9\":2}}", "{\"x\":\"\\ud800\"}", "{\"x\":\"\\udc00\"}", "{}{}", "{\"x\":01}", "{\"x\":1e}"] {
            XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(bytes(raw)), raw)
        }
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(Data([123,34,120,34,58,34,255,34,125])))
    }
    func testSurrogatePairExactUTF8NamesAndExponentCanonicalization() throws {
        let e = try entry(name: "é😀"), data = try DeviceNativeStructuralStateCodec.encode(state([e]))
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "😀", with: "\\ud83d\\ude00")
            .replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":2e0")
        let decoded = try DeviceNativeStructuralStateCodec.decode(bytes(text))
        XCTAssertTrue(decoded.entries[0].displayName.utf8.elementsEqual(e.displayName.utf8))
        let decomposed = try entry(name: "e\u{301}")
        XCTAssertFalse(decomposed.displayName.utf8.elementsEqual(e.displayName.utf8))
    }
    func testSameIdentityUnicodeNamesHaveExactByteEquality() throws {
        let composed = try entry(name: "é")
        let decomposed = try DeviceNativeStructuralEntry.validating(entryID: composed.entryID,
            displayName: "e\u{301}", package: composed.package, preparedPackage: composed.preparedPackage)
        XCTAssertNotEqual(composed, decomposed)
        let installation = owner
        let a = try DeviceNativeStructuralState.validating(generationID: generation,
            owner: .nativeInstallation(installation), entries: [composed], configuredEntryID: composed.entryID)
        let b = try DeviceNativeStructuralState.validating(generationID: generation,
            owner: .nativeInstallation(installation), entries: [decomposed], configuredEntryID: composed.entryID)
        let encodedA = try DeviceNativeStructuralStateCodec.encode(a)
        let encodedB = try DeviceNativeStructuralStateCodec.encode(b)
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(encodedA, encodedB)
        let decodedA = try DeviceNativeStructuralStateCodec.decode(encodedA)
        let decodedB = try DeviceNativeStructuralStateCodec.decode(encodedB)
        XCTAssertNotEqual(decodedA, decodedB)
        XCTAssertTrue(decodedA.entries[0].displayName.utf8.elementsEqual(composed.displayName.utf8))
        XCTAssertTrue(decodedB.entries[0].displayName.utf8.elementsEqual(decomposed.displayName.utf8))
        XCTAssertEqual(try DeviceNativeStructuralStateCodec.encode(decodedA), encodedA)
        XCTAssertEqual(try DeviceNativeStructuralStateCodec.encode(decodedB), encodedB)
    }
    func testRawSizeDepthNodesAndPreparedReferenceConstraints() throws {
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(Data(repeating: 32, count: 65_537)))
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(bytes(String(repeating: "{\"x\":", count: 33) + "0" + String(repeating: "}", count: 33))))
        let many = (0..<2100).map { "\"k\($0)\":0" }.joined(separator: ",")
        XCTAssertThrowsError(try DeviceNativeStructuralStateCodec.decode(bytes("{" + many + "}")))
        let e = try entry()
        XCTAssertThrowsError(try DeviceNativeStructuralEntry.validating(entryID: e.entryID, displayName: e.displayName, package: e.package,
            preparedPackage: .init(rootID: UUID(), contentID: e.preparedPackage.contentID, preparationOperationID: UUID(), directory: "../other")))
    }
    func testMixedSchemaPreservesLocalResourcesOwnershipOrderAndSelection() throws {
        let cloud = try entry(), localID = UUID(), grantRoot = UUID()
        let content = String(repeating: "d", count: 64)
        let reference = DevicePreparedPackageReference(rootID: UUID(), contentID: content, preparationOperationID: UUID(), directory: "package.staging-cas-v1-" + content)
        let revision = StoredRevision(revision: "local-revision", dashboardId: "local-dashboard", name: "Local", digest: String(repeating: "a", count: 64), orientation: .portrait, width: 390, height: 844)
        let localOwner = PairingIdentity(role: .controller, publicKey: Array(repeating: 9, count: 32))
        let local = DeviceMixedStructuralState.Local(entry: .init(entryID: localID, displayName: "Local", revision: revision, packageDirectory: reference.directory), package: reference,
            grant: .init(identity: .init(rootID: grantRoot, revisionID: UUID()), preparationOperationID: UUID()), owner: localOwner)
        let cloudGrant = DeviceMixedStructuralState.Grant(identity: .init(rootID: UUID(), revisionID: UUID()), preparationOperationID: UUID())
        let mixed = try DeviceMixedStructuralState.validating(generationID: generation, installationOwner: owner,
            entries: [.retainedLocal(local), .cloud(cloud, cloudGrant)], configuredEntryID: localID)
        let bytes = try DeviceMixedStructuralStateCodec.encode(mixed)
        let restored = try DeviceMixedStructuralStateCodec.decode(bytes)
        XCTAssertEqual(restored, mixed)
        XCTAssertEqual(restored.entries.map(\.entryID), [localID, cloud.entryID])
        XCTAssertEqual(restored.configuredEntryID, localID)
        guard case .retainedLocal(let retained) = restored.entries[0] else { return XCTFail() }
        XCTAssertEqual(retained.owner, localOwner); XCTAssertEqual(retained.package, reference)
        XCTAssertEqual(retained.grant, local.grant)
        XCTAssertThrowsError(try DeviceMixedStructuralState.validating(generationID: generation, installationOwner: owner,
            entries: [.retainedLocal(local), .retainedLocal(local)], configuredEntryID: localID))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID(), inventory = DeviceMixedInventoryStore(root: root, rootID: rootID)
        try inventory.initializeExplicit()
        let committed = try DeviceMixedInventoryQualificationHarness.scope(inventory) {
            try inventory.commitExact(operationID: UUID(), previous: nil, candidate: mixed, admissionEnabled: true, permit: $0)
        }
        let reopened = DeviceMixedInventoryStore(root: root, rootID: rootID)
        XCTAssertEqual(try reopened.readCurrent()?.snapshot, mixed)
        XCTAssertThrowsError(try DeviceMixedInventoryQualificationHarness.scope(inventory) {
            try inventory.commitExact(operationID: UUID(), previous: committed.0,
                candidate: .validating(generationID: UUID(), installationOwner: mixed.installationOwner,
                    entries: mixed.entries, configuredEntryID: cloud.entryID), admissionEnabled: false, permit: $0)
        })
        XCTAssertEqual(try reopened.readCurrent()?.snapshot.entries, mixed.entries)
        XCTAssertEqual(try reopened.readCurrent()?.snapshot.configuredEntryID, localID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = object["entries"] as! [[String: Any]]
        var altered = entries[0]["local"] as! [String: Any]
        altered.removeValue(forKey: "owner"); entries[0]["local"] = altered; object["entries"] = entries
        XCTAssertThrowsError(try DeviceMixedStructuralStateCodec.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
    }

}
