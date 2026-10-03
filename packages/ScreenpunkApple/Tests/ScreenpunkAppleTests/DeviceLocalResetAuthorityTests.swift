import XCTest
@testable import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceLocalResetAuthorityTests: XCTestCase {
    private func authority(_ reset: ResetEvidenceFixture) -> DeviceManagementAuthority {
        .init(journal: ResetManagementFixture(), credentials: .init(backend: ResetCredentialFixture(), random: { Data() }), reset: reset)
    }
    func testPendingCorruptAndMismatchedResetBlockAdmissionAndRendering() throws {
        for mode in 0..<3 {
            let reset = ResetEvidenceFixture()
            if mode == 0 { reset.record = try reset.pending() }
            if mode == 1 { reset.failedRead = true }
            if mode == 2 { reset.record = try .init(resetID: UUID(), scopeDigest: String(repeating: "b", count: 64), phase: .completed) }
            let owner = authority(reset)
            XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
        }
    }
    func testCompletedResetDisappearanceBlocksAndCloudFailureStillAllowsRetained() throws {
        let reset = ResetEvidenceFixture(); reset.record = try reset.pending().completed()
        let owner = authority(reset)
        XCTAssertNotNil(try owner.refresh())
        reset.record = nil
        XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
        let badCloud = DeviceManagementAuthority(journal: BrokenResetManagementFixture(), credentials: .init(backend: ResetCredentialFixture(), random: { Data() }), reset: ResetEvidenceFixture())
        XCTAssertNil(try badCloud.refresh()); XCTAssertTrue(badCloud.resetRenderingAllowed())
    }
    func testExternalResetRevokesLeaseAndCannotDisappearIntoPermission() throws {
        let reset = ResetEvidenceFixture(), owner = authority(reset)
        let lease = try XCTUnwrap(owner.refresh())
        reset.record = try reset.pending()
        XCTAssertThrowsError(try owner.withLocalAuthority(lease) { XCTFail("blocked") })
        reset.record = nil
        XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
    }
    func testPendingWriteUncertaintyBeforeAndAfterReplacementExactRetry() throws {
        for replacement in [false, true] {
            let reset = ResetEvidenceFixture(), owner = authority(reset)
            let lease = try XCTUnwrap(owner.refresh()), pending = try reset.pending()
            reset.failNextWrite = true; reset.replaceBeforeFailure = replacement
            XCTAssertThrowsError(try owner.beginLocalReset(lease, record: pending))
            XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
            XCTAssertThrowsError(try owner.withLocalAuthority(lease) {})
            try owner.recommitResetAttempt()
            XCTAssertEqual(reset.methods, ["save", "save"])
            XCTAssertEqual(reset.record, pending)
            XCTAssertNil(try owner.refresh())
        }
    }
    func testNewResetUsesExactBeginMethodAndCompletionNeverRevivesContext() throws {
        let reset = ResetEvidenceFixture()
        reset.record = try reset.pending().completed()
        let owner = authority(reset), lease = try XCTUnwrap(owner.refresh())
        let context = DeviceManagementContext(authority: owner, lease: lease), pending = try reset.pending()
        reset.failNextWrite = true
        XCTAssertThrowsError(try context.beginLocalReset(record: pending))
        try owner.recommitResetAttempt()
        XCTAssertEqual(reset.methods, ["begin", "begin"])
        reset.failNextWrite = true; reset.replaceBeforeFailure = true
        XCTAssertThrowsError(try owner.completeLocalReset(expected: pending))
        XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
        try owner.recommitResetAttempt()
        XCTAssertEqual(reset.methods, ["begin", "begin", "save", "save"])
        XCTAssertThrowsError(try context.validate())
        XCTAssertNotNil(try owner.refresh())
    }
    func testRestartPendingCanCompleteOnlyExactConfiguredBinding() throws {
        let reset = ResetEvidenceFixture(), pending = try reset.pending()
        reset.record = pending
        let owner = authority(reset)
        XCTAssertNil(try owner.refresh())
        XCTAssertThrowsError(try owner.completeLocalReset(expected: reset.pending()))
        XCTAssertTrue(reset.methods.isEmpty)
        try owner.completeLocalReset(expected: pending)
        XCTAssertNotNil(try owner.refresh())
    }
    func testConcurrentBeginOnlyOneAttemptAccepted() throws {
        let reset = ResetEvidenceFixture(), owner = authority(reset)
        let lease = try XCTUnwrap(owner.refresh())
        let records = try [reset.pending(), reset.pending()]
        DispatchQueue.concurrentPerform(iterations: 2) { index in try? owner.beginLocalReset(lease, record: records[index]) }
        XCTAssertEqual(reset.methods.count, 1)
        XCTAssertNil(try owner.refresh())
    }
    @MainActor func testResetBlockedBootstrapNeverLoadsRetainedOrHost() throws {
        for mode in 0..<3 {
            let reset = ResetEvidenceFixture()
            if mode == 0 { reset.record = try reset.pending() }
            if mode == 1 { reset.failedRead = true }
            if mode == 2 { reset.record = try .init(resetID: UUID(), scopeDigest: String(repeating: "b", count: 64), phase: .completed) }
            var retained = 0, hosts = 0
            let bootstrap = DeviceManagementBootstrap(authority: authority(reset), retained: { retained += 1; return .empty }, hostFactory: { _ in hosts += 1; throw DeviceManagementAuthority.Failure.resetConflict })
            bootstrap.start()
            XCTAssertEqual(retained, 0); XCTAssertEqual(hosts, 0)
        }
    }
    func testRealStoreEveryPendingCommitBoundaryRequiresExactRecommit() throws {
        for boundary in [DeviceLocalResetCommitBoundary.afterTemporaryWrite, .afterFileSync, .beforeReplace, .afterReplace, .afterDirectorySync] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = ResetFaultSwitch()
            let store = DeviceLocalResetStore(directory: directory) { if fault.enabled && $0 == boundary { throw DeviceManagementAuthority.Failure.resetConflict } }
            let base = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            let scope = try DeviceLocalResetScope(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("preferences"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: directory, credentialItems: [])
            let reset = DeviceLocalResetEvidenceAdapter(scope: scope, store: store)
            let owner = DeviceManagementAuthority(journal: ResetManagementFixture(), credentials: .init(backend: ResetCredentialFixture(), random: { Data() }), reset: reset)
            let lease = try XCTUnwrap(owner.refresh()), pending = try DeviceLocalResetRecord(resetID: UUID(), scopeDigest: scope.digest)
            XCTAssertThrowsError(try owner.beginLocalReset(lease, record: pending))
            XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
            fault.enabled = false
            try owner.recommitResetAttempt()
            XCTAssertEqual(try store.load(), pending)
            fault.enabled = true
            XCTAssertThrowsError(try owner.completeLocalReset(expected: pending))
            XCTAssertNil(try owner.refresh()); XCTAssertFalse(owner.resetRenderingAllowed())
            fault.enabled = false
            try owner.recommitResetAttempt()
            XCTAssertEqual(try store.load(), try pending.completed())
            XCTAssertNotNil(try owner.refresh())
            XCTAssertThrowsError(try owner.withLocalAuthority(lease) {})
        }
    }
    func testAdapterRejectsMismatchedJournalDirectoryWithoutWriting() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scope = try DeviceLocalResetScope(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("preferences"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: base.appendingPathComponent("resetA"), credentialItems: [])
        let pending = try DeviceLocalResetRecord(resetID: UUID(), scopeDigest: scope.digest)
        for directory in [base.appendingPathComponent("resetB"), base.appendingPathComponent("device/resetB"), base.appendingPathComponent("preferences/resetB")] {
            let adapter = DeviceLocalResetEvidenceAdapter(scope: scope, store: .init(directory: directory))
            XCTAssertThrowsError(try adapter.scopeDigest)
            XCTAssertThrowsError(try adapter.load())
            XCTAssertThrowsError(try adapter.save(pending))
            XCTAssertThrowsError(try adapter.beginNewReset(pending))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        let matching = DeviceLocalResetEvidenceAdapter(scope: scope, store: .init(directory: scope.resetDirectory))
        XCTAssertEqual(try matching.scopeDigest, scope.digest)
        XCTAssertNil(try matching.load())
    }
    func testCredentialBindingsUseAdapterConstantsAndRejectOtherServices() throws {
        let items = DeviceLocalResetScope.allowedCredentialItems
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.contains(.init(service: GoogleCalendarDeviceService.storageService, account: GoogleCalendarDeviceService.storageKey)))
        XCTAssertTrue(items.contains(.init(service: GenericConnectionDeviceVault.storageService, account: GenericConnectionDeviceVault.storageKey)))
        XCTAssertFalse(items.contains { $0.service == CloudInstallationCredentialStore.service })
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DeviceLocalResetScope(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("prefs"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: base.appendingPathComponent("reset"), credentialItems: [.init(service: "unapproved", account: "key")]))
    }
    func testScopeCanonicalAliasesStableAndOverlapAndSymlinkRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func scope(_ device: URL, _ preference: URL) throws -> DeviceLocalResetScope {
            try .init(deviceRoot: device, preferencesRoot: preference, managementDirectory: root.appendingPathComponent("management"), resetDirectory: root.appendingPathComponent("reset"), credentialItems: [])
        }
        let device = root.appendingPathComponent("device"), preferences = root.appendingPathComponent("preferences")
        let first = try scope(device, preferences)
        let alias = URL(fileURLWithPath: device.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        XCTAssertEqual(first.digest, try scope(alias, preferences).digest)
        XCTAssertThrowsError(try scope(root, preferences))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: device)
        XCTAssertThrowsError(try scope(link, preferences))
    }
}
private final class ResetEvidenceFixture: DeviceLocalResetEvidence {
    let scopeDigest = String(repeating: "a", count: 64)
    var record: DeviceLocalResetRecord?
    var failedRead = false
    var uncertain = false
    var failNextWrite = false
    var replaceBeforeFailure = false
    var methods: [String] = []
    func pending() throws -> DeviceLocalResetRecord { try .init(resetID: UUID(), scopeDigest: scopeDigest) }
    func load() throws -> DeviceLocalResetRecord? { if failedRead || uncertain { throw DeviceLocalResetStoreError.writeOutcomeUncertain }; return record }
    func save(_ record: DeviceLocalResetRecord) throws { try write(record, method: "save") }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { try write(record, method: "begin") }
    private func write(_ value: DeviceLocalResetRecord, method: String) throws {
        methods.append(method)
        if failNextWrite {
            failNextWrite = false; uncertain = true
            if replaceBeforeFailure { record = value }
            throw DeviceLocalResetStoreError.writeOutcomeUncertain
        }
        record = value; uncertain = false
    }
}
private final class ResetManagementFixture: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ history: DeviceManagementTransitionHistory) throws { XCTFail("unexpected Cloud write") }
}
private struct ResetCredentialFixture: CloudInstallationCredentialBackend {
    func read(reference: String) throws -> Data? { nil }
    func references() throws -> Set<String> { [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { fatalError("no insertion") }
}

private final class ResetFaultSwitch: @unchecked Sendable { var enabled = true }

private struct BrokenResetManagementFixture: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { throw DeviceManagementTransitionStoreError.corrupt }
    func save(_ history: DeviceManagementTransitionHistory) throws { fatalError("no writes") }
}
