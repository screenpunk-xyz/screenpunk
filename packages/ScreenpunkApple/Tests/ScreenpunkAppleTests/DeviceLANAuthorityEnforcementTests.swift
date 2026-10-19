import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

#if canImport(Network) && canImport(Security)
final class DeviceLANAuthorityEnforcementTests: XCTestCase {
    private func runtime(_ identity: TLSIdentityMaterial) -> DeviceRuntime {
        .init(identity: identity.pairingIdentity, profile: .init(deviceId: "authority-phone", name: "Test"),
              advertisement: .init(deviceId: "authority-phone", host: "127.0.0.1", port: 0, source: .advertised))
    }
    private func server(_ context: DeviceManagementContext, store: DeviceStateStore? = nil,
                        identity: TLSIdentityMaterial? = nil, clock: PairingClock = SystemClock()) throws -> DeviceLANServer {
        let identity = try identity ?? TLSIdentity.make(role: .device, commonName: "authority-enforcement")
        return try DeviceLANServer(management: context, runtime: runtime(identity), identity: identity, clock: clock, store: store,
            homeAssistantVault: .init(store: MemoryCredentialStore()), genericConnectionVault: .init(store: MemoryCredentialStore()))
    }
    private func temporaryStore() -> DeviceStateStore { .init(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }

    func testStaleConstructionCannotMigrateStorageOrCreateTLSIdentity() throws {
        let context = testManagementContext()
        let identity = try TLSIdentity.make(role: .device, commonName: "stale-construction")
        let store = temporaryStore(); defer { try? store.erase() }
        try store.save(.init(owner: nil, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil))
        let before = try Data(contentsOf: store.stateURL)
        try context.revoke()
        XCTAssertThrowsError(try server(context, store: store, identity: identity))
        var identityCalls = 0
        XCTAssertThrowsError(try DeviceLANHost(runtime: runtime(identity), management: context, store: store,
            identityProvider: { identityCalls += 1; return identity }))
        XCTAssertEqual(identityCalls, 0)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
    }

    func testEveryLocalMutationRejectsRevokedAdmissionAndPreservesRetainedContent() throws {
        let context = testManagementContext(), store = temporaryStore()
        defer { try? store.erase() }
        let identity = try TLSIdentity.make(role: .device, commonName: "retained-authority")
        let owner = PairingIdentityFactory.make(role: .controller)
        let revision = StoredRevision.offlineFixture
        let assets = try PackageAssetStore.bundledOfflineFixture().assets.values.map { (path: $0.path, data: $0.data) }
        try store.activatePackage(staged: store.stagePackage(assets))
        try store.save(.init(owner: owner, activeRevision: revision.revision, activeStoredRevision: revision, lastDeployment: nil))
        let server = try self.server(context, store: store, identity: identity)
        let grant = HomeAssistantProvisioning(dashboardId: revision.dashboardId, connectionId: "retained", provisioningId: "retained",
            revision: revision.revision, origin: "https://ha.example", token: "fixture")
        try server.homeAssistantVault.provision(grant, owner: PeerPin.hex(owner.publicKey))
        let beforeGrant = try server.homeAssistantVault.record(owner: PeerPin.hex(owner.publicKey), revision: revision.revision)
        let before = try Data(contentsOf: store.stateURL), settings = server.settingsSnapshot
        try context.revoke()
        let mutations: [() throws -> Void] = [
            { try server.confirmLocally() }, { try server.cancelPairing() }, { try server.expirePairingIfNeeded() },
            { try server.disconnect(keepScreens: true) }, { try server.disconnect(keepScreens: false) },
            { try server.removeScreen(revision.dashboardId) }, { try server.removeAllScreens() },
            { try server.selectScreen(revision.dashboardId) },
            { _ = try server.updateSettingsLocally(.init(expectedRevision: settings.revision, value: .init())) },
            { try server.markSettingsApplied(revision: settings.revision) }, { try server.markSettingsUnapplied(revision: settings.revision) },
            { try server.updateTemporaryActivationStatus(.init()) }, { try server.unlink() }, { try server.start() }
        ]
        for mutate in mutations { XCTAssertThrowsError(try mutate()) { XCTAssertEqual($0 as? DeviceManagementAuthority.Failure, .staleLease) } }
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
        XCTAssertEqual(server.settingsSnapshot, settings)
        XCTAssertNotNil(server.activePackage?.assets["index.html"])
        XCTAssertEqual(try server.homeAssistantVault.record(owner: PeerPin.hex(owner.publicKey), revision: revision.revision), beforeGrant)
        XCTAssertEqual(server.port, 0)
    }

    func testRevocationDuringListenerReadinessCannotInstallOrRestart() throws {
        let context = testManagementContext(), server = try server(context)
        let barrier = EnforcementBarrier()
        server.managementBoundary = { if $0 == .listenerReady { barrier.pause() } }
        let completed = expectation(description: "startup rejected")
        DispatchQueue.global().async {
            expectFailure { try server.start() }; completed.fulfill()
        }
        XCTAssertTrue(barrier.wait())
        // Returns while start is paused: neither gate nor server lock spans readiness.
        try context.revoke()
        XCTAssertEqual(server.port, 0)
        barrier.release()
        wait(for: [completed], timeout: 5)
        XCTAssertNil(server.listener)
        XCTAssertThrowsError(try server.start())
    }

    func testRevocationBeforeListenerStartCancelsCandidateWithoutInstallation() throws {
        let context = testManagementContext(), server = try server(context)
        let barrier = EnforcementBarrier(), completed = expectation(description: "candidate rejected")
        server.managementBoundary = { if $0 == .listenerWillStart { barrier.pause() } }
        DispatchQueue.global().async { expectFailure { try server.start() }; completed.fulfill() }
        XCTAssertTrue(barrier.wait())
        try context.revoke()
        barrier.release(); wait(for: [completed], timeout: 7)
        XCTAssertNil(server.listener)
        XCTAssertEqual(server.port, 0)
    }

    func testStoppedListenerCandidateCannotReplaceNewerAttempt() throws {
        let context = testManagementContext(), server = try server(context)
        let barrier = EnforcementBarrier(), first = expectation(description: "old startup rejected")
        server.managementBoundary = { if $0 == .listenerReady { barrier.pauseFirst() } }
        DispatchQueue.global().async { expectFailure { try server.start() }; first.fulfill() }
        XCTAssertTrue(barrier.wait())
        server.stop()
        try server.start()
        let newPort = server.port
        XCTAssertGreaterThan(newPort, 0)
        barrier.release(); wait(for: [first], timeout: 5)
        XCTAssertEqual(server.port, newPort)
        server.stop()
    }

    func testRevocationDuringHandshakeDropsAcceptedConnection() throws {
        let context = testManagementContext(), server = try server(context)
        let controller = try TLSIdentity.make(role: .controller, commonName: "handshake-revoked")
        let barrier = EnforcementBarrier()
        server.managementBoundary = { if $0 == .handshakeReady { barrier.pause() } }
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: controller); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(barrier.wait())
        XCTAssertEqual(server.activeConnectionCount, 1)
        try context.revoke()
        XCTAssertEqual(server.activeConnectionCount, 0)
        barrier.release()
        XCTAssertThrowsError(try client.beginPairing(nonce: PairingIdentityFactory.nonce()))
        XCTAssertNil(server.pendingPairingRequest)
    }

    func testReceivedPairConfirmCannotCommitAfterRevocationDuringApprovalWait() throws {
        let context = testManagementContext(), store = temporaryStore(), server = try server(context, store: store)
        defer { server.stop(); try? store.erase() }
        let controller = try TLSIdentity.make(role: .controller, commonName: "confirm-revoked")
        let client = ControllerLANClient(identity: controller); defer { client.cancel() }
        try server.start(); try client.connect(host: "127.0.0.1", port: server.port)
        let begun = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        let barrier = EnforcementBarrier(), completed = expectation(description: "confirm rejected")
        server.managementBoundary = { if $0 == .pairingWaitStarted { barrier.pause() } }
        DispatchQueue.global().async { expectFailure { try client.confirmPairing(code: begun.code) }; completed.fulfill() }
        XCTAssertTrue(barrier.wait())
        try context.revoke()
        barrier.release(); wait(for: [completed], timeout: 5)
        XCTAssertNil(store.load()?.owner)
        XCTAssertFalse(server.runtime.isPaired)
        XCTAssertNil(server.pendingPairingRequest)
    }

    func testReceivedOwnerSettingsUpdateCannotCommitAfterRevocation() throws {
        let context = testManagementContext(), store = temporaryStore()
        defer { try? store.erase() }
        let controller = try TLSIdentity.make(role: .controller, commonName: "request-revoked")
        try store.save(.init(owner: controller.pairingIdentity, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil))
        let server = try server(context, store: store), client = ControllerLANClient(identity: controller)
        defer { server.stop(); client.cancel() }
        try server.start(); try client.connect(host: "127.0.0.1", port: server.port)
        _ = try client.hello()
        let settings = try client.getSettings(), before = try Data(contentsOf: store.stateURL)
        let barrier = EnforcementBarrier(), completed = expectation(description: "update rejected")
        server.managementBoundary = { if $0 == .requestReceived(LANMethod.settingsUpdate.rawValue) { barrier.pause() } }
        DispatchQueue.global().async {
            expectFailure { _ = try client.updateSettings(.init(expectedRevision: settings.revision,
                value: .init(brightness: .init(mode: .fixed, fixedLevel: 0.2)))) }
            completed.fulfill()
        }
        XCTAssertTrue(barrier.wait()); try context.revoke(); barrier.release()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
        XCTAssertEqual(server.settingsSnapshot, settings)
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    func testHandshakeCannotInheritRepairedSamePinManagerGeneration() throws {
        let context = testManagementContext(), store = temporaryStore()
        defer { try? store.erase() }
        let controller = try TLSIdentity.make(role: .controller, commonName: "same-pin-generation")
        try store.save(.init(owner: controller.pairingIdentity, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil))
        let server = try server(context, store: store), old = ControllerLANClient(identity: controller), current = ControllerLANClient(identity: controller)
        defer { server.stop(); old.cancel(); current.cancel() }
        let barrier = EnforcementBarrier()
        server.managementBoundary = { if $0 == .handshakeReady { barrier.pauseFirst() } }
        try server.start(); try old.connect(host: "127.0.0.1", port: server.port)
        XCTAssertTrue(barrier.wait())
        try server.disconnect(keepScreens: true)
        try current.connect(host: "127.0.0.1", port: server.port)
        _ = try current.hello()
        let begin = try current.beginPairing(nonce: PairingIdentityFactory.nonce())
        try server.confirmLocally(); try current.confirmPairing(code: begin.code)
        XCTAssertNoThrow(try current.getSettings())
        barrier.release()
        _ = try old.hello()
        XCTAssertThrowsError(try old.getSettings()) { XCTAssertEqual($0 as? TransferFailure, .notPaired) }
    }

    func testChangedCloudEvidenceQuarantinesServerWithoutLocalMutation() throws {
        let backend = EnforcementEvidenceBackend()
        let authority = DeviceManagementAuthority(journal: ManagementTestJournal(), credentials: .init(backend: backend, random: { Data() }), reset: ManagementTestResetEvidence())
        let context = DeviceManagementContext(authority: authority, lease: try XCTUnwrap(authority.refresh()))
        let server = try server(context), settings = server.settingsSnapshot
        backend.setOrphan(true)
        XCTAssertThrowsError(try server.updateSettingsLocally(.init(expectedRevision: settings.revision, value: .init())))
        XCTAssertEqual(server.settingsSnapshot, settings)
        backend.setOrphan(false)
        XCTAssertNil(try authority.refresh(), "Removing evidence cannot restore a quarantined owner")
        XCTAssertThrowsError(try server.start())
    }

    func testRetainedGenericGrantRuntimeCanBeConstructedAfterManagementRevocation() async throws {
        let context = testManagementContext(), store = temporaryStore()
        defer { try? store.erase() }
        let owner = PairingIdentityFactory.make(role: .controller), revision = StoredRevision.offlineFixture
        try store.save(.init(owner: owner, activeRevision: revision.revision, activeStoredRevision: revision, lastDeployment: nil))
        let server = try server(context, store: store)
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "retained", origin: "https://example.com", transport: .http,
            authRef: "retained", lan: false, allowInsecureHTTP: false,
            operations: [.init(name: "read", kind: .http, method: .GET, path: "/status", idempotent: true, write: false)])
        try server.genericConnectionVault.provision(.init(dashboardId: revision.dashboardId, revision: revision.revision, provisioningId: "retained",
            entries: [.init(grant: grant, binding: .init(authRef: "retained", placement: .bearer), secret: Data("fixture".utf8))]), owner: PeerPin.hex(owner.publicKey))
        _ = try await server.makeGenericConnectionRuntime()
        try context.revoke()
        _ = try await server.makeGenericConnectionRuntime()
        XCTAssertEqual(server.runtime.activeRevision, revision.revision)
    }

    func testStaleTemporaryActivationCannotWriteCheckpoint() throws {
        let context = testManagementContext(), server = try server(context)
        try context.revoke()
        var writes = 0
        XCTAssertThrowsError(try server.commitTemporaryActivationSelection(nil,
            expectedScope: .init(owner: "old", revision: "old", dashboardId: "old"),
            beforeSelection: { writes += 1 }, afterSelection: { writes += 1 }))
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testHostRetryAndUnlinkCannotEscapeCapturedAdmission() async throws {
        let authority = DeviceManagementAuthority(journal: ManagementTestJournal(), credentials: .init(backend: ManagementTestCredentials(), random: { Data() }), reset: ManagementTestResetEvidence())
        let context = DeviceManagementContext(authority: authority, lease: try XCTUnwrap(authority.refresh()))
        let identity = try TLSIdentity.make(role: .device, commonName: "host-admission")
        let store = temporaryStore(); defer { try? store.erase() }
        try store.save(.init(owner: nil, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil))
        let host = try DeviceLANHost(runtime: runtime(identity), management: context, store: store, identityProvider: { identity })
        let before = try Data(contentsOf: store.stateURL)
        try host.server?.start()
        try context.revoke()
        // A new lease does not renew an existing host's captured admission.
        XCTAssertNotNil(try authority.refresh())
        host.start(); host.resume(); host.unlink()
        await Task.yield()
        XCTAssertEqual(host.server?.port, 0)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
        XCTAssertNotNil(host.errorMessage)
    }

    func testCallbacksMayReenterAuthorityAndServerWithoutDeadlock() throws {
        let context = testManagementContext(), server = try server(context)
        var notified = false
        server.onChange = {
            do { try context.validate(); try server.markSettingsApplied(revision: "stale-revision") }
            catch { XCTFail("Callback still held a management lock: \(error)") }
            notified = true
        }
        _ = try server.updateSettingsLocally(.init(expectedRevision: server.settingsSnapshot.revision, value: .init()))
        XCTAssertTrue(notified)
    }

    func testOldPairingExpiryCannotExpireReplacementAndRevocationClearsPending() throws {
        let context = testManagementContext(), server = try server(context)
        let controller = try TLSIdentity.make(role: .controller, commonName: "expiry-revoked")
        let client = ControllerLANClient(identity: controller)
        defer { server.stop(); client.cancel() }
        try server.start(); try client.connect(host: "127.0.0.1", port: server.port)
        let old = PairingIdentityFactory.nonce()
        _ = try client.beginPairing(nonce: old); try server.cancelPairing()
        let next = PairingIdentityFactory.nonce()
        _ = try client.beginPairing(nonce: next)
        try server.expirePairingIfNeeded(expectedSessionNonceHex: PeerPin.hex(old))
        XCTAssertEqual(server.pendingPairingSessionNonceHex, PeerPin.hex(next))
        try context.revoke()
        XCTAssertNil(server.pendingPairingRequest)
        XCTAssertThrowsError(try server.expirePairingIfNeeded(expectedSessionNonceHex: PeerPin.hex(next)))
    }
}

private final class EnforcementEvidenceBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var orphan = false
    func setOrphan(_ value: Bool) { lock.lock(); orphan = value; lock.unlock() }
    func read(reference: String) throws -> Data? { Data(repeating: 1, count: 32) }
    func references() throws -> Set<String> { lock.lock(); defer { lock.unlock() }; return orphan ? ["orphan"] : [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { fatalError("No Cloud writes") }
}

private func expectFailure(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    do { try operation(); XCTFail("Expected rejected operation", file: file, line: line) } catch {}
}

private final class EnforcementBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pauses = 0
    func pause() { entered.signal(); _ = resume.wait(timeout: .now() + 10) }
    func pauseFirst() { lock.lock(); pauses += 1; let first = pauses == 1; lock.unlock(); if first { pause() } }
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func release() { resume.signal() }
}
#endif
