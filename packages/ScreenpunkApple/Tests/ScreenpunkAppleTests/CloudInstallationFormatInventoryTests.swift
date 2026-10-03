import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class CloudInstallationFormatInventoryTests: XCTestCase {
    func testCompleteMixedInventoryAndAllMismatchCases() throws {
        let backend = FormatInventoryBackend()
        let store = CloudInstallationCredentialStore(backend: backend, random: { fatalError("No insertion") })
        let id = UUID()
        let bindings = try [DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: id, credentialReference: "legacy", format: .legacyLocal32), .init(credentialGenerationID: UUID(), transitionID: id, credentialReference: "native", format: .nativeInstallationV1)]
        let h = try DeviceManagementFormatHistory(transitions: [.init(transitionID: id, phase: .locallyFenced)], credentials: bindings)
        backend.values = ["legacy": Data(repeating: 1, count: 32), "native": Data(repeating: 2, count: 48)]
        let journal = NativeFormatJournal(history: h)
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: store), .blocked(.nativeAuthorityUnresolved))
        let owner = DeviceManagementAuthority(journal: journal, credentials: store, reset: ManagementTestResetEvidence())
        XCTAssertNil(try owner.refresh())
        XCTAssertEqual(try store.inventory(history: h), ["legacy": .legacyLocal32, "native": .nativeInstallationV1])
        XCTAssertThrowsError(try store.secret(for: "native"), "Legacy reader never interprets native bytes")
        backend.values["unknown"] = Data(repeating: 3, count: 48)
        XCTAssertThrowsError(try store.inventory(history: h))
        backend.values.removeValue(forKey: "unknown"); backend.values.removeValue(forKey: "native")
        XCTAssertThrowsError(try store.inventory(history: h))
        backend.values["native"] = Data(repeating: 2, count: 32)
        XCTAssertThrowsError(try store.inventory(history: h))
        backend.unavailable = true
        XCTAssertThrowsError(try store.inventory(history: h))
        XCTAssertEqual(backend.inserts, 0)
    }
}
final class FormatInventoryBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
    var values: [String: Data] = [:]
    var unavailable = false
    var inserts = 0
    var referenceCalls = 0
    var failReferenceCall: Int?
    var onReferenceCall: ((Int) throws -> Void)?
    func read(reference: String) throws -> Data? { if unavailable { throw CloudInstallationCredentialError.inaccessible(status: -25308) }; return values[reference] }
    func references() throws -> Set<String> { referenceCalls += 1; try onReferenceCall?(referenceCalls); if referenceCalls == failReferenceCall { throw CloudInstallationCredentialError.inaccessible(status: -25308) }; if unavailable { throw CloudInstallationCredentialError.inaccessible(status: -25308) }; return Set(values.keys) }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { inserts += 1; fatalError("No insertion") }
}

private final class NativeFormatJournal: CloudInstallationTransitionJournal {
    let history: DeviceManagementFormatHistory
    init(history: DeviceManagementFormatHistory) { self.history = history }
    func loadEvidence() throws -> DeviceManagementEvidence? { .formatted(history) }
    func load() throws -> DeviceManagementTransitionHistory? { throw DeviceManagementTransitionStoreError.unsupportedVersion(3) }
    func save(_ history: DeviceManagementTransitionHistory) throws { fatalError("No writes") }
}
