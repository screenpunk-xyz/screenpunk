import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor
final class DeviceManagementBootstrapTests: XCTestCase {
    func testPreparedOwnerSetupFailureRetainsOwnerAndRetriesBeforeDeferredConstruction() throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let anchor = parent.appendingPathComponent("Application Support")
        // Configure the real inspector, then reproduce a missing final anchor
        // before its first observation. No production locator is consulted.
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        let inspector = try DeviceManagedNamespaceInspector.fixture(existingPhysicalAnchor: anchor)
        try FileManager.default.removeItem(at: anchor)
        var failed = false, creations = 0, parentSyncs = 0
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: parent, boundary: { boundary in
            if boundary == .afterCreate { creations += 1 }
            if boundary == .afterParentSync {
                parentSyncs += 1
                if !failed { failed = true; throw BootstrapError.factory }
            }
        })
        let owner = DeviceManagementAuthority(journal: BootstrapJournal(), credentials: .init(backend: BootstrapBackend(), random: { XCTFail("no keys"); return Data() }), reset: ManagementTestResetEvidence(), managedNamespace: inspector, supportAnchorSetup: setup)
        var preparations = 0, constructions = 0, hosts = 0, retained = 0
        let bootstrap = DeviceManagementBootstrap(preparationFactory: {
            preparations += 1
            return .init(authority: owner, constructLifecycle: {
                constructions += 1
                XCTAssertTrue(setup.allowsNamespaceInspection)
                try owner.requireLegacyNamespaceAbsent()
                throw BootstrapError.factory
            })
        }, retained: { retained += 1; return .empty }, hostFactory: { _ in hosts += 1; throw BootstrapError.factory })
        bootstrap.start()
        XCTAssertEqual(preparations, 1); XCTAssertEqual(constructions, 0)
        XCTAssertEqual(hosts, 0); XCTAssertEqual(retained, 0); XCTAssertNil(try owner.refresh())
        bootstrap.retry()
        XCTAssertEqual(preparations, 1); XCTAssertEqual(constructions, 1)
        XCTAssertEqual(creations, 1); XCTAssertEqual(parentSyncs, 2)
        XCTAssertEqual(hosts, 0); XCTAssertEqual(retained, 0)
        XCTAssertEqual(try inspector.inspect().classification, .confirmedAbsent)
    }
    func testPreparedOwnerManagedPresenceBlocksDeferredLifecycleAndAllFactories() throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: anchor.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName), withIntermediateDirectories: false)
        var setupEffects = 0, constructions = 0, hosts = 0, retained = 0
        let setup = try DeviceProductionSupportAnchorSetup.fixture(existingPhysicalParent: parent, boundary: { _ in setupEffects += 1 })
        let owner = DeviceManagementAuthority(journal: BootstrapJournal(), credentials: .init(backend: BootstrapBackend(), random: { Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor), supportAnchorSetup: setup)
        let bootstrap = DeviceManagementBootstrap(preparationFactory: { .init(authority: owner, constructLifecycle: { constructions += 1; throw BootstrapError.factory }) }, retained: { retained += 1; return .empty }, hostFactory: { _ in hosts += 1; throw BootstrapError.factory })
        bootstrap.start(); bootstrap.retry()
        XCTAssertEqual(setupEffects, 0); XCTAssertEqual(constructions, 0); XCTAssertEqual(hosts, 0); XCTAssertEqual(retained, 0)
        guard case .blocked(let snapshot) = bootstrap.state else { return XCTFail("managed") }
        XCTAssertTrue(snapshot.screens.isEmpty)
    }

    func testManagedNamespaceBlocksBeforeLifecycleAndRetainedFactories() throws {
        for symlink in [false, true] {
            let anchor = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: anchor) }
            let namespace = anchor.appendingPathComponent("xyz.screenpunk.native-managed")
            if symlink { try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: anchor) }
            else { try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false) }
            let authority = DeviceManagementAuthority(journal: BootstrapJournal(), credentials: .init(backend: BootstrapBackend(), random: { XCTFail("no keys"); return Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor))
            var lifecycleCalls = 0, hostCalls = 0, retainedCalls = 0
            let bootstrap = DeviceManagementBootstrap(authority: authority, lifecycleFactory: { lifecycleCalls += 1; throw BootstrapError.factory }, retained: { retainedCalls += 1; return .empty }, hostFactory: { _ in hostCalls += 1; throw BootstrapError.factory })
            bootstrap.start(); bootstrap.retry()
            XCTAssertEqual(lifecycleCalls, 0); XCTAssertEqual(hostCalls, 0); XCTAssertEqual(retainedCalls, 0)
            guard case .blocked = bootstrap.state else { return XCTFail("managed namespace must block") }
        }
    }

    func testNamespaceAppearingBeforeHostConstructionNeverCallsTLSProvider() throws {
        let anchor = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: anchor) }
        let authority = DeviceManagementAuthority(journal: BootstrapJournal(), credentials: .init(backend: BootstrapBackend(), random: { Data() }), reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor))
        let context = DeviceManagementContext(authority: authority, lease: try XCTUnwrap(authority.refresh()))
        try FileManager.default.createDirectory(at: anchor.appendingPathComponent("xyz.screenpunk.native-managed"), withIntermediateDirectories: false)
        var tlsCalls = 0
        XCTAssertThrowsError(try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context, store: .init(root: anchor.appendingPathComponent("device")), identityProvider: { tlsCalls += 1; throw BootstrapError.factory }))
        XCTAssertEqual(tlsCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: anchor.appendingPathComponent("device").path))
    }

    func testBlockedEvidenceNeverInvokesHostFactory() throws {
        for mode in 0..<5 {
            let journal = BootstrapJournal(), backend = BootstrapBackend()
            if mode == 0 { journal.failed = true }
            if mode == 1 { backend.failed = true }
            if mode == 2 { backend.values["orphan"] = Data(repeating: 1, count: 32) }
            if mode >= 3 {
                journal.value = try .intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate")
                if mode == 4 { backend.values["candidate"] = Data(repeating: 1, count: 32) }
            }
            var creations = 0, retainedLoads = 0
            let bootstrap = DeviceManagementBootstrap(authority: .init(journal: journal, credentials: .init(backend: backend, random: { XCTFail("unexpected generation"); return Data() }), reset: ManagementTestResetEvidence(), managedNamespace: testManagedNamespaceInspector()), retained: { retainedLoads += 1; return .empty }, hostFactory: { _ in creations += 1; throw BootstrapError.factory })
            bootstrap.start(); bootstrap.start()
            XCTAssertEqual(creations, 0); XCTAssertEqual(retainedLoads, 2)
            guard case .blocked = bootstrap.state else { return XCTFail("expected blocked") }
        }
    }
    func testLegacyAndFencedEvidenceAdmitFactory() throws {
        for fenced in [false, true] {
            let journal = BootstrapJournal(), backend = BootstrapBackend()
            if fenced {
                journal.value = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate").fenced()
                backend.values["candidate"] = Data(repeating: 1, count: 32)
            }
            var creations = 0
            let bootstrap = DeviceManagementBootstrap(authority: .init(journal: journal, credentials: .init(backend: backend, random: { Data() }), reset: ManagementTestResetEvidence(), managedNamespace: testManagedNamespaceInspector()), retained: { .empty }, hostFactory: { _ in creations += 1; throw BootstrapError.factory })
            bootstrap.start()
            XCTAssertEqual(creations, 1)
        }
    }
    func testRetryCannotEscapeKnownHistoryQuarantine() throws {
        let journal = BootstrapJournal(), backend = BootstrapBackend()
        journal.value = try .intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate")
        var creations = 0
        let bootstrap = DeviceManagementBootstrap(authority: .init(journal: journal, credentials: .init(backend: backend, random: { Data() }), reset: ManagementTestResetEvidence(), managedNamespace: testManagedNamespaceInspector()), retained: { .empty }, hostFactory: { _ in creations += 1; throw BootstrapError.factory })
        bootstrap.start(); journal.value = nil; bootstrap.start()
        XCTAssertEqual(creations, 0)
    }
    func testValidRetainedLegacyPackageLoadsWithoutChangingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeviceStateStore(root: directory)
        let revision = StoredRevision.offlineFixture
        let staged = try store.stagePackage([(path: "index.html", data: Data("<html>retained</html>".utf8))])
        try store.activatePackage(staged: staged)
        try store.save(.init(owner: nil, activeRevision: revision.revision, activeStoredRevision: revision, lastDeployment: nil))
        let beforeState = try Data(contentsOf: store.stateURL)
        let beforePackage = try store.loadPackageFiles()
        let snapshot = DeviceRetainedContentSnapshot.load(store: store)
        XCTAssertEqual(snapshot.screens.count, 1)
        XCTAssertEqual(snapshot.selectedID, revision.dashboardId)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), beforeState)
        XCTAssertEqual(try store.loadPackageFiles().map(\.data), beforePackage.map(\.data))
    }
    func testManifestWithoutBehaviorAndInstalledSelectionAreRetained() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeviceStateStore(root: directory)
        var installed: [DeviceInstalledScreen] = []
        for id in ["first", "second"] {
            let manifest = fixtureManifest(id: id)
            let staged = try store.stagePackage([(path: "index.html", data: Data("<html>retained</html>".utf8)),
                                                (path: "manifest.json", data: try JSONEncoder().encode(manifest))])
            var revision = StoredRevision.offlineFixture; revision.dashboardId = id; revision.revision = manifest.revision
            installed.append(.init(name: id, revision: revision, deployment: .init(deploymentId: "fixture", revision: manifest.revision, dashboardId: id, deviceId: "fixture", phase: .active), packageDirectory: staged.lastPathComponent))
        }
        var state = DevicePersistedState(owner: nil, activeRevision: "1", activeStoredRevision: installed[1].revision, lastDeployment: nil)
        state.screenSet = .init(deploymentId: "fixture", contentDigest: "fixture", grantSet: "retained", screens: installed, selectedDashboardId: "second")
        try store.save(state)
        let before = try Data(contentsOf: store.stateURL)
        let snapshot = DeviceRetainedContentSnapshot.load(store: store)
        XCTAssertEqual(snapshot.screens.map(\.id), ["first", "second"])
        XCTAssertEqual(snapshot.selectedID, "second")
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
    }
    func testInvalidBehaviorAndManifestIdentityAreRejected() throws {
        for mode in 0..<3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = DeviceStateStore(root: directory)
            var manifest = fixtureManifest(id: "fixture")
            if mode == 0 { manifest.dashboardId = "wrong" }
            if mode == 1 { manifest.revision = "wrong" }
            if mode == 2 { manifest.deviceBehavior = .init(temporaryActivation: .init(entityId: "invalid", activeState: "on", inactiveState: "off", idAttribute: "id", startedAtAttribute: "started", expiresAtAttribute: "expires", maxDurationSeconds: 0)) }
            let staged = try store.stagePackage([(path: "index.html", data: Data("<html/>".utf8)), (path: "manifest.json", data: try JSONEncoder().encode(manifest))])
            try store.activatePackage(staged: staged)
            var revision = StoredRevision.offlineFixture; revision.dashboardId = "fixture"; revision.revision = "1"
            try store.save(.init(owner: nil, activeRevision: "1", activeStoredRevision: revision, lastDeployment: nil))
            XCTAssertTrue(DeviceRetainedContentSnapshot.load(store: store).screens.isEmpty)
        }
    }
    private func fixtureManifest(id: String) -> DashboardManifest {
        .init(schemaVersion: 1, dashboardId: id, name: "Retained", revision: "1", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture", width: 640, height: 360, scale: 1, orientation: "landscape"), connections: [], files: [.init(path: "index.html", bytes: 20, sha256: String(repeating: "0", count: 64))])
    }
    func testRetainedLoaderDoesNotWriteOrCreateMissingStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DeviceStateStore(root: directory)
        XCTAssertTrue(DeviceRetainedContentSnapshot.load(store: store).screens.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("grants-sentinel")
        try Data([1, 2, 3]).write(to: marker)
        try Data("corrupt".utf8).write(to: store.stateURL)
        let before = try Data(contentsOf: store.stateURL)
        XCTAssertTrue(DeviceRetainedContentSnapshot.load(store: store).screens.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
        XCTAssertEqual(try Data(contentsOf: marker), Data([1, 2, 3]))
    }
}
private enum BootstrapError: Error { case factory }
private final class BootstrapJournal: CloudInstallationTransitionJournal {
    var value: DeviceManagementTransitionHistory?
    var failed = false
    func load() throws -> DeviceManagementTransitionHistory? { if failed { throw BootstrapError.factory }; return value }
    func save(_ history: DeviceManagementTransitionHistory) throws { XCTFail("unexpected write") }
}
private final class BootstrapBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
    var values: [String: Data] = [:]
    var failed = false
    func read(reference: String) throws -> Data? { if failed { throw BootstrapError.factory }; return values[reference] }
    func references() throws -> Set<String> { if failed { throw BootstrapError.factory }; return Set(values.keys) }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { XCTFail("unexpected insert"); throw BootstrapError.factory }
}
