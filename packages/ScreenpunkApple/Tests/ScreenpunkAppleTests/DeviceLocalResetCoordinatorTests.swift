import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor final class DeviceLocalResetCoordinatorTests: XCTestCase {
    private func fixture() throws -> ResetSessionFixture { try .init() }
    func testBeginSuspendsThenCleansAndCompletionNeverRevivesContext() async throws {
        let f = try fixture(), context = try f.context()
        let coordinator = try f.coordinator()
        try await coordinator.begin(context: context, resetID: UUID())
        XCTAssertEqual(f.actions, ["suspend", "cleanup"])
        guard case .completed = coordinator.state else { return XCTFail("expected completed") }
        XCTAssertThrowsError(try context.validate())
        XCTAssertNotNil(try f.owner.refresh())
    }
    func testFailedSuspensionNeverCleansAndReattachedRetryUsesOriginalActions() async throws {
        let f = try fixture(), context = try f.context()
        var coordinator: DeviceLocalResetCoordinator? = try f.coordinator()
        f.failSuspension = true
        do { try await coordinator!.begin(context: context, resetID: UUID()); XCTFail("expected failure") } catch {}
        XCTAssertEqual(f.actions, ["suspend"])
        coordinator = nil
        f.failSuspension = false
        let replacement = try DeviceLocalResetCoordinator(scope: f.scope, authority: f.owner, suspend: { _ in XCTFail("replacement action") }, cleanup: { _ in XCTFail("replacement action") })
        try await replacement.retry()
        XCTAssertEqual(f.actions, ["suspend", "suspend", "cleanup"])
    }
    func testCancelledIgnoringCallbackRetainsExclusiveDriverUntilReturn() async throws {
        let f = try fixture(), context = try f.context()
        let first = try f.coordinator(), second = try f.coordinator()
        f.holdSuspension = true
        let task = Task { try await first.begin(context: context, resetID: UUID()) }
        while f.continuation == nil { await Task.yield() }
        task.cancel()
        do { try await second.retry(); XCTFail("must remain exclusive") } catch { XCTAssertEqual(error as? DeviceLocalResetCoordinator.Failure, .driverActive) }
        XCTAssertEqual(f.actions, ["suspend"])
        f.holdSuspension = false; f.continuation?.resume(); f.continuation = nil
        do { try await task.value; XCTFail("cancelled") } catch {}
        XCTAssertEqual(f.actions, ["suspend"])
        try await second.retry()
        XCTAssertEqual(f.actions, ["suspend", "suspend", "cleanup"])
    }
    func testPendingUncertaintyRetriesBeforeCleanupAndCompletionUncertaintyDoesNotRepeatCleanup() async throws {
        let f = try fixture(), context = try f.context(), coordinator = try f.coordinator()
        f.reset.failWrite = true
        do { try await coordinator.begin(context: context, resetID: UUID()); XCTFail("intent uncertainty") } catch {}
        XCTAssertTrue(f.actions.isEmpty)
        f.failCompletionWrite = true
        do { try await coordinator.retry(); XCTFail("completion uncertainty") } catch {}
        XCTAssertEqual(f.actions, ["suspend", "cleanup"])
        XCTAssertNil(try f.owner.refresh())
        try await coordinator.retry()
        XCTAssertEqual(f.actions, ["suspend", "cleanup"])
        XCTAssertEqual(f.reset.methods, ["save", "save", "save", "save"])
    }
    func testNewResetIntentRetryUsesBeginMethod() async throws {
        let f = try fixture()
        f.reset.record = try .init(resetID: UUID(), scopeDigest: f.scope.digest, phase: .completed)
        let context = try f.context(), coordinator = try f.coordinator()
        f.reset.failWrite = true
        do { try await coordinator.begin(context: context, resetID: UUID()); XCTFail("expected uncertainty") } catch {}
        try await coordinator.retry()
        XCTAssertEqual(f.reset.methods, ["begin", "begin", "save"])
        XCTAssertEqual(f.actions, ["suspend", "cleanup"])
    }
    func testCleanupFailureRetainsPendingAndRepeatsSuspensionBeforeRetry() async throws {
        let f = try fixture(), context = try f.context(), coordinator = try f.coordinator()
        f.failCleanup = true
        do { try await coordinator.begin(context: context, resetID: UUID()); XCTFail("cleanup failure") } catch {}
        XCTAssertEqual(f.reset.record?.phase, .pending)
        XCTAssertNil(try f.owner.refresh())
        f.failCleanup = false
        try await coordinator.retry()
        XCTAssertEqual(f.actions, ["suspend", "cleanup", "suspend", "cleanup"])
    }
    func testEvidenceChangedDuringSuspensionNeverCleansOrFinishesSession() async throws {
        let f = try fixture(), context = try f.context(), coordinator = try f.coordinator()
        f.holdSuspension = true
        let task = Task { try await coordinator.begin(context: context, resetID: UUID()) }
        while f.continuation == nil { await Task.yield() }
        f.reset.record = try f.reset.record!.completed()
        f.continuation?.resume(); f.continuation = nil
        do { try await task.value; XCTFail("evidence changed") } catch {}
        XCTAssertEqual(f.actions, ["suspend"])
        do { try await coordinator.recover(); XCTFail("not its completion") } catch {}
        XCTAssertEqual(f.actions, ["suspend"])
    }
    func testRestartPendingRecoveryDoesNotCreateIDAndCompletedRecoveryIsNoWork() async throws {
        let pending = try fixture()
        let id = UUID()
        pending.reset.record = try .init(resetID: id, scopeDigest: pending.scope.digest)
        try await pending.coordinator().recover()
        XCTAssertEqual(pending.reset.record?.resetID, id)
        XCTAssertEqual(pending.actions, ["suspend", "cleanup"])
        let completed = try fixture()
        completed.reset.record = try .init(resetID: UUID(), scopeDigest: completed.scope.digest, phase: .completed)
        try await completed.coordinator().recover()
        XCTAssertTrue(completed.actions.isEmpty); XCTAssertTrue(completed.reset.methods.isEmpty)
    }
    func testInvalidRestartEvidenceNeverRunsActions() async throws {
        for mismatch in [false, true] {
            let f = try fixture()
            if mismatch { f.reset.record = try .init(resetID: UUID(), scopeDigest: String(repeating: "b", count: 64)) }
            else { f.reset.corrupt = true }
            do { try await f.coordinator().recover(); XCTFail("blocked") } catch {}
            XCTAssertTrue(f.actions.isEmpty); XCTAssertTrue(f.reset.methods.isEmpty)
        }
    }
    func testCompletedSessionRetiresForFreshAuthorityAndOldHandlesAreTerminal() async throws {
        let f = try fixture(), first = try f.coordinator(), oldContext = try f.context()
        try await first.begin(context: oldContext, resetID: UUID())
        let freshOwner = DeviceManagementAuthority(journal: SessionManagementEvidence(), credentials: .init(backend: SessionCredentialEvidence(), random: { Data() }), reset: f.reset)
        let freshContext = DeviceManagementContext(authority: freshOwner, lease: try XCTUnwrap(freshOwner.refresh()))
        var freshActions: [String] = []
        let second = try DeviceLocalResetCoordinator(scope: f.scope, authority: freshOwner, suspend: { _ in freshActions.append("suspend") }, cleanup: { _ in freshActions.append("cleanup") })
        do { try await first.begin(context: freshContext, resetID: UUID()); XCTFail("old handle") } catch { XCTAssertEqual(error as? DeviceLocalResetCoordinator.Failure, .invalidOperation) }
        do { try await first.recover(); XCTFail("old recovery") } catch { XCTAssertEqual(error as? DeviceLocalResetCoordinator.Failure, .invalidOperation) }
        try await second.begin(context: freshContext, resetID: UUID())
        XCTAssertEqual(freshActions, ["suspend", "cleanup"])
        XCTAssertEqual(f.actions, ["suspend", "cleanup"])
        XCTAssertThrowsError(try freshContext.validate())
        guard case .completed = second.state else { return XCTFail("second completion") }
    }
    func testCleanupRootCannotOverlapAnotherSessionsProtectedManagementRoot() throws {
        let f = try fixture(); _ = try f.coordinator()
        let conflicting = try DeviceLocalResetScope(deviceRoot: f.scope.managementDirectory, preferencesRoot: f.base.appendingPathComponent("otherPreferences"), managementDirectory: f.base.appendingPathComponent("otherManagement"), resetDirectory: f.base.appendingPathComponent("otherReset"), credentialItems: [])
        let matchingOwner = DeviceManagementAuthority(journal: SessionManagementEvidence(), credentials: .init(backend: SessionCredentialEvidence(), random: { Data() }), reset: SessionResetEvidence(digest: conflicting.digest))
        XCTAssertThrowsError(try DeviceLocalResetCoordinator(scope: conflicting, authority: matchingOwner, suspend: { _ in }, cleanup: { _ in })) { XCTAssertEqual($0 as? DeviceLocalResetCoordinator.Failure, .configurationConflict) }
    }
    func testOverlappingOrDifferentlyConfiguredCoordinatorRejected() throws {
        let f = try fixture(); _ = try f.coordinator()
        let altered = try DeviceLocalResetScope(deviceRoot: f.scope.deviceRoot, preferencesRoot: f.scope.preferencesRoot, managementDirectory: f.base.appendingPathComponent("management"), resetDirectory: f.scope.resetDirectory, credentialItems: [.init(service: GenericConnectionDeviceVault.storageService, account: GenericConnectionDeviceVault.storageKey)])
        let alteredOwner = DeviceManagementAuthority(journal: SessionManagementEvidence(), credentials: .init(backend: SessionCredentialEvidence(), random: { Data() }), reset: SessionResetEvidence(digest: altered.digest))
        XCTAssertThrowsError(try DeviceLocalResetCoordinator(scope: altered, authority: alteredOwner, suspend: { _ in }, cleanup: { _ in }))
        let overlap = try DeviceLocalResetScope(deviceRoot: f.scope.deviceRoot.appendingPathComponent("child"), preferencesRoot: f.base.appendingPathComponent("otherPreferences"), managementDirectory: f.base.appendingPathComponent("otherManagement"), resetDirectory: f.base.appendingPathComponent("otherReset"), credentialItems: [])
        let overlapOwner = DeviceManagementAuthority(journal: SessionManagementEvidence(), credentials: .init(backend: SessionCredentialEvidence(), random: { Data() }), reset: SessionResetEvidence(digest: overlap.digest))
        XCTAssertThrowsError(try DeviceLocalResetCoordinator(scope: overlap, authority: overlapOwner, suspend: { _ in }, cleanup: { _ in }))
    }
}
@MainActor private final class ResetSessionFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let scope: DeviceLocalResetScope
    let reset: SessionResetEvidence
    let owner: DeviceManagementAuthority
    var actions: [String] = []
    var failSuspension = false
    var failCleanup = false
    var failCompletionWrite = false
    var holdSuspension = false
    var continuation: CheckedContinuation<Void, Never>?
    init() throws {
        scope = try .init(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("preferences"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: base.appendingPathComponent("reset"), credentialItems: [])
        reset = SessionResetEvidence(digest: scope.digest)
        owner = .init(journal: SessionManagementEvidence(), credentials: .init(backend: SessionCredentialEvidence(), random: { Data() }), reset: reset)
    }
    func context() throws -> DeviceManagementContext { .init(authority: owner, lease: try XCTUnwrap(owner.refresh())) }
    func coordinator() throws -> DeviceLocalResetCoordinator {
        try .init(scope: scope, authority: owner, suspend: { [self] _ in
            actions.append("suspend")
            if holdSuspension { await withCheckedContinuation { continuation = $0 } }
            if failSuspension { throw DeviceManagementAuthority.Failure.resetConflict }
        }, cleanup: { [self] _ in actions.append("cleanup"); if failCleanup { throw DeviceManagementAuthority.Failure.resetConflict }; if failCompletionWrite { failCompletionWrite = false; reset.failWrite = true } })
    }
}
private final class SessionResetEvidence: DeviceLocalResetEvidence {
    let scopeDigest: String
    var record: DeviceLocalResetRecord?
    var corrupt = false
    var failWrite = false
    var uncertain = false
    var methods: [String] = []
    init(digest: String) { scopeDigest = digest }
    func load() throws -> DeviceLocalResetRecord? { if corrupt || uncertain { throw DeviceLocalResetStoreError.writeOutcomeUncertain }; return record }
    func save(_ record: DeviceLocalResetRecord) throws { try write(record, method: "save") }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { try write(record, method: "begin") }
    private func write(_ value: DeviceLocalResetRecord, method: String) throws {
        methods.append(method); record = value
        if failWrite { failWrite = false; uncertain = true; throw DeviceLocalResetStoreError.writeOutcomeUncertain }
        uncertain = false
    }
}
private struct SessionManagementEvidence: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ history: DeviceManagementTransitionHistory) throws { fatalError("no Cloud writes") }
}
private struct SessionCredentialEvidence: CloudInstallationCredentialBackend {
    func read(reference: String) throws -> Data? { nil }
    func references() throws -> Set<String> { [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { fatalError("no key writes") }
}
