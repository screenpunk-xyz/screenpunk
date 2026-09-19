import XCTest
import ScreenpunkCore
import WebKit
@testable import ScreenpunkApple

final class HomeAssistantDeviceTests: XCTestCase {
    func configuration() -> HomeAssistantProvisioning {
        .init(dashboardId: "screen", connectionId: "connection", provisioningId: "generation", revision: "revision",
              origin: "https://ha.example", token: "fixture-credential")
    }

    func testPermissionAuthorityAndRequestBounds() throws {
        let config = configuration()
        try config.validate()
        XCTAssertEqual(config.permissionMode, "homeAssistantUser")
        XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "all"]))
        XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.a,light.b"]))
        XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "scene.a"]))
        XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.a", "area_id": "all"]))
        XCTAssertThrowsError(try config.authorize(operation: "getStates", parameters: ["Authorization": "override"]))
        XCTAssertThrowsError(try config.authorize(operation: "volumeSet", parameters: ["entity_id": "media_player.a", "volume_level": "nan"]))
        XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.a", "brightness": "256"]))
        let action = try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.newly_authorized", "brightness": "128"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: action.body!) as? [String: Any])
        XCTAssertEqual(body["brightness"] as? Int, 128)
        let states = Data("[{\"entity_id\":\"sensor.new\",\"state\":\"23\"}]".utf8)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: config.filterStates(states)) as? [[String: String]],
                       [["entity_id": "sensor.new", "state": "23"]])
    }

    func testScriptAndSwitchRoutesRejectBroadOrMismatchedTargets() throws {
        let config = configuration()
        for (operation, entity, path) in [("scriptOn", "script.theater_on", "/api/services/script/turn_on"), ("switchOn", "switch.stars", "/api/services/switch/turn_on"), ("switchOff", "switch.screen_led", "/api/services/switch/turn_off")] {
            let action = try config.authorize(operation: operation, parameters: ["entity_id": entity])
            XCTAssertEqual(action.path, path)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: action.body!) as? [String: String])
            XCTAssertEqual(body, ["entity_id": entity])
            XCTAssertThrowsError(try config.authorize(operation: operation, parameters: ["entity_id": "light.game_lights"]))
            XCTAssertThrowsError(try config.authorize(operation: operation, parameters: ["entity_id": entity, "area_id": "basement"]))
            XCTAssertThrowsError(try config.authorize(operation: operation, parameters: ["entity_id": entity + "," + entity]))
        }
    }

    func testMediaPowerAndRGBControlsAreBounded() throws {
        let config = configuration()
        XCTAssertEqual(try config.authorize(operation: "mediaOn", parameters: ["entity_id": "media_player.denon"]).path, "/api/services/media_player/turn_on")
        XCTAssertEqual(try config.authorize(operation: "mediaOff", parameters: ["entity_id": "media_player.denon"]).path, "/api/services/media_player/turn_off")
        XCTAssertThrowsError(try config.authorize(operation: "mediaOn", parameters: ["entity_id": "switch.denon"]))
        XCTAssertThrowsError(try config.authorize(operation: "mediaOff", parameters: ["entity_id": "media_player.denon", "area_id": "all"]))
        let action = try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.window", "rgb_color": "[255,0,128]", "brightness": "100"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: action.body!) as? [String: Any])
        XCTAssertEqual(body["rgb_color"] as? [Int], [255, 0, 128])
        XCTAssertEqual(body["brightness"] as? Int, 100)
        for invalid in ["[256,0,0]", "[-1,0,0]", "[1,2]", "[1,2,3,4]", "[true,0,0]", "[1.5,0,0]", "null", "{\"r\":255}", "[\"255\",0,0]"] {
            XCTAssertThrowsError(try config.authorize(operation: "lightOn", parameters: ["entity_id": "light.window", "rgb_color": invalid]))
        }
        XCTAssertThrowsError(try config.authorize(operation: "lightOff", parameters: ["entity_id": "light.window", "rgb_color": "[1,2,3]"]))
        XCTAssertThrowsError(try config.authorize(operation: "switchOn", parameters: ["entity_id": "switch.fan", "rgb_color": "[1,2,3]"]))
    }

    func testVaultIsBoundIdempotentAndRejectsInvalidReplacement() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        var config = configuration()
        try vault.provision(config, owner: "owner")
        let generation = try vault.record(owner: "owner", revision: "revision").generation
        try vault.provision(config, owner: "owner")
        XCTAssertEqual(try vault.record(owner: "owner", revision: "revision").generation, generation)
        config.token = "changed"
        XCTAssertThrowsError(try vault.provision(config, owner: "owner"))
        config.provisioningId = "new"; config.token = "bad\r\ntoken"
        XCTAssertThrowsError(try vault.provision(config, owner: "owner"))
        XCTAssertEqual(try vault.record(owner: "owner", revision: "revision").generation, generation)
        XCTAssertThrowsError(try vault.record(owner: "other-owner", revision: "revision"))
        XCTAssertThrowsError(try vault.record(owner: "owner", revision: "other-revision"))
        try vault.revoke()
        XCTAssertThrowsError(try vault.record(owner: "owner", revision: "revision"))
    }

    func testNativeAuthStaleReadsAndNoWriteReplay() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(configuration(), owner: "owner")
        let transport = FixtureHTTP()
        let runtime = HomeAssistantDeviceRuntime(vault: vault, scope: { .init(owner: "owner", revision: "revision", dashboardId: "screen") },
                                                 transport: transport, resolver: FixedResolver(["203.0.113.10"]))
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "lightOn", parameters: ["entity_id": "light.a"])
            XCTFail("Writes require a recent successful state read")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .deviceOffline) }
        let fresh = try await runtime.request(revision: "revision", alias: "home", operation: "getStates", parameters: [:])
        XCTAssertFalse(fresh.stale)
        _ = try await runtime.request(revision: "revision", alias: "home", operation: "lightOn", parameters: ["entity_id": "light.a"])
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].headers["Authorization"], "Bearer fixture-credential")
        XCTAssertFalse(String(decoding: fresh.body, as: UTF8.self).contains("fixture-credential"))
        await transport.setStatus(500)
        let stale = try await runtime.request(revision: "revision", alias: "home", operation: "getStates", parameters: [:])
        XCTAssertTrue(stale.stale)
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "lightOff", parameters: ["entity_id": "light.a"])
            XCTFail("Stale writes must be denied")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .deviceOffline) }
        let afterStale = await transport.requests.count
        XCTAssertEqual(afterStale, 3)
        await transport.setStatus(403)
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "getStates", parameters: [:])
            XCTFail("HA permission denials cannot be hidden by cache")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        try vault.revoke()
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "getStates", parameters: [:])
            XCTFail("Revoked configuration must not run")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
    }
}

private actor FixtureHTTP: HTTPTransport {
    var requests: [AuthorizedHTTPRequest] = []
    var status = 200
    func setStatus(_ value: Int) { status = value }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        return .init(status: status, body: Data("[{\"entity_id\":\"light.a\",\"state\":\"on\"}]".utf8))
    }
}

extension HomeAssistantDeviceTests {
    func testPairedTLSProvisionReceiptScopeAndRevoke() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "ha-contract-device")
        let ownerIdentity = try TLSIdentity.make(role: .controller, commonName: "ha-contract-owner")
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let device = DeviceRuntime(identity: deviceIdentity.pairingIdentity,
            profile: DeviceProfile(deviceId: "ha-phone", name: "HA phone"),
            advertisement: .init(deviceId: "ha-phone", host: "127.0.0.1", port: 0, source: .advertised))
        let server = DeviceLANServer(runtime: device, identity: deviceIdentity, homeAssistantVault: vault)
        try server.start()
        defer { server.stop() }
        let client = ControllerLANClient(identity: ownerIdentity)
        defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port)
        let hello = try client.hello()
        XCTAssertTrue(hello.capabilities?.contains("home-assistant-http-v1") == true)
        var config = configuration()
        config.dashboardId = StoredRevision.offlineFixture.dashboardId
        config.revision = StoredRevision.offlineFixture.revision
        XCTAssertThrowsError(try client.provisionHomeAssistant(config), "Unpaired callers cannot provision")
        let begin = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        try server.confirmLocally()
        try client.confirmPairing(code: begin.code)
        XCTAssertThrowsError(try client.provisionHomeAssistant(config), "Screen must be deployed first")
        let deploy = DeploymentRecord(deploymentId: "ha-deploy", revision: config.revision,
                                      dashboardId: config.dashboardId, deviceId: "ha-phone", phase: .queued)
        let outcome = try client.deploy(.init(deployment: deploy, revision: .offlineFixture, files: LANPackageFiles.offlineFixture()))
        XCTAssertEqual(outcome.phase, .active)
        let receipt = try client.provisionHomeAssistant(config)
        XCTAssertEqual(receipt.deviceId, "ha-phone")
        XCTAssertEqual(receipt.dashboardId, config.dashboardId)
        XCTAssertEqual(receipt.connectionId, config.connectionId)
        XCTAssertEqual(receipt.provisioningId, config.provisioningId)
        XCTAssertTrue(receipt.installed)
        XCTAssertEqual(receipt.reachability, "not_checked")
        XCTAssertFalse(try LANCodec.encodePayload(receipt).contains(config.token))
        XCTAssertEqual(try client.provisionHomeAssistant(config), receipt)
        config.dashboardId = "wrong-screen"
        XCTAssertThrowsError(try client.provisionHomeAssistant(config))
        let saved = try vault.record(owner: PeerPin.hex(ownerIdentity.pin), revision: config.revision)
        XCTAssertEqual(saved.configuration.dashboardId, receipt.dashboardId)
        try client.revokeHomeAssistant()
        XCTAssertThrowsError(try vault.record(owner: PeerPin.hex(ownerIdentity.pin), revision: config.revision))
        config.dashboardId = receipt.dashboardId
        try client.provisionHomeAssistant(config)
        server.unlink()
        XCTAssertThrowsError(try vault.record(owner: PeerPin.hex(ownerIdentity.pin), revision: config.revision))
    }
}

extension HomeAssistantDeviceTests {
    func testGeneralServicesFreshnessPermissionDenialAndNoReplay() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        var config = configuration(); config.schemaVersion = 2
        config.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.a"])]
        try vault.provision(config, owner: "owner")
        let transport = FixtureHTTP()
        let runtime = HomeAssistantDeviceRuntime(vault: vault, scope: { .init(owner: "owner", revision: "revision", dashboardId: "screen") },
            transport: transport, resolver: FixedResolver(["192.168.1.9"]))
        let parameters = ["call": "{\"domain\":\"light\",\"service\":\"turn_on\",\"target\":{\"entity_id\":\"light.a\"},\"serviceData\":{\"rgb_color\":[10,20,30],\"transition\":1.5}}"]
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "callService", parameters: parameters)
            XCTFail("No fresh states")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .deviceOffline) }
        let before = await transport.requests.count; XCTAssertEqual(before, 0)
        _ = try await runtime.request(revision: "revision", alias: "home", operation: "getStates", parameters: [:])
        let result = try await runtime.request(revision: "revision", alias: "home", operation: "callService", parameters: parameters)
        XCTAssertEqual(result.body, Data("null".utf8))
        let sent = await transport.requests
        XCTAssertEqual(sent[1].url.path, "/api/services/light/turn_on")
        XCTAssertEqual(sent[1].method, "POST")
        XCTAssertEqual(sent[1].headers["Authorization"], "Bearer fixture-credential")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].body!) as? [String: Any])
        XCTAssertEqual(body["rgb_color"] as? [Int], [10,20,30])
        await transport.setStatus(403)
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "callService", parameters: parameters)
            XCTFail("HA permission denial")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .permissionRequired) }
        await transport.setStatus(200)
        do {
            _ = try await runtime.request(revision: "revision", alias: "home", operation: "callService", parameters: parameters)
            XCTFail("Denied call must invalidate fresh state")
        } catch { XCTAssertEqual(error as? ConnectionFailure, .deviceOffline) }
        let after = await transport.requests.count; XCTAssertEqual(after, 3, "No automatic retry or replay")
    }
}


extension HomeAssistantDeviceTests {
    @MainActor
    func testBundledSDKCallsNativeServiceFromLocalPackage() async throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        var config = configuration(); config.schemaVersion = 2
        config.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.a"])]
        try vault.provision(config, owner: "owner")
        let transport = FixtureHTTP()
        let runtime = HomeAssistantDeviceRuntime(vault: vault, scope: { .init(owner: "owner", revision: "revision", dashboardId: "screen") },
            transport: transport, resolver: FixedResolver(["203.0.113.10"]))
        let html = Data("<!doctype html><html><body>Bridge fixture</body></html>".utf8)
        let store = PackageAssetStore(assets: ["index.html": PackageAsset(path: "index.html", data: html, mime: "text/html")])
        let loaded = expectation(description: "Local package loaded")
        let coordinator = DashboardWebCoordinator(store: store, homeAssistant: runtime, revision: "revision", onReady: { loaded.fulfill() }, onUnlinkHold: {})
        let view = coordinator.makeWebView()
        await fulfillment(of: [loaded], timeout: 15)
        let script = """
        await screenpunk.connections.request('home', 'getStates', {});
        const result = await screenpunk.homeAssistant.callService({domain:'light',service:'turn_on',target:{entity_id:'light.a'},serviceData:{rgb_color:[2,4,8],transition:0.5}});
        let denied = false;
        try { await screenpunk.homeAssistant.callService({domain:'light',service:'turn_off',target:{entity_id:'light.a'},serviceData:{}}); }
        catch (error) { denied = error.code === 'permission_required'; }
        return JSON.stringify({result, denied, containsCredential: JSON.stringify(screenpunk).includes('fixture-credential')});
        """
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        let text = try XCTUnwrap(raw as? String)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(reply["denied"] as? Bool, true)
        XCTAssertEqual(reply["containsCredential"] as? Bool, false)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].body!) as? [String: Any])
        XCTAssertEqual(body["rgb_color"] as? [Int], [2,4,8])
        view.stopLoading()
        withExtendedLifetime(coordinator) {}
    }
}
