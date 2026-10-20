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
    @MainActor func testPresentationSuspensionSnapshotsObserversAndRemainsNonterminal() {
        let lifetime = DeviceRuntimeLifetime()
        var calls = 0, terminal = 0
        var registration: UUID?
        registration = lifetime.registerSuspension {
            calls += 1
            lifetime.unregisterSuspension(registration)
        }
        let retained = lifetime.registerSuspension { calls += 1 }
        _ = lifetime.register { terminal += 1 }
        lifetime.suspendPresentation()
        XCTAssertEqual(calls,2); XCTAssertEqual(terminal,0); XCTAssertFalse(lifetime.isRetired)
        lifetime.suspendPresentation(); XCTAssertEqual(calls,3)
        lifetime.unregisterSuspension(retained)
        lifetime.suspendPresentation(); XCTAssertEqual(calls,3)
        _ = lifetime.registerSuspension { XCTFail("retirement must clear suspension observers") }
        lifetime.retire(); lifetime.suspendPresentation()
        XCTAssertEqual(terminal,1); XCTAssertTrue(lifetime.isRetired)
        XCTAssertNil(lifetime.registerSuspension { XCTFail("retired suspension registration ran") })
    }
    @MainActor func testLivePresentationGateDeniesPreferenceEffectsBeforeViewUpdateAndResumesNonterminally() throws {
        let preferences = ScreenPreferenceStore(root:root()), generation = try preferences.generation()
        let store = try PackageAssetStore.bundledOfflineFixture()
        let manifest = try JSONDecoder().decode(DashboardManifest.self,from:XCTUnwrap(store.assets["manifest.json"]?.data))
        let gate = RendererPresentationTestGate()
        let bridge = HomeAssistantWebBridge(runtime:nil,revision:manifest.revision,presentationAllowed:{gate.allows()},mapManifest:manifest,preferenceStore:preferences,onHealth:{_ in})
        func request(_ value:String) { bridge.handleValidatedBody(["protocolVersion":1,"kind":"request","method":"state.set","key":"retained","value":value],id:UUID().uuidString) }
        request("before")
        XCTAssertEqual(try preferences.get(dashboard:manifest.dashboardId,key:"retained",generation:generation) as? String,"before")
        gate.set(false) // No coordinator/SwiftUI update occurs before this callback.
        request("paused")
        XCTAssertEqual(try preferences.get(dashboard:manifest.dashboardId,key:"retained",generation:generation) as? String,"before")
        XCTAssertFalse(bridge.isSuspendedForReset)
        gate.set(true); bridge.setActive(true); request("resumed")
        XCTAssertEqual(try preferences.get(dashboard:manifest.dashboardId,key:"retained",generation:generation) as? String,"resumed")
        bridge.suspendForReset()
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

    @MainActor func testSynchronousSuspensionRejectsQueuedSettingsAcknowledgmentAfterGateReopens() async throws {
        let lifetime = DeviceRuntimeLifetime(), gate = RendererPresentationTestGate()
        var staleCallbacks = 0, currentCallbacks = 0
        let current = expectation(description:"current settings acknowledgment delivered")
        let coordinator = DashboardWebCoordinator(store:try .bundledOfflineFixture(),lifetime:lifetime,
            preferenceStore:.init(root:root()),active:false,presentationAllowed:{gate.allows()}) {}
        defer { coordinator.retireForReset() }
        coordinator.update(settings:.init(),active:false) { _ in staleCallbacks += 1 }
        // No await, redraw, or queued callback can observe the closed boolean.
        gate.set(false); lifetime.suspendPresentation(); gate.set(true)
        coordinator.update(settings:.init(),active:false) { _ in
            currentCallbacks += 1; current.fulfill()
        }
        await fulfillment(of:[current],timeout:2)
        XCTAssertEqual(staleCallbacks,0)
        XCTAssertEqual(currentCallbacks,1)
        XCTAssertFalse(coordinator.isRetired); XCTAssertFalse(lifetime.isRetired)
    }

    @MainActor func testOrdinaryStopThenUpdateRetainsSynchronousSuspensionObserver() async throws {
        let lifetime = DeviceRuntimeLifetime(), gate = RendererPresentationTestGate()
        var staleCallbacks = 0, currentCallbacks = 0
        let current = expectation(description:"current settings acknowledgment delivered")
        let coordinator = DashboardWebCoordinator(store:try .bundledOfflineFixture(),lifetime:lifetime,
            preferenceStore:.init(root:root()),active:false,presentationAllowed:{gate.allows()}) {}
        defer { coordinator.retireForReset() }
        coordinator.stop()
        coordinator.update(settings:.init(),active:true) { _ in staleCallbacks += 1 }
        // No await, redraw, or queued callback can observe the closed boolean.
        gate.set(false); lifetime.suspendPresentation(); gate.set(true)
        coordinator.update(settings:.init(),active:true) { _ in
            currentCallbacks += 1; current.fulfill()
        }
        await fulfillment(of:[current],timeout:2)
        XCTAssertEqual(staleCallbacks,0)
        XCTAssertEqual(currentCallbacks,1)
        XCTAssertFalse(coordinator.isRetired); XCTAssertFalse(lifetime.isRetired)
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

/// The production seam is Sendable and may be read by the public-read actor.
/// This test-only flag protects every read/write and fires denial observation
/// after releasing its lock; it never changes runtime/resource authority.
final class RendererPresentationTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    private var observedDenial = false
    private let onFirstDenial: @Sendable () -> Void
    init(onFirstDenial:@escaping @Sendable () -> Void = {}) { self.onFirstDenial = onFirstDenial }
    func set(_ value:Bool) { lock.lock(); self.value = value; lock.unlock() }
    func allows() -> Bool {
        lock.lock(); let result = value, notify = !value && !observedDenial
        if notify { observedDenial = true }; lock.unlock()
        if notify { onFirstDenial() }; return result
    }
}

private enum RendererBoundedTestError: Error { case expired }

/// Callback-based timeout returns independently of WebKit/provider cooperation;
/// a task-group timeout would still wait for an uncooperative child.
@MainActor func rendererJavaScript(_ web: WKWebView, _ script: String, arguments:[String:Any] = [:], seconds:UInt64 = 5) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        var finished = false
        var escape: Task<Void,Never>?
        let finish: @MainActor (Result<Any?,Error>) -> Void = { result in
            guard !finished else { return }; finished = true; escape?.cancel()
            continuation.resume(with:result)
        }
        escape = Task { @MainActor in
            do { try await Task.sleep(nanoseconds:seconds * 1_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            XCTFail("WebKit operation required bounded test escape")
            finish(.failure(RendererBoundedTestError.expired))
        }
        web.callAsyncJavaScript(script,arguments:arguments,in:nil,in:.page) { result in
            Task { @MainActor in finish(result.map { Optional($0) }) }
        }
    }
}

/// An independent escape is installed before publishing that the provider is
/// held. Every owning test also releases in defer and asserts escape was unused.
@MainActor final class RendererHeldOperation {
    private var continuation: CheckedContinuation<Void,Error>?
    private var escape: Task<Void,Never>?
    private let onHeld: () -> Void
    private(set) var escaped = false
    init(onHeld:@escaping () -> Void) { self.onHeld = onHeld }
    func hold() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            escape = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds:8_000_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.escaped = true
                XCTFail("Held renderer provider required bounded test escape")
                self.release(error:RendererBoundedTestError.expired)
            }
            onHeld()
        }
    }
    func release(error:Error? = nil) {
        escape?.cancel(); escape = nil
        let held = continuation; continuation = nil
        if let error { held?.resume(throwing:error) } else { held?.resume() }
    }
}
