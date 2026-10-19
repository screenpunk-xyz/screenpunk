import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor final class DeviceLocalResetCleanupTests: XCTestCase {
    func testExplicitV2RetainsSentinelsAndDeletesOnlyFivePairs() async throws {
        let f = try Fixture()
        for path in ["device/content", "preferences/preferences-v1.json", "preferences/unknown.tmp", "management/evidence", "reset/sentinel"] {
            let url = f.base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("sentinel".utf8).write(to: url)
        }
        let context = try f.context()
        let coordinator = try f.coordinator { try f.adapter.execute($0) }
        try await coordinator.begin(context: context, resetID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("device/content").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("preferences/preferences-v1.json").path))
        for path in ["preferences/unknown.tmp", "management/evidence", "reset/sentinel"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(path).path))
        }
        XCTAssertEqual(Set(f.keys.deleted), Set(DeviceLocalResetScope.allowedCredentialItems))
        XCTAssertEqual(f.keys.remaining, [f.keys.protected, f.keys.unrelatedAccount])
    }
    func testExplicitV3DeletesReservedPendingOnlyAndV2RetainsIt() async throws {
        for v3 in [false, true] {
            let f = try Fixture(v3: v3)
            let root = f.scope.authorityScope.preferencesRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in [ScreenPreferenceAtomicWriter.archiveName, ScreenPreferenceAtomicWriter.pendingName, ScreenPreferenceAtomicWriter.lockName, "unknown-history.tmp"] {
                try Data("sentinel".utf8).write(to: root.appendingPathComponent(name))
            }
            let coordinator = try f.coordinator { try f.adapter.execute($0) }
            try await coordinator.begin(context: f.context(), resetID: UUID())
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ScreenPreferenceAtomicWriter.archiveName).path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent(ScreenPreferenceAtomicWriter.pendingName).path), !v3)
            for name in [ScreenPreferenceAtomicWriter.lockName, "unknown-history.tmp"] {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name)), "sentinel")
            }
        }
    }
    func testV3RejectsPendingAndCompletedV2RecordsWithoutMigration() async throws {
        for phase in [DeviceLocalResetPhase.pending, .completed] {
            let f = try Fixture(v3: true)
            let v2 = try DeviceLocalResetCleanupScope(base: f.v1, anchor: f.base)
            XCTAssertNotEqual(v2.authorityScope.digest, f.scope.authorityScope.digest)
            f.reset.record = try .init(resetID: UUID(), scopeDigest: v2.authorityScope.digest, phase: phase)
            let coordinator = try f.coordinator { _ in XCTFail("cleanup") }
            do { try await coordinator.recover(); XCTFail("v2 migration forbidden") } catch {}
            XCTAssertTrue(f.keys.deleted.isEmpty)
            XCTAssertEqual(f.reset.record?.scopeDigest, v2.authorityScope.digest)
        }
    }
    func testEscapedPermitAndWrongScopeCannotAuthorize() async throws {
        let f = try Fixture(); var escaped: DeviceLocalResetCleanupPermit?
        let coordinator = try f.coordinator { permit in
            escaped = permit
            XCTAssertThrowsError(try permit.withStep(scopeDigest: f.v1.digest) { XCTFail("wrong digest executed") })
        }
        try await coordinator.begin(context: f.context(), resetID: UUID())
        XCTAssertThrowsError(try XCTUnwrap(escaped).withStep(scopeDigest: f.scope.authorityScope.digest) { XCTFail("expired executed") })
    }
    func testFailedSuspensionNeverMintsQualifiedPermit() async throws {
        let f = try Fixture()
        let coordinator = try DeviceLocalResetCoordinator(scope: f.scope.authorityScope, authority: f.owner,
            suspend: { _ in throw DeviceLocalResetStoreError.writeOutcomeUncertain },
            qualifiedCleanup: { _ in XCTFail("permit minted after failed suspension") })
        do { try await coordinator.begin(context: f.context(), resetID: UUID()); XCTFail("suspension failed") } catch {}
        XCTAssertTrue(f.keys.deleted.isEmpty)
        XCTAssertEqual(f.reset.record?.phase, .pending)
    }
    func testAsyncSessionCannotBeUpgradedToMintPermit() throws {
        let f = try Fixture()
        _ = try DeviceLocalResetCoordinator(scope: f.scope.authorityScope, authority: f.owner, suspend: { _ in }, cleanup: { _ in })
        XCTAssertThrowsError(try f.coordinator { _ in XCTFail("minted") })
    }
    func testChangedPendingRejectsNextDeleteAndLeavesNoCompletion() async throws {
        let f = try Fixture()
        f.keys.afterDelete = { f.reset.record = try! .init(resetID: UUID(), scopeDigest: f.scope.authorityScope.digest) }
        let coordinator = try f.coordinator { try f.adapter.execute($0) }
        do { try await coordinator.begin(context: f.context(), resetID: UUID()); XCTFail("changed pending") } catch {}
        XCTAssertEqual(f.keys.deleted.count, 1)
        XCTAssertEqual(f.reset.record?.phase, .pending)
    }
    func testAbsenceReadFailureAfterDeleteKeepsPendingAndRetryIsIdempotent() async throws {
        let f = try Fixture(); f.keys.failAbsence = true
        let coordinator = try f.coordinator { try f.adapter.execute($0) }
        do { try await coordinator.begin(context: f.context(), resetID: UUID()); XCTFail("read failure") } catch {}
        let id = f.reset.record?.resetID
        XCTAssertEqual(f.reset.record?.phase, .pending)
        try await coordinator.retry()
        XCTAssertEqual(f.reset.record?.resetID, id)
        XCTAssertEqual(f.reset.record?.phase, .completed)
        XCTAssertEqual(f.keys.deleted.count, 6)
    }
    func testV1PendingAndCompletedCannotBeReinterpreted() async throws {
        for phase in [DeviceLocalResetPhase.pending, .completed] {
            let f = try Fixture()
            f.reset.record = try .init(resetID: UUID(), scopeDigest: f.v1.digest, phase: phase)
            let coordinator = try f.coordinator { _ in XCTFail("cleanup") }
            do { try await coordinator.recover(); XCTFail("v1 mismatch") } catch {}
            XCTAssertTrue(f.keys.deleted.isEmpty)
            XCTAssertEqual(f.reset.record?.scopeDigest, f.v1.digest)
        }
    }
    func testCanonicalMetadataBindsModesNamesAndLimits() throws {
        let f = try Fixture()
        let named = try DeviceLocalFilesystemCleanupPlan(anchor: f.scope.plan.anchor, roots: [.init(directory: f.v1.deviceRoot, mode: .namedFiles(["x"]))], protectedRoots: [f.v1.managementDirectory, f.v1.resetDirectory])
        let other = try DeviceLocalFilesystemCleanupPlan(anchor: f.scope.plan.anchor, roots: [.init(directory: f.v1.deviceRoot, mode: .namedFiles(["y"]))], protectedRoots: [f.v1.managementDirectory, f.v1.resetDirectory])
        XCTAssertNotEqual(try DeviceLocalResetScope(v2: f.v1, cleanupMetadata: named.canonicalMetadata).digest, try DeviceLocalResetScope(v2: f.v1, cleanupMetadata: other.canonicalMetadata).digest)
        let directory = try DeviceLocalFilesystemCleanupPlan(anchor: f.scope.plan.anchor, roots: [.init(directory: f.v1.deviceRoot, mode: .directoryContents)], protectedRoots: [f.v1.managementDirectory, f.v1.resetDirectory])
        XCTAssertNotEqual(try DeviceLocalResetScope(v2: f.v1, cleanupMetadata: named.canonicalMetadata).digest, try DeviceLocalResetScope(v2: f.v1, cleanupMetadata: directory.canonicalMetadata).digest)
        XCTAssertNotEqual(f.v1.digest, f.scope.authorityScope.digest)
        XCTAssertNotEqual(f.scope.authorityScope.digest, try DeviceLocalResetCleanupScope(base: f.v1, anchor: f.base, maximumDepth: 31).authorityScope.digest)
    }
}
@MainActor private final class Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let v1: DeviceLocalResetScope
    let scope: DeviceLocalResetCleanupScope
    let reset: Evidence
    let owner: DeviceManagementAuthority
    let keys = Keys()
    var adapter: DeviceLocalResetCleanup { .init(scope: scope, credentials: keys) }
    deinit { try? FileManager.default.removeItem(at: base) }
    init(v3: Bool = false) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        v1 = try .init(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("preferences"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: base.appendingPathComponent("reset"), credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        scope = try v3 ? .init(v3: v1, anchor: base) : .init(base: v1, anchor: base)
        reset = Evidence(scope.authorityScope.digest)
        owner = .init(journal: Journal(), credentials: .init(backend: Credentials(), random: { Data() }), reset: reset)
    }
    func context() throws -> DeviceManagementContext { .init(authority: owner, lease: try XCTUnwrap(owner.refresh())) }
    func coordinator(_ action: @escaping (DeviceLocalResetCleanupPermit) throws -> Void) throws -> DeviceLocalResetCoordinator { try .init(scope: scope.authorityScope, authority: owner, suspend: { _ in }, qualifiedCleanup: action) }
}
private final class Keys: DeviceLocalResetCredentialCleanup {
    let protected = DeviceLocalResetScope.CredentialItem(service: CloudInstallationCredentialStore.service, account: "retained")
    let unrelatedAccount = DeviceLocalResetScope.CredentialItem(service: "xyz.screenpunk.google-calendar", account: "unrelated")
    var remaining: Set<DeviceLocalResetScope.CredentialItem>
    var deleted: [DeviceLocalResetScope.CredentialItem] = []
    var failAbsence = false
    var afterDelete: (() -> Void)?
    init() { remaining = Set(DeviceLocalResetScope.allowedCredentialItems + [protected, unrelatedAccount]) }
    func delete(_ item: DeviceLocalResetScope.CredentialItem) throws { deleted.append(item); remaining.remove(item); afterDelete?() }
    func isAbsent(_ item: DeviceLocalResetScope.CredentialItem) throws -> Bool { if failAbsence { failAbsence = false; throw DeviceLocalResetStoreError.writeOutcomeUncertain }; return !remaining.contains(item) }
}
private final class Evidence: DeviceLocalResetEvidence {
    let scopeDigest: String; var record: DeviceLocalResetRecord?
    init(_ digest: String) { scopeDigest = digest }
    func load() throws -> DeviceLocalResetRecord? { record }
    func save(_ record: DeviceLocalResetRecord) throws { self.record = record }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { self.record = record }
}
private struct Journal: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ history: DeviceManagementTransitionHistory) throws { fatalError() }
}
private struct Credentials: CloudInstallationCredentialBackend {
    func read(reference: String) throws -> Data? { nil }
    func references() throws -> Set<String> { [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { fatalError() }
}
