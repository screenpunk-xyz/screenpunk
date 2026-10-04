import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceManagementAuthorityTests: XCTestCase {
    func testManagedAppearanceRevokesLeaseRenderingAndResetAndNeverBecomesLegacyAgain() throws {
        let anchor = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: anchor) }
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { XCTFail("no keys"); return Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor))
        let lease = try XCTUnwrap(authority.refresh())
        let namespace = anchor.appendingPathComponent("xyz.screenpunk.native-managed")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
        var effects = 0
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) { effects += 1 })
        XCTAssertEqual(effects, 0)
        XCTAssertFalse(authority.resetRenderingAllowed())
        XCTAssertThrowsError(try authority.resetRecoverySnapshot())
        try FileManager.default.removeItem(at: namespace)
        XCTAssertNil(try authority.refresh())
        XCTAssertThrowsError(try authority.requireLegacyNamespaceAbsent())
    }

    private func history() throws -> DeviceManagementTransitionHistory {
        try .intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: UUID().uuidString)
    }
    private func owner(_ journal: AuthorityJournal, _ backend: AuthorityBackend) -> DeviceManagementAuthority {
        .init(journal: journal, credentials: .init(backend: backend, random: { Data(repeating: 9, count: 32) }), reset: ManagementTestResetEvidence(), managedNamespace: testManagedNamespaceInspector())
    }
    func testRefreshRevokesPriorLeaseAndForeignLeaseRejected() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let first = try XCTUnwrap(authority.refresh())
        let second = try XCTUnwrap(authority.refresh())
        XCTAssertThrowsError(try authority.withLocalAuthority(first) {})
        try authority.withLocalAuthority(second) {}
        XCTAssertThrowsError(try owner(journal, backend).withLocalAuthority(second) {})
        try authority.revoke()
        XCTAssertThrowsError(try authority.withLocalAuthority(second) {})
    }
    func testPendingOrphanMissingAndInaccessibleBlock() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        backend.values["orphan"] = Data(repeating: 9, count: 32)
        XCTAssertNil(try authority.refresh())
        backend.values = [:]
        journal.value = try history()
        XCTAssertNil(try authority.refresh())
        backend.values[journal.value!.credentials[0].credentialReference] = Data(repeating: 9, count: 32)
        XCTAssertNil(try authority.refresh())
        journal.value = try journal.value!.fenced()
        let fencedAuthority = owner(journal, backend)
        XCTAssertNotNil(try fencedAuthority.refresh())
        backend.inaccessible = true
        XCTAssertNil(try authority.refresh())
        backend.inaccessible = false; journal.unavailable = true
        XCTAssertNil(try authority.refresh())
    }
    func testFreshEvidenceChangeRevokesBeforeSideEffectEvenIfNewHistoryFenced() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        journal.value = try history().fenced()
        backend.values[journal.value!.credentials[0].credentialReference] = Data(repeating: 9, count: 32)
        var ran = false
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) { ran = true })
        XCTAssertFalse(ran)
        XCTAssertNil(try authority.refresh())
    }
    func testObservedHistoryDisappearanceAndRollbackNeverBecomesLegacy() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend()
        let first = try history().fenced()
        let second = try first.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "next").fenced()
        journal.value = second
        for binding in second.credentials { backend.values[binding.credentialReference] = Data(repeating: 9, count: 32) }
        let authority = owner(journal, backend)
        XCTAssertNotNil(try authority.refresh())
        journal.value = first; backend.values.removeValue(forKey: "next")
        XCTAssertNil(try authority.refresh())
        journal.value = nil; backend.values = [:]
        XCTAssertNil(try authority.refresh())
    }
    func testKeyBecomingUnreadableRejectsLeaseAtOperationEntry() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        backend.inaccessible = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) { XCTFail("must not run") })
    }
    func testInitialUnavailableEvidenceCanRecoverButNeverReuseLease() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        journal.unavailable = true
        XCTAssertNil(try authority.refresh())
        journal.unavailable = false
        let lease = try XCTUnwrap(authority.refresh())
        backend.inaccessible = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        backend.inaccessible = false
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        XCTAssertNotNil(try authority.refresh())
    }
    func testSameFencedHistoryUnreadableKeyCanReclassifyWithNewLease() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend()
        journal.value = try history().fenced()
        backend.values[journal.value!.credentials[0].credentialReference] = Data(repeating: 9, count: 32)
        let authority = owner(journal, backend), lease = try XCTUnwrap(authority.refresh())
        backend.inaccessible = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        backend.inaccessible = false
        let recovered = try XCTUnwrap(authority.refresh())
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        try authority.withLocalAuthority(recovered) {}
    }
    func testJournalUncertaintyRevokesPreviouslyIssuedLease() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        journal.unavailable = true
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        XCTAssertNil(try authority.refresh())
    }
    func testReentrantCallsRejectWithoutInvalidatingCurrentOperation() throws {
        let journal = AuthorityJournal(), backend = AuthorityBackend(), authority = owner(journal, backend)
        let lease = try XCTUnwrap(authority.refresh())
        try authority.withLocalAuthority(lease) {
            XCTAssertThrowsError(try authority.revoke()) { XCTAssertEqual($0 as? DeviceManagementAuthority.Failure, .reentrantOperation) }
            XCTAssertThrowsError(try authority.refresh())
            XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
        }
        try authority.withLocalAuthority(lease) {}
    }
    func testRevocationWaitsForGatedOperationThenRejectsOldLease() throws {
        let authority = owner(AuthorityJournal(), AuthorityBackend())
        let lease = try XCTUnwrap(authority.refresh())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let operationDone = expectation(description: "operation"), revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { operationDone.fulfill() }
            do { try authority.withLocalAuthority(lease) { entered.signal(); _ = release.wait(timeout: .now() + 3) } }
            catch { XCTFail("unexpected gate failure") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async { try? authority.revoke(); revoked.signal() }
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        wait(for: [operationDone], timeout: 3)
        XCTAssertEqual(revoked.wait(timeout: .now() + 3), .success)
        XCTAssertThrowsError(try authority.withLocalAuthority(lease) {})
    }
}

private final class AuthorityJournal: CloudInstallationTransitionJournal {
    var value: DeviceManagementTransitionHistory?
    var unavailable = false
    var writeThenThrow = false
    func load() throws -> DeviceManagementTransitionHistory? {
        if unavailable { throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
        return value
    }
    func save(_ history: DeviceManagementTransitionHistory) throws {
        value = history
        if writeThenThrow { unavailable = true; throw DeviceManagementTransitionStoreError.writeOutcomeUncertain }
    }
}
private final class AuthorityBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
    var values: [String: Data] = [:]
    var inaccessible = false
    func read(reference: String) throws -> Data? {
        if inaccessible { throw CloudInstallationCredentialError.inaccessible(status: -25308) }
        return values[reference]
    }
    func references() throws -> Set<String> {
        if inaccessible { throw CloudInstallationCredentialError.inaccessible(status: -25308) }
        return Set(values.keys)
    }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert {
        values[reference] = secret
        return .inserted
    }
}
