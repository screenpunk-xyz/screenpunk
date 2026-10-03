import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor
final class DeviceManagementBootstrapTests: XCTestCase {
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
            let bootstrap = DeviceManagementBootstrap(authority: .init(journal: journal, credentials: .init(backend: backend, random: { XCTFail("unexpected generation"); return Data() }), reset: ManagementTestResetEvidence()), retained: { retainedLoads += 1; return .empty }, hostFactory: { _ in creations += 1; throw BootstrapError.factory })
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
            let bootstrap = DeviceManagementBootstrap(authority: .init(journal: journal, credentials: .init(backend: backend, random: { Data() }), reset: ManagementTestResetEvidence()), retained: { .empty }, hostFactory: { _ in creations += 1; throw BootstrapError.factory })
            bootstrap.start()
            XCTAssertEqual(creations, 1)
        }
    }
    func testRetryCannotEscapeKnownHistoryQuarantine() throws {
        let journal = BootstrapJournal(), backend = BootstrapBackend()
        journal.value = try .intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate")
        var creations = 0
        let bootstrap = DeviceManagementBootstrap(authority: .init(journal: journal, credentials: .init(backend: backend, random: { Data() }), reset: ManagementTestResetEvidence()), retained: { .empty }, hostFactory: { _ in creations += 1; throw BootstrapError.factory })
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
