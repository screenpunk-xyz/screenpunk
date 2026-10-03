import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class ResetWriterSuspensionTests: XCTestCase {
    actor IgnoringCancellationTransport: HTTPTransport {
        var calls = 0
        var continuation: CheckedContinuation<HTTPTransportResponse, Never>?
        func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func count() -> Int { calls }
        func finish() { continuation?.resume(returning: .init(status: 200, body: Data("{}".utf8), headers: ["content-type": "application/json"])); continuation = nil }
    }
    @MainActor private func bridge(_ transport: IgnoringCancellationTransport, health: @escaping (Bool) -> Void) throws -> HomeAssistantWebBridge {
        var connection = ManifestConnection(alias: "publicData", required: true)
        connection.publicHTTP = .init(origin: "https://data.example.org", operations: [.init(name: "read", path: "/data", response: "json", maxAgeSeconds: 1, staleSeconds: 10)])
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "fixture", name: "Fixture", revision: "revision", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "fixture", width: 400, height: 400, scale: 1, orientation: "portrait"), connections: [connection], files: [])
        let runtime = try PublicReadRuntime(provisioning: .init(manifest: manifest), transport: transport, resolver: FixedResolver(["203.0.113.10"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return HomeAssistantWebBridge(runtime: nil, revision: "revision", preferenceStore: .init(root: root), publicReads: runtime, onHealth: health)
    }
    private var request: [String: Any] { ["protocolVersion": 1, "kind": "request", "method": "connections.request", "alias": "publicData", "operation": "read", "parameters": [String:String]()] }

    @MainActor func testQueuedBridgeWorkNeverStartsAfterTerminalSuspension() async throws {
        let transport = IgnoringCancellationTransport()
        let bridge = try bridge(transport) { _ in XCTFail("late health") }
        bridge.handleValidatedBody(request, id: "queued")
        bridge.suspendForReset(); bridge.cancel(); bridge.setActive(true)
        bridge.handleValidatedBody(request, id: "replacement")
        for _ in 0..<20 { await Task.yield() }
        let count = await transport.count()
        XCTAssertEqual(count, 0); XCTAssertTrue(bridge.isSuspendedForReset)
    }
    @MainActor func testInFlightCancellationIgnoringResponseCannotPublishOrReactivate() async throws {
        let transport = IgnoringCancellationTransport()
        var health = 0
        let bridge = try bridge(transport) { _ in health += 1 }
        bridge.handleValidatedBody(request, id: "inflight")
        for _ in 0..<1000 { if await transport.count() == 1 { break }; await Task.yield() }
        let before = await transport.count(); XCTAssertEqual(before, 1)
        bridge.suspendForReset(); bridge.setActive(true)
        await transport.finish()
        for _ in 0..<100 { await Task.yield() }
        bridge.handleValidatedBody(request, id: "later")
        XCTAssertEqual(health, 0); let after = await transport.count(); XCTAssertEqual(after, 1)
    }
    @MainActor func testTemporaryCheckpointCallbacksAndAllEntryPointsStayFenced() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "reset-writer-\(UUID().uuidString)")
        let runtime = DeviceRuntime(identity: identity.pairingIdentity, profile: .init(deviceId: "fixture", name: "Fixture"), advertisement: .init(deviceId: "fixture", host: "127.0.0.1", port: 0, source: .advertised))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: identity, homeAssistantVault: .init(store: MemoryCredentialStore()), genericConnectionVault: .init(store: MemoryCredentialStore()))
        var services = 0, writes = 0
        let activation = DeviceTemporaryActivationRuntime(server: server, makeService: { server in services += 1; return HomeAssistantDeviceRuntime(vault: server.homeAssistantVault) { nil } })
        let before = activation.checkpointMutation { writes += 1 }
        let after = activation.checkpointMutation { writes += 1 }
        activation.suspendForReset()
        activation.update(active: true); activation.update(active: false); activation.update(active: true)
        activation.receive(state: ["entity_id": "fixture", "state": "on"], now: Date())
        activation.expire(now: Date()); activation.manualSelection(); activation.suspendForReset()
        XCTAssertThrowsError(try before()); XCTAssertThrowsError(try after())
        XCTAssertEqual(writes, 0); XCTAssertEqual(services, 0); XCTAssertTrue(activation.isSuspendedForReset)
    }
    @MainActor func testDroppingPollingRuntimeReleasesItDuringCancellationIgnoringTransport() async throws {
        let device = try TLSIdentity.make(role: .device, commonName: "reset-lifetime-\(UUID().uuidString)")
        let owner = try TLSIdentity.make(role: .controller, commonName: "reset-owner-\(UUID().uuidString)")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Fixture"), advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised), pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault, genericConnectionVault: .init(store: MemoryCredentialStore()))
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        _ = try client.hello(); _ = try client.deployScreenSet(lifetimeBody())
        let transport = IgnoringCancellationTransport()
        var listener: DeviceTemporaryActivationRuntime? = DeviceTemporaryActivationRuntime(server: server) { server in
            HomeAssistantDeviceRuntime(vault: vault, scope: { server.temporaryActivationScope() }, transport: transport, resolver: FixedResolver(["203.0.113.10"]))
        }
        weak var weakListener = listener
        listener?.update(active: true)
        for _ in 0..<1000 { if await transport.count() == 1 { break }; await Task.yield() }
        let count = await transport.count(); XCTAssertEqual(count, 1)
        listener = nil
        XCTAssertNil(weakListener, "A blocked transport must not retain its runtime through the polling task")
        await transport.finish()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(server.screenSet?.selectedDashboardId, "first")
    }

    private func lifetimeBody() throws -> LANScreenSetDeployBody {
        let items = try ["first", "second"].map { name -> LANScreenSetItem in
            var revision = StoredRevision.offlineFixture
            revision.dashboardId = name; revision.revision = name + "-revision"
            let data = Data("<html>\(name)</html>".utf8)
            var files = [LANFileBlob(path: "index.html", sha256: PeerPin.hex(PeerPin.sha256(data)), dataBase64: data.base64EncodedString())]
            if name == "second" {
                let configuration = TemporaryActivationConfiguration(entityId: "sensor.notice", activeState: "on", inactiveState: "off",
                    idAttribute: "alert_id", startedAtAttribute: "started_at", expiresAtAttribute: "expires_at", maxDurationSeconds: 300)
                let manifest = DashboardManifest(schemaVersion: 1, dashboardId: name, name: "Unrelated display name", revision: revision.revision,
                    entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "set-phone", width: revision.width,
                    height: revision.height, scale: 1, orientation: "landscape"), connections: [],
                    files: [.init(path: "index.html", bytes: data.count, sha256: PeerPin.hex(PeerPin.sha256(data)))],
                    deviceBehavior: .init(temporaryActivation: configuration))
                let bytes = try JSONEncoder().encode(manifest)
                files.append(.init(path: "manifest.json", sha256: PeerPin.hex(PeerPin.sha256(bytes)), dataBase64: bytes.base64EncodedString()))
            }
            return .init(name: name, deployment: .init(deployment: .init(deploymentId: name + "-deploy",
                revision: revision.revision, dashboardId: name, deviceId: "set-phone", phase: .queued), revision: revision,
                files: files),
                homeAssistant: .init(dashboardId: name, connectionId: "home", provisioningId: name + "-grant",
                    revision: revision.revision, origin: "https://ha.example", token: name + "-token"))
        }
        return .init(deploymentId: "set-deploy", deviceId: "set-phone", screens: items, selectedDashboardId: "first")
    }
}
