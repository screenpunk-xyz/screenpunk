import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

// Exact GitHub System Plugin committed-file reads verified both blob identities:
// screenpunk-xyz/cloud ca59ec8bee9acbac2abdab252c35542f51d9560c
// docs/api/native-delivery-codec-fixtures.json blob1662d4f2c19cd5821ef8bc7af1200069be789c4c
// SHA256 c2b38959b9f8cafeefcf8ad9ee9bb1b3aed6a740379fb399646c7def3c461c50
// screenpunk-xyz/cloud dfb9c83fae5ed5fb175ba41059900b679b098725
// docs/api/resulting-set-codec-fixtures.json blob599ac8d7afa30b591c7b0348f602ab6a8ae02a24
// SHA256 c1eada5b6e3a4115686dab3582c86fe1bbeb1fcebc7a6149f12bac6f3dbb7e09
// Fixtures remain synthetic/unfrozen and confer no authority. Test-only JSON
// projection below is NOT a production raw decoder or durable restart loader.
final class DeviceDeliveryCandidateCodecTests: XCTestCase {
    private struct Document: Decodable { let profile: String, identity: String; let cases: [Fixture] }
    private struct Fixture: Decodable { let name: String, value: Value, hex: String; let observationDigest: String?, resultingSetDigest: String? }
    private struct Value: Decodable {
        let schemaVersion: Int
        let installationId: String?, transitionId: String?, generationId: String?
        let entries: [Entry], configuredEntryId: String?
    }
    private struct Entry: Decodable { let entryId: String; let provenance: Provenance }
    private struct Provenance: Decodable { let kind: String; let package: Package?; let retainedEntryId: String?, manifestDigest: String? }
    private struct Package: Decodable {
        let packageProfile: String, publicationId: String, projectId: String, packageId: String, dashboardId: String, revision: String
        let manifestDigest: String, manifestSha256: String, archiveSha256: String
        let compressedBytes: UInt64, expandedBytes: UInt64, archiveEntries: UInt64
    }
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", n))! }
    private func hash(_ letter: String = "a") throws -> DeviceDeliveryCandidateHash { try .validating(String(repeating: letter, count: 64)) }
    private func document(_ name: String, sha256: String) throws -> Document {
        let path = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let bytes = try Data(contentsOf: path)
        #if canImport(CryptoKit)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), sha256)
        #endif
        return try JSONDecoder().decode(Document.self, from: bytes)
    }
    private func entries(_ value: Value) throws -> [DeviceDeliveryEntryCandidate] {
        XCTAssertEqual(value.schemaVersion, 1)
        return try value.entries.map { entry in
            let provenance: DeviceDeliveryEntryProvenanceCandidate
            if entry.provenance.kind == "cloud" {
                let p = try XCTUnwrap(entry.provenance.package)
                provenance = .cloud(try .validating(packageProfile: p.packageProfile,
                    publicationID: XCTUnwrap(UUID(uuidString: p.publicationId)), projectID: XCTUnwrap(UUID(uuidString: p.projectId)),
                    packageID: XCTUnwrap(UUID(uuidString: p.packageId)), dashboardID: XCTUnwrap(UUID(uuidString: p.dashboardId)),
                    revision: XCTUnwrap(UUID(uuidString: p.revision)), manifestDigest: .validating(p.manifestDigest),
                    manifestSHA256: .validating(p.manifestSha256), archiveSHA256: .validating(p.archiveSha256),
                    compressedBytes: p.compressedBytes, expandedBytes: p.expandedBytes, archiveEntries: p.archiveEntries))
            } else {
                XCTAssertEqual(entry.provenance.kind, "retainedLocal")
                provenance = .retainedLocal(retainedEntryID: try XCTUnwrap(UUID(uuidString: XCTUnwrap(entry.provenance.retainedEntryId))),
                    manifestDigest: try .validating(XCTUnwrap(entry.provenance.manifestDigest)))
            }
            return .validating(entryID: try XCTUnwrap(UUID(uuidString: entry.entryId)), provenance: provenance)
        }
    }
    private func selected(_ value: Value) throws -> UUID? {
        try value.configuredEntryId.map { try XCTUnwrap(UUID(uuidString: $0)) }
    }
    private func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private func package(dashboard: Int = 10, profile: String = DeviceDeliveryPackageCandidate.profile,
        compressed: UInt64 = 1, expanded: UInt64 = 1, archiveEntries: UInt64 = 1) throws -> DeviceDeliveryPackageCandidate {
        try .validating(packageProfile: profile, publicationID: id(1), projectID: id(2), packageID: id(3),
            dashboardID: id(dashboard), revision: id(4), manifestDigest: hash(), manifestSHA256: hash("b"), archiveSHA256: hash("c"),
            compressedBytes: compressed, expandedBytes: expanded, archiveEntries: archiveEntries)
    }
    private func retained(_ n: Int) throws -> DeviceDeliveryEntryCandidate {
        .validating(entryID: id(n), provenance: .retainedLocal(retainedEntryID: id(n + 100), manifestDigest: try hash("d")))
    }
    func testCommittedObservationGoldenBytesAndDigest() throws {
        let doc = try document("native-delivery-codec-fixtures", sha256: "c2b38959b9f8cafeefcf8ad9ee9bb1b3aed6a740379fb399646c7def3c461c50")
        XCTAssertEqual(doc.profile, DeviceDeliveryCandidateCodec.observationProfile); XCTAssertEqual(doc.identity, "observationDigest")
        XCTAssertEqual(doc.cases.count, 6)
        for fixture in doc.cases {
            let v = fixture.value
            let input = try DeviceDeliveryObservationCandidate.validating(
                installationID: XCTUnwrap(UUID(uuidString: XCTUnwrap(v.installationId))),
                transitionID: XCTUnwrap(UUID(uuidString: XCTUnwrap(v.transitionId))),
                generationID: XCTUnwrap(UUID(uuidString: XCTUnwrap(v.generationId))), entries: entries(v), configuredEntryID: selected(v))
            XCTAssertEqual(hex(try DeviceDeliveryCandidateCodec.observationBytes(input)), fixture.hex, fixture.name)
            #if canImport(CryptoKit)
            XCTAssertEqual(try DeviceDeliveryCandidateCodec.observationDigest(input), fixture.observationDigest, fixture.name)
            #else
            XCTAssertThrowsError(try DeviceDeliveryCandidateCodec.observationDigest(input)) { XCTAssertEqual($0 as? DeviceDeliveryCandidateFailure, .digestUnavailable) }
            #endif
        }
    }
    func testCommittedResultingSetGoldenBytesAndDigest() throws {
        let doc = try document("resulting-set-codec-fixtures", sha256: "c1eada5b6e3a4115686dab3582c86fe1bbeb1fcebc7a6149f12bac6f3dbb7e09")
        XCTAssertEqual(doc.profile, DeviceDeliveryCandidateCodec.resultingSetProfile); XCTAssertEqual(doc.identity, "resultingSetDigest")
        XCTAssertEqual(doc.cases.count, 6)
        for fixture in doc.cases {
            let input = try DeviceResultingSetCandidate.validating(entries: entries(fixture.value), configuredEntryID: selected(fixture.value))
            XCTAssertEqual(hex(try DeviceDeliveryCandidateCodec.resultingSetBytes(input)), fixture.hex, fixture.name)
            #if canImport(CryptoKit)
            XCTAssertEqual(try DeviceDeliveryCandidateCodec.resultingSetDigest(input), fixture.resultingSetDigest, fixture.name)
            #else
            XCTAssertThrowsError(try DeviceDeliveryCandidateCodec.resultingSetDigest(input)) { XCTAssertEqual($0 as? DeviceDeliveryCandidateFailure, .digestUnavailable) }
            #endif
        }
    }
    func testStrictBoundedASCIIHashes() throws {
        for invalid in [String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "a", count: 64) + "\n",
            String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "ａ", count: 64), String(repeating: "a", count: 8192)] {
            XCTAssertThrowsError(try DeviceDeliveryCandidateHash.validating(invalid)) { XCTAssertEqual($0 as? DeviceDeliveryCandidateFailure, .invalidHash) }
        }
        XCTAssertEqual(try hash().text, String(repeating: "a", count: 64))
    }
    func testPackageProfileAndExactNumericLimits() throws {
        _ = try package(compressed: 26_214_400, expanded: 52_428_800, archiveEntries: 2000)
        for profile in ["other", DeviceDeliveryPackageCandidate.profile + "\n", DeviceDeliveryPackageCandidate.profile + String(repeating: "x", count: 8192)] {
            XCTAssertThrowsError(try package(profile: profile))
        }
        for value in [UInt64(0), 26_214_401, UInt64.max] { XCTAssertThrowsError(try package(compressed: value)) }
        for value in [UInt64(0), 52_428_801, UInt64.max] { XCTAssertThrowsError(try package(expanded: value)) }
        for value in [UInt64(0), 2001, UInt64.max] { XCTAssertThrowsError(try package(archiveEntries: value)) }
    }
    func testSelectionDuplicateIdentityAndCapacityGuards() throws {
        let entry = try retained(20)
        _ = try DeviceResultingSetCandidate.validating(entries: [], configuredEntryID: nil)
        XCTAssertThrowsError(try DeviceResultingSetCandidate.validating(entries: [], configuredEntryID: id(20)))
        XCTAssertThrowsError(try DeviceResultingSetCandidate.validating(entries: [entry], configuredEntryID: nil))
        XCTAssertThrowsError(try DeviceResultingSetCandidate.validating(entries: [entry], configuredEntryID: id(21)))
        XCTAssertThrowsError(try DeviceResultingSetCandidate.validating(entries: [entry, entry], configuredEntryID: id(20)))
        let p = try package()
        let clouds = [DeviceDeliveryEntryCandidate.validating(entryID: id(30), provenance: .cloud(p)), .validating(entryID: id(31), provenance: .cloud(p))]
        XCTAssertThrowsError(try DeviceResultingSetCandidate.validating(entries: clouds, configuredEntryID: id(30)))
        XCTAssertThrowsError(try DeviceResultingSetCandidate.validating(entries: (0..<13).map { try retained($0 + 50) }, configuredEntryID: id(50)))
    }
    func testMaximumLegalCloudSetFitsBothByteProfilesExactly() throws {
        let entries = try (0..<12).map { n in DeviceDeliveryEntryCandidate.validating(entryID: id(n + 100),
            provenance: .cloud(try package(dashboard: n + 200, compressed: 26_214_400, expanded: 52_428_800, archiveEntries: 2000))) }
        let input = try DeviceDeliveryObservationCandidate.validating(installationID: id(1), transitionID: id(2), generationID: id(3),
            entries: entries, configuredEntryID: entries.last!.entryID)
        let observed = try DeviceDeliveryCandidateCodec.observationBytes(input), resulting = try DeviceDeliveryCandidateCodec.resultingSetBytes(input.resultingSet)
        XCTAssertEqual(observed.count, 7125); XCTAssertEqual(resulting.count, 6998)
        XCTAssertEqual(observed.count, DeviceDeliveryCandidateCodec.maximumObservationBytes)
        XCTAssertEqual(resulting.count, DeviceDeliveryCandidateCodec.maximumResultingSetBytes)
        XCTAssertLessThan(observed.count, DeviceDeliveryCandidateCodec.maximumEncodedBytes)
    }
    func testOrderSelectionAndScopeHaveTheirSeparateByteDomains() throws {
        let entries = try [retained(20), retained(21)]
        let first = try DeviceDeliveryObservationCandidate.validating(installationID: id(1), transitionID: id(2), generationID: id(3), entries: entries, configuredEntryID: id(20))
        let result = try DeviceDeliveryCandidateCodec.resultingSetBytes(first.resultingSet)
        for scope in [(id(9), id(2), id(3)), (id(1), id(9), id(3)), (id(1), id(2), id(9))] {
            let changed = try DeviceDeliveryObservationCandidate.validating(installationID: scope.0, transitionID: scope.1, generationID: scope.2, entries: entries, configuredEntryID: id(20))
            XCTAssertNotEqual(try DeviceDeliveryCandidateCodec.observationBytes(first), try DeviceDeliveryCandidateCodec.observationBytes(changed))
            XCTAssertEqual(result, try DeviceDeliveryCandidateCodec.resultingSetBytes(changed.resultingSet))
        }
        XCTAssertNotEqual(result, try DeviceDeliveryCandidateCodec.resultingSetBytes(.validating(entries: Array(entries.reversed()), configuredEntryID: id(20))))
        XCTAssertNotEqual(result, try DeviceDeliveryCandidateCodec.resultingSetBytes(.validating(entries: entries, configuredEntryID: id(21))))
        XCTAssertNotEqual(result, try DeviceDeliveryCandidateCodec.observationBytes(first))
    }
    func testEveryCloudPackageBindingChangesResultingBytes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "native-delivery-codec-fixtures", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let mixed = try XCTUnwrap(cases.first(where: { $0["name"] as? String == "mixed" })?["value"] as? [String: Any])
        func bytes(_ value: [String: Any]) throws -> Data {
            let input = try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: value))
            return try DeviceDeliveryCandidateCodec.resultingSetBytes(.validating(entries: entries(input), configuredEntryID: selected(input)))
        }
        let original = try bytes(mixed)
        for field in ["publicationId", "projectId", "packageId", "dashboardId", "revision", "manifestDigest", "manifestSha256", "archiveSha256", "compressedBytes", "expandedBytes", "archiveEntries"] {
            var changed = mixed
            var es = try XCTUnwrap(changed["entries"] as? [[String: Any]])
            var provenance = try XCTUnwrap(es[1]["provenance"] as? [String: Any])
            var package = try XCTUnwrap(provenance["package"] as? [String: Any])
            if ["compressedBytes", "expandedBytes", "archiveEntries"].contains(field) {
                package[field] = try XCTUnwrap(package[field] as? Int) + 1
            } else if ["manifestDigest", "manifestSha256", "archiveSha256"].contains(field) {
                package[field] = String(repeating: "e", count: 64)
            } else { package[field] = id(999).uuidString }
            provenance["package"] = package; es[1]["provenance"] = provenance; changed["entries"] = es
            XCTAssertNotEqual(original, try bytes(changed), field)
        }
        for field in ["retainedEntryId", "manifestDigest"] {
            var changed = mixed
            var es = try XCTUnwrap(changed["entries"] as? [[String: Any]])
            var provenance = try XCTUnwrap(es[0]["provenance"] as? [String: Any])
            provenance[field] = field == "retainedEntryId" ? id(999).uuidString : String(repeating: "e", count: 64)
            es[0]["provenance"] = provenance; changed["entries"] = es
            XCTAssertNotEqual(original, try bytes(changed), field)
        }
    }
}
