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
        let server = DeviceLANServer(runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity: owner)
        defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port, pinnedDevice: device.pin)
        XCTAssertTrue(try client.hello().capabilities?.contains("screen-set-v1") == true)
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
        let restored = DeviceLANServer(runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
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
        let afterCrash = DeviceLANServer(runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertEqual(afterCrash.runtime.activeRevision, "second-revision")
        XCTAssertEqual(afterCrash.screenSet?.grantSet, generation)
        let stateBytes = try Data(contentsOf: store.stateURL)
        XCTAssertFalse(String(decoding: stateBytes, as: UTF8.self).contains("first-token"))
        XCTAssertFalse(String(decoding: stateBytes, as: UTF8.self).contains("second-token"))

        var single = body; single.deploymentId = "single"; single.screens.removeLast()
        _ = try client.deployScreenSet(single)
        XCTAssertEqual(server.screenSet?.screens.count, 1)
        XCTAssertThrowsError(try vault.record(owner: pin, revision: "second-revision", grantSet: generation))
        server.unlink()
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
        let server = DeviceLANServer(runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
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
        let restored = DeviceLANServer(runtime: runtime, identity: device, store: store, homeAssistantVault: vault)
        XCTAssertNotNil(restored.publicReadSession())
        var invalid = body; invalid.deploymentId = "mismatched-public-grant"
        invalid.screens[0].publicReads?.connections[0].publicHTTP?.origin = "https://unapproved.example.org"
        XCTAssertThrowsError(try client.deployScreenSet(invalid))
        XCTAssertEqual(server.screenSet?.grantSet, generation)
        server.unlink()
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
        let server = DeviceLANServer(runtime: runtime, identity: device, store: store,
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
        let restored = DeviceLANServer(runtime: runtime, identity: device, store: store,
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

    private func makeBody() throws -> LANScreenSetDeployBody {
        let items = ["first", "second"].map { name -> LANScreenSetItem in
            var revision = StoredRevision.offlineFixture
            revision.dashboardId = name; revision.revision = name + "-revision"
            let data = Data("<html>\(name)</html>".utf8)
            return .init(name: name, deployment: .init(deployment: .init(deploymentId: name + "-deploy",
                revision: revision.revision, dashboardId: name, deviceId: "set-phone", phase: .queued), revision: revision,
                files: [.init(path: "index.html", sha256: PeerPin.hex(PeerPin.sha256(data)), dataBase64: data.base64EncodedString())]),
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
