import XCTest
import WebKit
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceRuntimeRetirementTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    @MainActor func testRetiredCoordinatorRejectsDeferredCallbacksAndReactivation() async throws {
        let lifetime = DeviceRuntimeLifetime(), preferences = ScreenPreferenceStore(root: root())
        let package = try PackageAssetStore.bundledOfflineFixture(); var callbacks = 0
        let coordinator = DashboardWebCoordinator(store: package, lifetime: lifetime, preferenceStore: preferences,
            active: false, onSettingsApplied: { _ in callbacks += 1 }, onReady: { callbacks += 1 }) {}
        coordinator.update(settings: .init(), active: false) { _ in callbacks += 1 }
        lifetime.retire()
        coordinator.update(settings: .init(), active: true) { _ in XCTFail("reactivated") }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isRetired); XCTAssertEqual(callbacks, 0)
        let blank = coordinator.makeWebView()
        XCTAssertFalse(blank.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertNil(blank.navigationDelegate)
        coordinator.webView(blank, didFinish: nil); coordinator.webViewWebContentProcessDidTerminate(blank)
        XCTAssertNil(blank.url); XCTAssertEqual(callbacks, 0)
    }
    @MainActor func testLateCoordinatorCannotInitializePreferenceWriter() throws {
        let lifetime = DeviceRuntimeLifetime(); lifetime.retire()
        let directory = root(), preferences = ScreenPreferenceStore(root: directory)
        let coordinator = DashboardWebCoordinator(store: try .bundledOfflineFixture(), lifetime: lifetime, preferenceStore: preferences) {}
        XCTAssertTrue(coordinator.isRetired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    @MainActor func testHostLifetimeRetiresNetworkingForegroundAndLocalMutationsWithoutErasure() async throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "retirement-\(UUID().uuidString)")
        let store = DeviceStateStore(root: root())
        let runtime = DeviceRuntime(identity: identity.pairingIdentity, profile: .init(deviceId: "fixture", name: "Fixture"), advertisement: .init(deviceId: "fixture", host: "127.0.0.1", port: 0, source: .advertised))
        let host = try DeviceLANHost(runtime: runtime, management: testManagementContext(), store: store, identityProvider: { identity }, homeAssistantVault: .init(store: MemoryCredentialStore()), genericConnectionVault: .init(store: MemoryCredentialStore()))
        try store.save(.init(owner: nil, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil))
        let before = try Data(contentsOf: store.stateURL)
        try XCTUnwrap(host.server).start()
        XCTAssertNotEqual(host.server?.port, 0)
        host.setForeground(true); let lifetime = host.lifetime
        lifetime.retire(); host.retireForReset(); host.setForeground(true); host.start(); host.resume(); host.refresh()
        host.confirm(); host.cancelPairing(); host.selectScreen("missing"); host.unlink()
        XCTAssertThrowsError(try host.disconnect(keepScreens: false)); XCTAssertThrowsError(try host.removeAllScreens())
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(lifetime.isRetired); XCTAssertEqual(host.server?.port, 0)
        XCTAssertThrowsError(try host.server?.start()); XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
    }
    func testCapturedContentActorsRejectAfterServerRetirementWhileCredentialsSurvive() async throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "captured-retirement-\(UUID().uuidString)")
        let owner = PairingIdentityFactory.make(role: .controller), revision = StoredRevision.offlineFixture
        let store = DeviceStateStore(root: root())
        var state = DevicePersistedState(owner: owner, activeRevision: revision.revision, activeStoredRevision: revision, lastDeployment: nil)
        state.screenSet = .init(deploymentId: "fixture", contentDigest: "fixture", grantSet: "fixture-grants", screens: [.init(name: "Fixture", revision: revision, deployment: .init(deploymentId: "fixture", revision: revision.revision, dashboardId: revision.dashboardId, deviceId: "fixture", phase: .active), packageDirectory: "package")], selectedDashboardId: revision.dashboardId)
        try store.activatePackage(staged: store.stagePackage([("index.html", Data("<html>fixture</html>".utf8))]))
        try store.save(state)
        let vaultStore = MemoryCredentialStore(), genericStore = MemoryCredentialStore()
        let vault = HomeAssistantDeviceVault(store: vaultStore), generic = GenericConnectionDeviceVault(store: genericStore)
        let pin = PeerPin.hex(owner.publicKey)
        try vault.stage([.init(dashboardId: revision.dashboardId, connectionId: "home", provisioningId: "fixture", revision: revision.revision, origin: "https://example.com", token: "fixture")], owner: pin, generation: "fixture-grants")
        var publicConnection = ManifestConnection(alias: "publicData", required: true)
        publicConnection.publicHTTP = .init(origin: "https://example.com", operations: [.init(name: "read", path: "/data", response: "json", maxAgeSeconds: 1, staleSeconds: 10)])
        let publicManifest = DashboardManifest(schemaVersion: 1, dashboardId: revision.dashboardId, name: "Fixture", revision: revision.revision, entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture", width: revision.width, height: revision.height, scale: 1, orientation: "landscape"), connections: [publicConnection], files: [])
        try vault.stagePublic([PublicReadProvisioning(manifest: publicManifest)], owner: pin, generation: "fixture-grants")
        let runtime = DeviceRuntime(identity: identity.pairingIdentity, profile: .init(deviceId: "fixture", name: "Fixture"), advertisement: .init(deviceId: "fixture", host: "127.0.0.1", port: 0, source: .advertised))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: identity, store: store, homeAssistantVault: vault, genericConnectionVault: generic)
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "sensor", origin: "https://example.com", transport: .http, authRef: "fixture", lan: false, allowInsecureHTTP: false, operations: [.init(name: "read", kind: .http, method: .GET, path: "/status", idempotent: true, write: false)])
        try generic.provision(.init(dashboardId: revision.dashboardId, revision: revision.revision, provisioningId: "fixture", entries: [.init(grant: grant, binding: .init(authRef: "fixture", placement: .bearer), secret: Data("secret".utf8))]), owner: pin)
        let capturedGeneric = try await server.makeGenericConnectionRuntime(), capturedHome = server.homeAssistantRuntime
        let capturedPublic = try XCTUnwrap(server.publicReadSession())
        _ = server.suspendManagement()
        XCTAssertTrue(server.publicReadSession() === capturedPublic, "Ordinary management revocation preserves content authority")
        _ = try await server.makeGenericConnectionRuntime()
        let before = try Data(contentsOf: store.stateURL), genericBytes = try genericStore.secret(for: GenericConnectionDeviceVault.storageKey), homeBytes = try vaultStore.secret(for: HomeAssistantDeviceVault.storageKeys[1])
        server.retireForReset(); server.retireForReset()
        do { _ = try await capturedGeneric.requestRead(alias: "sensor", operation: "read", parameters: [:]); XCTFail("captured generic actor authorized") } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        do { _ = try await capturedHome.request(revision: revision.revision, alias: "home", operation: "getStates", parameters: [:]); XCTFail("captured home actor authorized") } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        do { _ = try await capturedPublic.runtime.request(alias: "publicData", operation: "read", parameters: [:]); XCTFail("captured public actor authorized") } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        XCTAssertNil(server.temporaryActivationScope()); XCTAssertNil(server.publicReadSession())
        XCTAssertEqual(try genericStore.secret(for: GenericConnectionDeviceVault.storageKey), genericBytes)
        XCTAssertEqual(try vaultStore.secret(for: HomeAssistantDeviceVault.storageKeys[1]), homeBytes)
        XCTAssertEqual(try Data(contentsOf: store.stateURL), before)
    }
    @MainActor func testOrdinaryCoordinatorStopStillAllowsCurrentGenerationUpdates() async throws {
        let lifetime = DeviceRuntimeLifetime(); var callbacks = 0
        let coordinator = DashboardWebCoordinator(store: try .bundledOfflineFixture(), lifetime: lifetime, preferenceStore: .init(root: root()), active: false) {}
        coordinator.stop(); coordinator.update(settings: .init(), active: false) { _ in callbacks += 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(coordinator.isRetired); XCTAssertFalse(lifetime.isRetired); XCTAssertEqual(callbacks, 1)
    }

    @MainActor func testDirectCoordinatorRetirementAlsoRejectsAlreadyQueuedAcknowledgment() async throws {
        let lifetime = DeviceRuntimeLifetime(); var callbacks = 0
        let coordinator = DashboardWebCoordinator(store: try .bundledOfflineFixture(), lifetime: lifetime, preferenceStore: .init(root: root()), active: false) {}
        coordinator.update(settings: .init(), active: false) { _ in callbacks += 1 }
        coordinator.retireForReset()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.isRetired); XCTAssertFalse(lifetime.isRetired); XCTAssertEqual(callbacks, 0)
    }

}
