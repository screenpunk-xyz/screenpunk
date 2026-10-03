import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceStructuralStateTests: XCTestCase {
    private let generation = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let entryID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let owner = PairingIdentity(role: .controller, publicKey: Array(repeating: 7, count: 32))
    private var package: DeviceStructuralPackageEvidence { .init(directory: "package", revision: .offlineFixture) }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(value)
    }
    private func read(_ structural: DeviceStructuralInput = .missing, legacy: DeviceStructuralInput = .missing,
        bound: Bool = false, packages: [DeviceStructuralPackageEvidence] = []) -> DeviceStructuralRead {
        DeviceStructuralStateReader.read(structural: structural, legacy: legacy,
            expectation: bound ? .bound(generationID: generation) : .unbound, packages: packages)
    }
    private func snapshot(empty: Bool = false) -> DeviceStructuralSnapshot {
        .init(generationID: generation, entries: empty ? [] : [.init(entryID: entryID, displayName: "Private household display name", revision: .offlineFixture, packageDirectory: "package")],
              configuredEntryID: empty ? nil : entryID, contentOwner: owner, grantSet: "legacy-grants-not-a-uuid")
    }
    private func legacy() -> DevicePersistedState {
        let stored = StoredRevision.offlineFixture
        let deployment = DeploymentRecord(deploymentId: "local-deploy", revision: stored.revision, dashboardId: stored.dashboardId, deviceId: "device", phase: .active)
        var state = DevicePersistedState(owner: owner, activeRevision: stored.revision, activeStoredRevision: stored, lastDeployment: deployment,
                                        savedAt: Date(timeIntervalSince1970: 0))
        state.contentOwner = owner
        state.screenSet = .init(deploymentId: "local-deploy", contentDigest: "body-digest", grantSet: "old-grant",
            screens: [.init(name: "Private household name", revision: stored, deployment: deployment, packageDirectory: "package")], selectedDashboardId: stored.dashboardId)
        state.screenSet?.deployedSelectedDashboardId = "removed-original-screen"
        return state
    }
    func testAbsentKnownBindingAndExplicitEmptyAreDistinct() throws {
        XCTAssertEqual(read(), .absent)
        XCTAssertEqual(read(bound: true), .blocked(.missingBinding))
        XCTAssertEqual(read(.readError), .blocked(.readError))
        XCTAssertEqual(read(packages: [package]), .blocked(.packageMismatch))
        let empty = snapshot(empty: true)
        XCTAssertEqual(read(.bytes(try encode(empty)), bound: true), .bound(empty))
        let state = DevicePersistedState(owner: nil, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil, savedAt: Date(timeIntervalSince1970: 0))
        #if !canImport(CryptoKit)
        XCTAssertEqual(read(legacy: .bytes(try encode(state))), .blocked(.digestUnavailable))
        return
        #endif
        guard case .legacyUnbound(let evidence) = read(legacy: .bytes(try encode(state))) else { return XCTFail() }
        XCTAssertEqual(evidence.kind, .empty)
    }
    func testLegacyPreservesBytesOwnerGrantsSelectionsAndNoIdentity() throws {
        #if !canImport(CryptoKit)
        XCTAssertEqual(read(legacy: .bytes(try encode(legacy())), packages: [package]), .blocked(.digestUnavailable))
        return
        #endif
        var state = legacy()
        state.settings = .init(revision: "existing-settings", value: .init(startingPageByDashboard: ["場所": "ページ"]))
        let bytes = try encode(state)
        let result = read(legacy: .bytes(bytes), packages: [package])
        XCTAssertEqual(result, read(legacy: .bytes(bytes), packages: [package]))
        guard case .legacyUnbound(let evidence) = result else { return XCTFail() }
        XCTAssertEqual(evidence.kind, .orderedSet); XCTAssertEqual(evidence.originalBytes, bytes)
        XCTAssertEqual(evidence.originalSHA256, PeerPin.hex(PeerPin.sha256(bytes)))
        XCTAssertEqual(evidence.state, state); XCTAssertNil(evidence.configuredEntryID)
        XCTAssertEqual(read(legacy: .bytes(bytes), packages: []), .blocked(.packageMismatch))
        state.screenSet = nil
        guard case .legacyUnbound(let single) = read(legacy: .bytes(try encode(state)), packages: [package]) else { return XCTFail() }
        XCTAssertEqual(single.kind, .singlePackage)
        state.activeRevision = "contradiction"
        XCTAssertEqual(read(legacy: .bytes(try encode(state)), packages: [package]), .blocked(.invalidState))
    }
    func testBoundIdentitySelectionReferencesAndLimits() throws {
        let valid = snapshot(); XCTAssertNotEqual(valid.entries[0].displayName, valid.entries[0].revision.name); XCTAssertEqual(read(.bytes(try encode(valid)), packages: [package]), .bound(valid))
        var changed = valid; changed.entries.append(changed.entries[0])
        XCTAssertEqual(read(.bytes(try encode(changed)), packages: [package]), .blocked(.invalidState))
        changed = valid; changed.configuredEntryID = generation
        XCTAssertEqual(read(.bytes(try encode(changed)), packages: [package]), .blocked(.invalidState))
        changed = valid; changed.entries[0].packageDirectory = "package.staging-../escape"
        XCTAssertEqual(read(.bytes(try encode(changed)), packages: [package]), .blocked(.packageMismatch))
        changed = valid; changed.schemaVersion = 2
        XCTAssertEqual(read(.bytes(try encode(changed)), packages: [package]), .blocked(.unsupportedSchema))
        changed = valid; changed.generationID = entryID
        XCTAssertEqual(read(.bytes(try encode(changed)), bound: true, packages: [package]), .blocked(.invalidState))
        XCTAssertEqual(read(.bytes(Data(repeating: 32, count: 64*1024+1))), .blocked(.oversized))
        XCTAssertEqual(read(legacy: .bytes(Data(repeating: 32, count: 4*1024*1024+1))), .blocked(.oversized))
    }
    func testCapacityAndStrictLegacyNestedFields() throws {
        var state = snapshot(empty: true)
        var supplied: [DeviceStructuralPackageEvidence] = []
        for index in 1...12 {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
            var revision = StoredRevision.offlineFixture
            revision.dashboardId = "dashboard-\(index)"; revision.revision = "revision-\(index)"
            let directory = "package.staging-\(index)"
            state.entries.append(.init(entryID: id, displayName: "Display \(index)", revision: revision, packageDirectory: directory))
            supplied.append(.init(directory: directory, revision: revision))
        }
        state.configuredEntryID = state.entries[0].entryID
        XCTAssertEqual(read(.bytes(try encode(state)), packages: supplied), .bound(state))
        var extra = state.entries[0]; extra.entryID = generation; extra.revision.dashboardId = "extra"
        state.entries.append(extra)
        XCTAssertEqual(read(.bytes(try encode(state)), packages: supplied), .blocked(.invalidState))
        var old = legacy()
        old.settings = .init(revision: "settings", value: .init(eventRuleOverrides: ["dashboard": ["rule": .init(pageId: "page")]]))
        let original = String(decoding: try encode(old), as: UTF8.self)
        let unknown = original.replacingOccurrences(of: "\"timeoutSeconds\":30", with: "\"timeoutSeconds\":30,\"futureField\":1")
        XCTAssertNotEqual(original, unknown)
        XCTAssertEqual(read(legacy: .bytes(Data(unknown.utf8)), packages: [package]), .blocked(.invalidJSON))
        let duplicate = original.replacingOccurrences(of: "\"pageId\":\"page\"", with: "\"pageId\":\"page\",\"page\\u0049d\":\"page\"")
        XCTAssertNotEqual(original, duplicate)
        XCTAssertEqual(read(legacy: .bytes(Data(duplicate.utf8)), packages: [package]), .blocked(.invalidJSON))
    }
    func testStrictJSONDuplicatesUnknownNestedFieldsAndUnicode() throws {
        let bytes = try encode(snapshot())
        let text = String(decoding: bytes, as: UTF8.self)
        let invalid = [
            text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
            text.replacingOccurrences(of: "\"provenance\":\"retainedLocal\"", with: "\"provenance\":\"retainedLocal\",\"proven\\u0061nce\":\"retainedLocal\""),
            text.replacingOccurrences(of: "\"provenance\":\"retainedLocal\"", with: "\"provenance\":\"futureCloud\""),
            text.replacingOccurrences(of: "\"orientation\":\"portrait\"", with: "\"orientation\":\"portrait\",\"future\":true"),
            text.replacingOccurrences(of: "Offline fixture", with: "\\uD800"),
            text.replacingOccurrences(of: "Offline fixture", with: "\\uDC00"),
            text + "{}", text + ",", text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1e+"),
            "{\"a\":" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}"
        ]
        for value in invalid { XCTAssertEqual(read(.bytes(Data(value.utf8)), packages: [package]), .blocked(.invalidJSON), value) }
        var utf8 = bytes; utf8.append(0xff)
        XCTAssertEqual(read(.bytes(utf8)), .blocked(.invalidJSON))
        let pair = text.replacingOccurrences(of: "Offline fixture", with: "\\uD83D\\uDE00")
        var modified = snapshot(); modified.entries[0].revision.name = "😀"
        let modifiedPackage = DeviceStructuralPackageEvidence(directory: "package", revision: modified.entries[0].revision)
        XCTAssertEqual(read(.bytes(Data(pair.utf8)), packages: [modifiedPackage]), .bound(modified))
        let unicodeKeys = "{\"é\":1,\"\\u00e9\":2}"
        XCTAssertEqual(read(.bytes(Data(unicodeKeys.utf8))), .blocked(.invalidJSON))
        XCTAssertEqual(read(.bytes(Data(("[" + Array(repeating: "0", count: 4097).joined(separator: ",") + "]").utf8))), .blocked(.invalidJSON))
        XCTAssertEqual(read(.bytes(Data(String(repeating: "😀", count: 16385).utf8))), .blocked(.oversized))
        let exponent = text.replacingOccurrences(of: "\"width\":390", with: "\"width\":3.9e2")
        XCTAssertEqual(read(.bytes(Data(exponent.utf8)), packages: [package]), .bound(snapshot()))
    }
}
