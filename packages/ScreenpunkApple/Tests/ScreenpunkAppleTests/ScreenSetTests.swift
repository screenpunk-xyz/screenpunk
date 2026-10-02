import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class ScreenSetTests: XCTestCase {
    func testAtomicSetSelectionRelaunchFailuresAndGrantIsolation() throws {
        let device = try TLSIdentity.make(role: .device, commonName: "set-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "set-owner")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DeviceStateStore(root: root)
        defer { try? store.erase() }
        let secrets = SetTestCredentialStore()
        let vault = HomeAssistantDeviceVault(store: secrets)
        let pin = PeerPin.hex(owner.pin)
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test phone"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised),
            pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner)
        defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        XCTAssertTrue(try client.hello().capabilities?.contains("screen-set-v1") == true)
        XCTAssertTrue(try client.hello().capabilities?.contains("home-assistant-temporary-activation-v1") == true)
        let body = try makeBody()
        let receipt = try client.deployScreenSet(body)
        XCTAssertEqual(receipt.screens.map(\.dashboardId), ["first", "second"])
        XCTAssertEqual(try client.deployScreenSet(body), receipt)
        let generation = try XCTUnwrap(server.screenSet?.grantSet)
        let firstGrant = try vault.record(owner: pin, revision: "first-revision", grantSet: generation)
        XCTAssertEqual(firstGrant.configuration.dashboardId, "first")
        XCTAssertEqual(try vault.record(owner: pin, revision: "second-revision", grantSet: generation).configuration.token, "second-token")
        XCTAssertThrowsError(try vault.record(owner: "wrong-owner", revision: "first-revision", grantSet: generation))
        XCTAssertThrowsError(try vault.record(owner: pin, revision: "other-revision", grantSet: generation))
        try server.selectScreen("second")
        XCTAssertEqual(try client.queryActiveState().selectedDashboardId, "second")
        XCTAssertEqual(try client.deployScreenSet(body), receipt, "Retry returns original receipt after swipe")
        XCTAssertEqual(server.runtime.activeRevision, "second-revision")
        XCTAssertEqual(server.activePackage?.assets["index.html"]?.data, Data("<html>second</html>".utf8))
        let restored = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertEqual(restored.screenSet?.screens.count, 2)
        XCTAssertEqual(restored.runtime.activeRevision, "second-revision")
        XCTAssertEqual(restored.activePackage?.assets["index.html"]?.data, server.activePackage?.assets["index.html"]?.data)
        XCTAssertEqual(try vault.record(owner: pin, revision: "first-revision", grantSet: generation), firstGrant)

        var conflicting = body
        conflicting.screens[0].name = "Different same deployment"
        XCTAssertThrowsError(try client.deployScreenSet(conflicting))
        var wrongSize = body; wrongSize.deploymentId = "wrong-size"
        wrongSize.screens[1].deployment.revision.width += 1
        XCTAssertThrowsError(try client.deployScreenSet(wrongSize)) { error in
            XCTAssertEqual(error as? TransferFailure, .targetMismatch)
        }
        var corrupt = body; corrupt.deploymentId = "corrupt"
        corrupt.screens[1].deployment.files[0].sha256 = "bad"
        XCTAssertThrowsError(try client.deployScreenSet(corrupt))
        var deniedGrant = body; deniedGrant.deploymentId = "denied-grant"
        secrets.failWrites = true
        XCTAssertThrowsError(try client.deployScreenSet(deniedGrant))
        secrets.failWrites = false
        XCTAssertEqual(server.screenSet?.grantSet, generation)
        XCTAssertEqual(store.load()?.screenSet?.grantSet, generation)
        XCTAssertEqual(server.runtime.activeRevision, "second-revision")
        XCTAssertEqual(try vault.record(owner: pin, revision: "first-revision", grantSet: generation), firstGrant)

        // Simulate process loss after package/credential preparation but before the state commit.
        _ = try store.stagePackage([(path: "index.html", data: Data("uncommitted".utf8))])
        try vault.stage([body.screens[0].homeAssistant!], owner: pin, generation: "uncommitted")
        let afterCrash = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertEqual(afterCrash.runtime.activeRevision, "second-revision")
        XCTAssertEqual(afterCrash.screenSet?.grantSet, generation)
        let stateBytes = try Data(contentsOf: store.stateURL)
        XCTAssertFalse(String(decoding: stateBytes, as: UTF8.self).contains("first-token"))
        XCTAssertFalse(String(decoding: stateBytes, as: UTF8.self).contains("second-token"))

        var single = body; single.deploymentId = "single"; single.screens.removeLast()
        _ = try client.deployScreenSet(single)
        XCTAssertEqual(server.screenSet?.screens.count, 1)
        XCTAssertThrowsError(try vault.record(owner: pin, revision: "second-revision", grantSet: generation))
        try server.unlink()
        XCTAssertNil(server.screenSet)
        XCTAssertFalse(store.hasState)
    }

    func testPublicReadsTransferAlongsideHomeAssistantAndInvalidateHandlesOnSelection() throws {
        let device = try TLSIdentity.make(role: .device, commonName: "public-set-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "public-set-owner")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test phone"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised), pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        XCTAssertTrue(try client.hello().capabilities?.contains("public-read-http-v1") == true)
        var body = try makeBody()
        let id = UUID().uuidString.lowercased(), revisionId = UUID().uuidString.lowercased()
        var item = body.screens[0]
        item.homeAssistant = nil
        item.deployment.revision.dashboardId = id; item.deployment.revision.revision = revisionId
        item.deployment.deployment.dashboardId = id; item.deployment.deployment.revision = revisionId
        var connection = ManifestConnection(alias: "publicData", required: true)
        connection.publicHTTP = .init(origin: "https://data.example.org", operations: [.init(name: "timeline", path: "/timeline", response: "json")])
        let html = Data("<html>public fixture</html>".utf8)
        let target = ManifestTarget(profileId: "fixture-phone", width: item.deployment.revision.width, height: item.deployment.revision.height,
            scale: 1, orientation: "portrait")
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: id, name: "Public fixture", revision: revisionId,
            entrypoint: "index.html", sdkVersion: "1", target: target, connections: [connection],
            files: [.init(path: "index.html", bytes: html.count, sha256: PeerPin.hex(PeerPin.sha256(html)))])
        try PackageValidator.validate(manifest)
        let manifestData = try JSONEncoder().encode(manifest)
        item.deployment.files = [("index.html", html), ("manifest.json", manifestData)].map {
            .init(path: $0.0, sha256: PeerPin.hex(PeerPin.sha256($0.1)), dataBase64: $0.1.base64EncodedString())
        }
        item.publicReads = try PublicReadProvisioning(manifest: manifest)
        body.screens[0] = item; body.selectedDashboardId = id
        _ = try client.deployScreenSet(body)
        let session = try XCTUnwrap(server.publicReadSession())
        let png = try PublicReadRuntimeTests().raster()
        let handle = try session.resources.put(.init(state: "fresh", body: png, mime: "image/png", status: 200))
        let generation = try XCTUnwrap(server.screenSet?.grantSet)
        XCTAssertEqual(try vault.record(owner: PeerPin.hex(owner.pin), revision: "second-revision", grantSet: generation).configuration.token, "second-token")
        try server.selectScreen("second")
        XCTAssertNil(server.publicReadSession())
        XCTAssertThrowsError(try session.resources.asset(url: handle))
        try server.selectScreen(id)
        let newSession = try XCTUnwrap(server.publicReadSession())
        XCTAssertThrowsError(try newSession.resources.asset(url: handle))
        let restored = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertNotNil(restored.publicReadSession())
        var invalid = body; invalid.deploymentId = "mismatched-public-grant"
        invalid.screens[0].publicReads?.connections[0].publicHTTP?.origin = "https://unapproved.example.org"
        XCTAssertThrowsError(try client.deployScreenSet(invalid))
        XCTAssertEqual(server.screenSet?.grantSet, generation)
        try server.unlink()
        XCTAssertThrowsError(try vault.publicConfiguration(owner: PeerPin.hex(owner.pin), dashboardId: id, revision: revisionId, generation: generation))
    }

    func testPairedTLSDeployAcceptsAssetsBeyondLegacyLimit() throws {
        let device = try TLSIdentity.make(role: .device, commonName: "large-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "large-owner")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DeviceStateStore(root: root)
        defer { try? store.erase() }
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised),
            pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store,
            homeAssistantVault: HomeAssistantDeviceVault(store: MemoryCredentialStore()))
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner)
        defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        XCTAssertEqual(try client.hello().maxTransferBytes, 32 * 1024 * 1024)
        var body = try makeBody()
        let asset = Data(repeating: 0x55, count: 3 * 1024 * 1024)
        body.screens[0].deployment.files.append(.init(path: "generic.bin", sha256: PeerPin.hex(PeerPin.sha256(asset)), dataBase64: asset.base64EncodedString()))
        let encoded = try LANCodec.encodePayload(body)
        XCTAssertGreaterThan(encoded.utf8.count, LANProtocolLimits.legacyMessageBytes)
        let receipt = try client.deployScreenSet(body)
        XCTAssertEqual(receipt.screens.count, 2)
        XCTAssertEqual(server.activePackage?.assets["generic.bin"]?.data, asset)
        let restored = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store,
            homeAssistantVault: HomeAssistantDeviceVault(store: MemoryCredentialStore()))
        XCTAssertEqual(restored.activePackage?.assets["generic.bin"]?.data, asset)
    }

    func testCircularNavigationWrapsInBothDirections() {
        XCTAssertEqual(ScreenCarousel.index(from: 0, offset: -1, count: 2), 1)
        XCTAssertEqual(ScreenCarousel.index(from: 0, offset: 1, count: 2), 1)
        XCTAssertEqual(ScreenCarousel.index(from: 1, offset: 1, count: 2), 0)
        XCTAssertEqual(ScreenCarousel.index(from: 1, offset: -1, count: 2), 0)
        XCTAssertEqual(ScreenCarousel.index(from: 0, offset: -1, count: 3), 2)
        XCTAssertEqual(ScreenCarousel.index(from: 2, offset: 1, count: 3), 0)
        XCTAssertEqual(ScreenCarousel.index(from: 0, offset: 1, count: 1), 0)
        XCTAssertNil(ScreenCarousel.index(from: 0, offset: 1, count: 0))
    }

    func testInvalidMembershipBindingsAndSizeAreRejected() throws {
        let body = try makeBody()
        var invalid = body; invalid.screens = []
        XCTAssertThrowsError(try invalid.validate())
        invalid = body; invalid.screens.append(body.screens[0])
        XCTAssertThrowsError(try invalid.validate())
        invalid = body; invalid.selectedDashboardId = "missing"
        XCTAssertThrowsError(try invalid.validate())
        invalid = body; invalid.screens[1].deployment.deployment.deviceId = "other-device"
        XCTAssertThrowsError(try invalid.validate())
        invalid = body; invalid.screens[1].homeAssistant?.dashboardId = "first"
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try LANCodec.frame(Data(repeating: 0, count: LANProtocolLimits.maxMessageBytes + 1)))
    }

    @MainActor func testDeviceAlertSwitchesInactiveScreenRestoresAndSurvivesRestart() throws {
        let device = try TLSIdentity.make(role: .device, commonName: "alert-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "alert-owner")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised), pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        _ = try client.hello()
        let body = try makeBody(activationTargets: ["second"])
        _ = try client.deployScreenSet(body)
        let scope = try XCTUnwrap(server.temporaryActivationScope())
        XCTAssertEqual(scope.dashboardId, "second", "inactive target has its own approved scope")
        let listener = DeviceTemporaryActivationRuntime(server: server)
        listener.update(active: false)
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let attributes: [String: Any] = ["alert_id": "test-run", "started_at": formatter.string(from: now),
            "expires_at": formatter.string(from: now.addingTimeInterval(300))]
        listener.receive(state: ["entity_id": "sensor.notice", "state": "on", "attributes": attributes], now: now)
        XCTAssertEqual(try client.queryActiveState().selectedDashboardId, "second")
        XCTAssertEqual(server.temporaryActivationScope(), scope, "screen selection cannot revoke the native subscription")
        listener.receive(state: ["entity_id": "sensor.notice", "state": "off", "attributes": attributes], now: now)
        XCTAssertEqual(try client.queryActiveState().selectedDashboardId, "first")
        var second = attributes; second["alert_id"] = "next-run"
        second["started_at"] = formatter.string(from: now.addingTimeInterval(1))
        listener.receive(state: ["entity_id": "sensor.notice", "state": "on", "attributes": second], now: now.addingTimeInterval(1))
        XCTAssertEqual(server.screenSet?.selectedDashboardId, "second")
        let restarted = DeviceTemporaryActivationRuntime(server: server); restarted.update(active: false)
        restarted.expire(now: now.addingTimeInterval(301))
        XCTAssertEqual(server.screenSet?.selectedDashboardId, "first")
        try vault.revoke()
        XCTAssertNil(server.temporaryActivationScope())
        restarted.receive(state: ["entity_id": "sensor.notice", "state": "on", "attributes": second], now: now)
        XCTAssertEqual(server.screenSet?.selectedDashboardId, "first")
    }

    @MainActor func testNativeAlertPollsOnlyItsEntityAndNavigatesThroughTransport() async throws {
        let device = try TLSIdentity.make(role: .device, commonName: "alert-poll-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "alert-poll-owner")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised), pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        _ = try client.hello()
        let body = try makeBody(activationTargets: ["second"])
        _ = try client.deployScreenSet(body)
        let transport = AlertEntityTransport()
        let listener = DeviceTemporaryActivationRuntime(server: server, pollNanoseconds: 10_000_000) { server in
            HomeAssistantDeviceRuntime(vault: vault, scope: { server.temporaryActivationScope() }, transport: transport,
                resolver: FixedResolver(["203.0.113.10"]))
        }
        defer { listener.update(active: false) }
        listener.update(active: true)
        for _ in 0..<300 {
            if server.screenSet?.selectedDashboardId == "second" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(server.screenSet?.selectedDashboardId, "second", "real native task must consume HTTP state and select inactive alert")
        let status = try XCTUnwrap(client.queryActiveState().temporaryActivation)
        XCTAssertEqual(status.lastState, "on"); XCTAssertEqual(status.selectionCount, 1)
        XCTAssertGreaterThan(status.receivedCount, 0); XCTAssertNil(status.lastError)
        await transport.setActive(false)
        for _ in 0..<300 {
            if server.screenSet?.selectedDashboardId == "first" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(server.screenSet?.selectedDashboardId, "first")
        let paths = await transport.paths
        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy { $0 == "/api/states/sensor.notice" })
        try vault.revoke()
        listener.update(active: true)
        XCTAssertEqual(try client.queryActiveState().temporaryActivation?.phase, "missing_target_or_grant")
    }

    func testActivationRequiresDeclarationUniqueTargetAndScopedGrant() throws {
        let device = try TLSIdentity.make(role: .device, commonName: "config-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "config-owner")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised), pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        _ = try client.hello()
        var namedOnly = try makeBody(); namedOnly.screens[1].name = "Red Alert"
        _ = try client.deployScreenSet(namedOnly)
        XCTAssertNil(server.temporaryActivationScope(), "Names never grant participation")
        var ambiguous = try makeBody(activationTargets: ["first", "second"]); ambiguous.deploymentId = "ambiguous"
        _ = try client.deployScreenSet(ambiguous)
        XCTAssertNil(server.temporaryActivationScope(), "Multiple declarations fail closed")
        var ungranted = try makeBody(activationTargets: ["second"]); ungranted.deploymentId = "ungranted"
        ungranted.screens[1].homeAssistant = nil
        _ = try client.deployScreenSet(ungranted)
        XCTAssertNil(server.temporaryActivationScope(), "Other screen's grant does not authorize target")
        var configured = try makeBody(activationTargets: ["second"]); configured.deploymentId = "configured"
        _ = try client.deployScreenSet(configured)
        XCTAssertEqual(server.temporaryActivationScope()?.temporaryActivation?.entityId, "sensor.notice")
        let restored = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertEqual(contentScope(restored.temporaryActivationScope()), contentScope(server.temporaryActivationScope()))
        var invalid = configured; invalid.deploymentId = "invalid"
        let index = try XCTUnwrap(invalid.screens[1].deployment.files.firstIndex(where: { $0.path == "manifest.json" }))
        let original = try XCTUnwrap(Data(base64Encoded: invalid.screens[1].deployment.files[index].dataBase64))
        var manifest = try JSONDecoder().decode(DashboardManifest.self, from: original)
        manifest.deviceBehavior?.temporaryActivation?.entityId = "sensor.notice/escape"
        let bytes = try JSONEncoder().encode(manifest)
        invalid.screens[1].deployment.files[index] = .init(path: "manifest.json", sha256: PeerPin.hex(PeerPin.sha256(bytes)), dataBase64: bytes.base64EncodedString())
        XCTAssertThrowsError(try client.deployScreenSet(invalid))
        XCTAssertEqual(contentScope(server.temporaryActivationScope()), contentScope(restored.temporaryActivationScope()))
    }

    func testLocalDisconnectRetentionRemovalAndPersistenceFailure() throws {
        let device = try TLSIdentity.make(role: .device, commonName: "retention-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "retention-owner")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DeviceStateStore(root: root)
        defer { try? store.erase() }
        let secrets = SetTestCredentialStore()
        let vault = HomeAssistantDeviceVault(store: secrets)
        let runtime = DeviceRuntime(identity: device.pairingIdentity, profile: .init(deviceId: "set-phone", name: "Test phone"),
            advertisement: .init(deviceId: "set-phone", host: "127.0.0.1", port: 0, source: .advertised), pairing: .init(owner: owner.pairingIdentity))
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner); defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        _ = try client.hello()
        _ = try client.deployScreenSet(makeBody(activationTargets: ["first"]))
        let scope = try XCTUnwrap(server.temporaryActivationScope())
        let settings = server.settingsSnapshot
        let stateBytes = try Data(contentsOf: store.stateURL)
        // A directory at the atomic destination forces rename to fail without changing live state.
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try server.disconnect(keepScreens: false))
        XCTAssertTrue(server.runtime.isPaired)
        XCTAssertEqual(server.screenSet?.screens.count, 2)
        try FileManager.default.removeItem(at: store.stateURL)
        try stateBytes.write(to: store.stateURL)
        try server.disconnect(keepScreens: true)
        XCTAssertFalse(server.runtime.isPaired)
        XCTAssertEqual(server.settingsSnapshot, settings)
        XCTAssertEqual(server.screenSet?.screens.count, 2)
        XCTAssertEqual(server.temporaryActivationScope()?.owner, scope.owner)
        XCTAssertNotEqual(server.temporaryActivationScope(), scope, "Old in-flight scope must become stale")
        XCTAssertThrowsError(try client.queryActiveState(), "Existing controller loses management authority")
        let repairedClient = ControllerLANClient(identity: owner)
        defer { repairedClient.cancel() }
        try repairedClient.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        _ = try repairedClient.hello()
        let repairNonce = PairingIdentityFactory.nonce()
        let repair = try repairedClient.beginPairing(nonce: repairNonce)
        try server.confirmLocally(expectedSessionNonceHex: PeerPin.hex(repairNonce))
        try repairedClient.confirmPairing(code: repair.code)
        XCTAssertNoThrow(try repairedClient.queryActiveState())
        XCTAssertThrowsError(try client.queryActiveState(), "Same-pin repair never revives the old management channel")
        try server.disconnect(keepScreens: true)
        let restored = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertFalse(restored.runtime.isPaired)
        XCTAssertEqual(restored.screenSet?.screens.count, 2)
        XCTAssertEqual(restored.settingsSnapshot, settings)
        XCTAssertEqual(restored.temporaryActivationScope()?.owner, scope.owner)
        var reassigned = try XCTUnwrap(store.load())
        reassigned.owner = PairingIdentityFactory.make(role: .controller, bytes: [UInt8](repeating: 0x91, count: 32))
        try store.save(reassigned)
        let newManager = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertNil(newManager.temporaryActivationScope(), "A new manager never inherits old content capabilities")
        reassigned.owner = nil
        try store.save(reassigned)
        try restored.removeScreen("first")
        XCTAssertEqual(restored.screenSet?.selectedDashboardId, "second")
        XCTAssertNil(restored.temporaryActivationScope(), "Removed package cannot execute its retained credential")
        XCTAssertNoThrow(try vault.record(owner: scope.owner, revision: scope.revision, grantSet: scope.grantSet))
        try restored.removeAllScreens()
        XCTAssertNil(restored.activePackage)
        XCTAssertNil(restored.runtime.activeRevision)
        XCTAssertEqual(store.load()?.settings, settings)
        XCTAssertNil(store.load()?.screenSet)
    }

    private func contentScope(_ scope: HomeAssistantDeviceRuntime.Scope?) -> HomeAssistantDeviceRuntime.Scope? {
        var value = scope
        value?.authorityGeneration = nil // A relaunch has no surviving in-flight handles.
        return value
    }

    private func makeBody(activationTargets: Set<String> = []) throws -> LANScreenSetDeployBody {
        let items = try ["first", "second"].map { name -> LANScreenSetItem in
            var revision = StoredRevision.offlineFixture
            revision.dashboardId = name; revision.revision = name + "-revision"
            let data = Data("<html>\(name)</html>".utf8)
            var files = [LANFileBlob(path: "index.html", sha256: PeerPin.hex(PeerPin.sha256(data)), dataBase64: data.base64EncodedString())]
            if activationTargets.contains(name) {
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

private final class SetTestCredentialStore: CredentialStore, @unchecked Sendable {
    let base = MemoryCredentialStore()
    var failWrites = false
    func secret(for account: String) throws -> Data? { try base.secret(for: account) }
    func put(_ secret: Data, for account: String) throws {
        if failWrites { throw ConnectionFailure.permissionRequired }
        try base.put(secret, for: account)
    }
    func delete(_ account: String) throws { try base.delete(account) }
    func deleteAll() throws { try base.deleteAll() }
}

private actor AlertEntityTransport: HTTPTransport {
    var paths: [String] = []
    var active = true
    let start = Date()
    func setActive(_ value: Bool) { active = value }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        paths.append(request.url.path)
        // The household snapshot is larger than the generic 256KiB WebSocket
        // bound. The listener must never depend on fetching this route.
        if request.url.path == "/api/states" {
            return .init(status: 200, body: Data(repeating: 32, count: 440_707))
        }
        guard request.url.path == "/api/states/" + "sensor.notice",
              request.method == "GET", request.maxBytes == 64 * 1024 else { throw ConnectionFailure.validationFailed }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try JSONSerialization.data(withJSONObject: ["entity_id": "sensor.notice",
            "state": active ? "on" : "off", "attributes": ["alert_id": "live-sized-household",
            "started_at": f.string(from: start), "expires_at": f.string(from: start.addingTimeInterval(300))]])
        return .init(status: 200, body: data)
    }
}
