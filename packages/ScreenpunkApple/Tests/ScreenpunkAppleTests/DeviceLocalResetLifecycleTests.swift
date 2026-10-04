import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor final class DeviceLocalResetLifecycleTests: XCTestCase {
    func testBootstrapRejectsMismatchedLifecycleAuthorityWithoutPublishingOrHost() throws {
        let expected = try LifecycleFixture(), replacement = try LifecycleFixture()
        var factories = 0, hosts = 0, retained = 0
        let bootstrap = DeviceManagementBootstrap(authority: expected.lifecycle.authority, lifecycleFactory: { factories += 1; return replacement.lifecycle }, retained: { retained += 1; return .empty }, hostFactory: { _ in hosts += 1; throw LifecycleFailure.injected })
        bootstrap.start()
        guard case .blocked(let snapshot) = bootstrap.state else { return XCTFail("mismatched owner must block") }
        XCTAssertTrue(snapshot.screens.isEmpty)
        XCTAssertEqual(factories, 1); XCTAssertEqual(hosts, 0); XCTAssertEqual(retained, 0)
        XCTAssertEqual(expected.keys.deletes, 0); XCTAssertEqual(replacement.keys.deletes, 0)
    }

    func testManagedAppearingAfterAdmissionBlocksCachedHostAndReset() async throws {
        let f = try LifecycleFixture(); var hosts = 0, retained = 0
        let bootstrap = DeviceManagementBootstrap(lifecycle: f.lifecycle, retained: { retained += 1; return .empty }, hostFactory: { hosts += 1; return try f.host($0) })
        bootstrap.start(); await settle(bootstrap)
        guard case .localReady(let host) = bootstrap.state else { return XCTFail("legacy admission") }
        try FileManager.default.createDirectory(at: f.base.appendingPathComponent("xyz.screenpunk.native-managed"), withIntermediateDirectories: false)
        bootstrap.start()
        guard case .blocked = bootstrap.state else { return XCTFail("cached host must not bypass managed fence") }
        XCTAssertTrue(host.lifetime.isRetired); XCTAssertEqual(hosts, 1); XCTAssertEqual(retained, 0)
        do { try await f.lifecycle.recover(progress: {}); XCTFail("managed reset must not recover") } catch {}
        XCTAssertEqual(f.keys.deletes, 0); XCTAssertNil(f.evidence.record)
    }
    func testNamespaceAppearingBetweenPreflightAndLifecycleConstructionRejectsDomains() throws {
        let f = try LifecycleFixture()
        try f.lifecycle.authority.requireLegacyNamespaceAbsent()
        try FileManager.default.createDirectory(at: f.base.appendingPathComponent("xyz.screenpunk.native-managed"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try DeviceLocalResetLifecycle(scope: f.scope, authorityFactory: { f.lifecycle.authority }, provider: f.provider, cleanup: .init(scope: f.scope, credentials: f.keys)))
        XCTAssertEqual(f.keys.deletes, 0); XCTAssertNil(f.evidence.record)
    }

    func testLegacyCloudEvidenceBlocksFreshAndPendingCleanupAndRetry() async throws {
        for pending in [false, true] {
            for kind in ["valid", "invalid", "symlink", "dangling-symlink"] {
                let f = try LifecycleFixture()
                let root = f.scope.authorityScope.deviceRoot
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let content = root.appendingPathComponent("screen-sentinel")
                try Data("retained".utf8).write(to: content)
                let legacy = root.appendingPathComponent("native-workspace-setup.json")
                if kind.contains("symlink") {
                    try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: kind == "symlink" ? f.sentinel : root.appendingPathComponent("missing-target"))
                } else {
                    // Reset must not decode either valid-looking or malformed evidence.
                    try Data((kind == "valid" ? "{\"userID\":\"\(UUID().uuidString)\",\"request\":{\"requestId\":\"\(UUID().uuidString)\",\"workspaceName\":\"Workspace\",\"locationName\":\"Room\"}}" : "invalid").utf8).write(to: legacy)
                }
                let originalLink = kind.contains("symlink") ? try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) : nil
                let originalBytes = originalLink == nil ? try Data(contentsOf: legacy) : nil
                if pending {
                    f.evidence.record = try .init(resetID: UUID(), scopeDigest: f.scope.authorityScope.digest)
                    do { try await f.lifecycle.recover(progress: {}); XCTFail("blocked") } catch {}
                } else {
                    let context = try f.context()
                    do { try await f.lifecycle.begin(context: context, resetID: UUID(), progress: {}); XCTFail("blocked") } catch {}
                }
                do { try await f.lifecycle.recover(progress: {}); XCTFail("retry blocked") } catch {}
                XCTAssertEqual(f.keys.deletes, 0)
                XCTAssertEqual(f.evidence.record?.phase, .pending)
                XCTAssertEqual(try String(contentsOf: content), "retained")
                XCTAssertEqual(try String(contentsOf: f.sentinel), "protected")
                if let originalLink {
                    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path), originalLink)
                } else { XCTAssertEqual(try Data(contentsOf: legacy), originalBytes) }
            }
        }
    }
    func testLegacyCloudGuardRejectsAmbiguousLookupAndAncestorLinks() throws {
        let f = try LifecycleFixture(), root = f.scope.authorityScope.deviceRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNoThrow(try DeviceLocalResetLegacyCloudGuard.requireAbsent(deviceRoot: root))
        XCTAssertThrowsError(try DeviceLocalResetLegacyCloudGuard.inspect(deviceRoot: root, beforeLookup: { throw DeviceLocalResetLegacyCloudGuard.Failure.lookup(EACCES) }))
        let link = f.base.appendingPathComponent("linked-device")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try DeviceLocalResetLegacyCloudGuard.requireAbsent(deviceRoot: link))
        XCTAssertNoThrow(try DeviceLocalResetLegacyCloudGuard.requireAbsent(deviceRoot: root.deletingLastPathComponent().appendingPathComponent("absent-device")))
    }
    func testLegacyCloudGuardRejectsActualInaccessibleDirectory() throws {
        let f = try LifecycleFixture(), root = f.scope.authorityScope.deviceRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try DeviceLocalResetLegacyCloudGuard.requireAbsent(deviceRoot: root))
    }
    func testRepeatedResetReplacesDomainsAndRetainsExcludedFiles() async throws {
        let f = try LifecycleFixture()
        let old = f.provider.preferences
        for cycle in 0..<2 {
            try f.lifecycle.prepareNextReset()
            let context = try f.context()
            let id = UUID()
            try await f.lifecycle.begin(context: context, resetID: id, progress: {})
            XCTAssertEqual(f.evidence.record?.resetID, id)
            XCTAssertEqual(f.evidence.record?.phase, .completed)
            XCTAssertEqual(f.keys.deletes, (cycle + 1) * 5)
            XCTAssertNoThrow(try f.provider.preferences.generation())
            XCTAssertNoThrow(try f.provider.calendar.snapshot())
        }
        XCTAssertThrowsError(try old.generation())
        XCTAssertEqual(try String(contentsOf: f.sentinel), "protected")
    }
    func testUncertainIntentBlocksWritersWithoutCleanupThenExactRetry() async throws {
        let f = try LifecycleFixture(); f.evidence.failPhase = .pending
        let id = UUID(), context = try f.context()
        do { try await f.lifecycle.begin(context: context, resetID: id, progress: {}); XCTFail("uncertainty") } catch {}
        XCTAssertEqual(f.keys.deletes, 0)
        XCTAssertThrowsError(try f.provider.preferences.generation())
        XCTAssertThrowsError(try f.provider.calendar.snapshot())
        try await f.lifecycle.recover(progress: {})
        XCTAssertEqual(f.evidence.record?.resetID, id)
        XCTAssertEqual(f.evidence.record?.phase, .completed)
        XCTAssertNoThrow(try f.provider.preferences.generation())
    }
    func testCompletionUncertaintyAndCancellationDoNotRepeatCleanup() async throws {
        for cancelled in [false, true] {
            let f = try LifecycleFixture(), context = try f.context()
            if cancelled { f.evidence.onCompletion = { withUnsafeCurrentTask { $0?.cancel() } } }
            else { f.evidence.failPhase = .completed }
            let task = Task { try await f.lifecycle.begin(context: context, resetID: UUID(), progress: {}) }
            do { try await task.value; XCTFail("completion blocked") } catch {}
            XCTAssertEqual(f.keys.deletes, 5)
            XCTAssertThrowsError(try f.provider.preferences.generation())
            f.evidence.onCompletion = nil
            try await f.lifecycle.recover(progress: {})
            XCTAssertEqual(f.keys.deletes, 5)
            XCTAssertNoThrow(try f.provider.preferences.generation())
        }
    }
    func testOldScopeMismatchIsEmptyBlockedWithoutHostOrRetainedRead() async throws {
        let f = try LifecycleFixture()
        f.evidence.record = try .init(resetID: UUID(), scopeDigest: String(repeating: "a", count: 64))
        var retained = 0, hosts = 0
        let boot = DeviceManagementBootstrap(lifecycle: f.lifecycle, retained: { retained += 1; return .empty }, hostFactory: { _ in hosts += 1; throw LifecycleFailure.injected })
        boot.start(); boot.retry(); await settle(boot)
        guard case .blocked(let snapshot) = boot.state else { return XCTFail("blocked") }
        XCTAssertTrue(snapshot.screens.isEmpty); XCTAssertEqual(retained, 0); XCTAssertEqual(hosts, 0)
        XCTAssertEqual(f.keys.deletes, 0)
    }
    func testPendingRecoveryPrecedesHostAndHostFailureRetriesOnlyConstruction() async throws {
        let f = try LifecycleFixture()
        f.evidence.record = try .init(resetID: UUID(), scopeDigest: f.scope.authorityScope.digest)
        var hosts = 0, retained = 0
        let boot = DeviceManagementBootstrap(lifecycle: f.lifecycle, retained: { retained += 1; return .empty }, hostFactory: { context in
            hosts += 1
            XCTAssertEqual(f.evidence.record?.phase, .completed)
            if hosts == 1 { throw LifecycleFailure.injected }
            return try f.host(context)
        })
        boot.start(); await settle(boot)
        guard case .blocked = boot.state else { return XCTFail("host failed") }
        XCTAssertEqual(retained, 0); XCTAssertEqual(f.keys.deletes, 5)
        boot.retry(); await settle(boot)
        guard case .localReady(let host) = boot.state else { return XCTFail("fresh host") }
        XCTAssertFalse(host.lifetime.isRetired); XCTAssertEqual(hosts, 2); XCTAssertEqual(f.keys.deletes, 5)
    }
    func testSharedOwnerReusesAdmissionWithoutRevokingFirstLease() async throws {
        let f = try LifecycleFixture(); var hosts = 0
        func bootstrap() -> DeviceManagementBootstrap { .init(lifecycle: f.lifecycle, retained: { .empty }, hostFactory: { hosts += 1; return try f.host($0) }) }
        let first = bootstrap(); first.start(); await settle(first)
        let second = bootstrap(); second.start(); await settle(second)
        guard case .localReady(let a) = first.state, case .localReady(let b) = second.state else { return XCTFail("admission") }
        XCTAssertTrue(a === b); XCTAssertEqual(hosts, 1)
        XCTAssertNoThrow(try a.saveSettings(.init(expectedRevision: a.settingsSnapshot?.revision ?? "", value: .init(displayName: "still admitted"))))
    }
    func testRejectedResetRetiresOldHostAndCanAdmitReplacement() async throws {
        let f = try LifecycleFixture()
        let boot = DeviceManagementBootstrap(lifecycle: f.lifecycle, retained: { .empty }, hostFactory: { try f.host($0) })
        boot.start(); await settle(boot)
        guard case .localReady(let old) = boot.state else { return XCTFail("admitted") }
        _ = try f.lifecycle.authority.refresh() // invalidates captured UI admission
        boot.requestLocalReset(); await settle(boot)
        XCTAssertTrue(old.lifetime.isRetired); XCTAssertNil(f.evidence.record); XCTAssertEqual(f.keys.deletes, 0)
        boot.retry(); await settle(boot)
        guard case .localReady(let new) = boot.state else { return XCTFail("readmission") }
        XCTAssertFalse(new === old); XCTAssertFalse(new.lifetime.isRetired)
    }
    func testConfigurationFailureRetriesConstructionWithoutRetainedRead() async throws {
        let f = try LifecycleFixture(); var configurations = 0, loads = 0
        let boot = DeviceManagementBootstrap(authority: f.lifecycle.authority, lifecycleFactory: {
            configurations += 1
            if configurations == 1 { throw LifecycleFailure.injected }
            return f.lifecycle
        }, retained: { loads += 1; return .empty }, hostFactory: { try f.host($0) })
        boot.start(); guard case .blocked = boot.state else { return XCTFail("configuration") }
        XCTAssertEqual(loads, 0)
        boot.retry(); await settle(boot)
        guard case .localReady = boot.state else { return XCTFail("retry") }
        XCTAssertEqual(configurations, 2)
    }
    func testUnknownEvidenceFenceCannotAdmitAbsentOrFreshCompletedOnRetry() async throws {
        for completed in [false, true] {
            let f = try LifecycleFixture(); f.evidence.readFailed = true
            var hosts = 0, retained = 0
            let boot = DeviceManagementBootstrap(lifecycle: f.lifecycle, retained: { retained += 1; return .empty }, hostFactory: { hosts += 1; return try f.host($0) })
            boot.start(); await settle(boot)
            f.evidence.readFailed = false
            if completed { f.evidence.record = try .init(resetID: UUID(), scopeDigest: f.scope.authorityScope.digest, phase: .completed) }
            boot.retry(); await settle(boot)
            guard case .blocked = boot.state else { return XCTFail("unproved reopening") }
            XCTAssertEqual(hosts, 0); XCTAssertEqual(retained, 0); XCTAssertEqual(f.keys.deletes, 0)
            XCTAssertThrowsError(try f.provider.preferences.generation())
            XCTAssertThrowsError(try f.provider.calendar.snapshot())
        }
    }
    func testSecondBootstrapAfterCompletedResetReusesFreshHost() async throws {
        let f = try LifecycleFixture(); var hosts = 0
        func bootstrap() -> DeviceManagementBootstrap { .init(lifecycle: f.lifecycle, retained: { .empty }, hostFactory: { hosts += 1; return try f.host($0) }) }
        let first = bootstrap(); first.start(); await settle(first)
        first.requestLocalReset(); await settle(first)
        guard case .localReady(let fresh) = first.state else { return XCTFail("replacement") }
        let authority = f.lifecycle.authority
        let second = bootstrap(); second.start(); await settle(second)
        guard case .localReady(let shared) = second.state else { return XCTFail("shared replacement") }
        XCTAssertTrue(fresh === shared); XCTAssertTrue(f.lifecycle.authority === authority)
        XCTAssertEqual(hosts, 2); XCTAssertEqual(f.keys.deletes, 5)
        XCTAssertNoThrow(try fresh.saveSettings(.init(expectedRevision: fresh.settingsSnapshot?.revision ?? "", value: .init(displayName: "fresh"))))
    }
    private func settle(_ boot: DeviceManagementBootstrap) async {
        for _ in 0..<200 { await Task.yield() }
    }
}
private enum LifecycleFailure: Error { case injected }
@MainActor private final class LifecycleFixture {
    let base = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    let scope: DeviceLocalResetCleanupScope
    let evidence: LifecycleEvidence
    let keys = LifecycleKeys()
    let provider: DeviceLocalResetWriterProvider
    let lifecycle: DeviceLocalResetLifecycle
    var sentinel: URL { scope.authorityScope.managementDirectory.appendingPathComponent("sentinel") }
    init() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let original = try DeviceLocalResetScope(deviceRoot: base.appendingPathComponent("device"), preferencesRoot: base.appendingPathComponent("preferences"), managementDirectory: base.appendingPathComponent("management"), resetDirectory: base.appendingPathComponent("reset"), credentialItems: DeviceLocalResetScope.allowedCredentialItems)
        scope = try .init(v3: original, anchor: base)
        evidence = .init(scope.authorityScope.digest)
        provider = try .init(calendar: .init(store: MemoryCredentialStore(), suspension: GoogleCalendarSuspensionDomain()), preferences: .init(root: original.preferencesRoot))
        let reset = evidence
        let managed = try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: base)
        lifecycle = try .init(scope: scope, authorityFactory: { .init(journal: LifecycleJournal(), credentials: .init(backend: LifecycleCredentials(), random: { Data() }), reset: reset, managedNamespace: managed) }, provider: provider, cleanup: .init(scope: scope, credentials: keys))
        _ = try provider.preferences.generation()
        try FileManager.default.createDirectory(at: original.managementDirectory, withIntermediateDirectories: true)
        try Data("protected".utf8).write(to: original.managementDirectory.appendingPathComponent("sentinel"))
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    func context() throws -> DeviceManagementContext { .init(authority: lifecycle.authority, lease: try XCTUnwrap(lifecycle.authority.refresh())) }
    func host(_ context: DeviceManagementContext) throws -> DeviceLANHost {
        let identity = try TLSIdentity.make(role: .device, commonName: "lifecycle-test-\(UUID().uuidString)")
        return try .init(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context, store: .init(root: scope.authorityScope.deviceRoot), identityProvider: { identity }, homeAssistantVault: .init(store: MemoryCredentialStore()), genericConnectionVault: .init(store: MemoryCredentialStore()))
    }
}
private final class LifecycleEvidence: DeviceLocalResetEvidence {
    let scopeDigest: String
    var record: DeviceLocalResetRecord?
    var uncertain = false
    var readFailed = false
    var failPhase: DeviceLocalResetPhase?
    var onCompletion: (() -> Void)?
    init(_ digest: String) { scopeDigest = digest }
    func load() throws -> DeviceLocalResetRecord? { if readFailed { throw LifecycleFailure.injected }; if uncertain { throw DeviceLocalResetStoreError.writeOutcomeUncertain }; return record }
    func save(_ value: DeviceLocalResetRecord) throws {
        record = value; uncertain = false
        if failPhase == value.phase { failPhase = nil; uncertain = true; throw DeviceLocalResetStoreError.writeOutcomeUncertain }
        if value.phase == .completed { onCompletion?() }
    }
    func beginNewReset(_ value: DeviceLocalResetRecord) throws { try save(value) }
}
private final class LifecycleKeys: DeviceLocalResetCredentialCleanup {
    var deletes = 0
    func delete(_ item: DeviceLocalResetScope.CredentialItem) throws { deletes += 1 }
    func isAbsent(_ item: DeviceLocalResetScope.CredentialItem) throws -> Bool { true }
}
private struct LifecycleJournal: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ value: DeviceManagementTransitionHistory) throws { throw LifecycleFailure.injected }
}
private struct LifecycleCredentials: CloudInstallationCredentialBackend {
    func references() throws -> Set<String> { [] }
    func read(reference: String) throws -> Data? { nil }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { throw LifecycleFailure.injected }
}
