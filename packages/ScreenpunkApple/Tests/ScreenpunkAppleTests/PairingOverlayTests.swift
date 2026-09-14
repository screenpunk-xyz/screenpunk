import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class PairingOverlayTests: XCTestCase {
    func testPairingOverActiveScreenCanCancelExpireAndConfirmWithoutReplacingContent() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "pair-overlay-device")
        let ownerIdentity = try TLSIdentity.make(role: .controller, commonName: "pair-overlay-owner")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let revision = StoredRevision.offlineFixture
        try store.save(.init(owner: ownerIdentity.pairingIdentity, activeRevision: revision.revision, activeStoredRevision: revision,
            lastDeployment: .init(deploymentId: "kept-deploy", revision: revision.revision, dashboardId: revision.dashboardId,
                                  deviceId: "overlay-phone", phase: .active)))
        let files = try PackageAssetStore.bundledOfflineFixture().assets.values.map { (path: $0.path, data: $0.data) }
        try store.activatePackage(staged: store.stagePackage(files))
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(.init(dashboardId: revision.dashboardId, connectionId: "home", provisioningId: "unchanged",
            revision: revision.revision, origin: "https://ha.example", token: "fixture-token"), owner: PeerPin.hex(ownerIdentity.pin))
        let savedGrant = try vault.record(owner: PeerPin.hex(ownerIdentity.pin), revision: revision.revision)
        let clock = PairingTestClock()
        let server = DeviceLANServer(runtime: .init(identity: deviceIdentity.pairingIdentity,
            profile: .init(deviceId: "overlay-phone", name: "iPhone"),
            advertisement: .init(deviceId: "overlay-phone", host: "127.0.0.1", port: 0, source: .advertised)),
            identity: deviceIdentity, clock: clock, store: store, homeAssistantVault: vault)
        try server.start()
        defer { server.stop() }
        let client = ControllerLANClient(identity: ownerIdentity)
        defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port)
        _ = try client.hello()
        let originalAssets = server.activePackage?.assets
        func assertContentPreserved() throws {
            XCTAssertEqual(server.runtime.activeRevision, revision.revision)
            XCTAssertEqual(server.runtime.lastDeployment?.deploymentId, "kept-deploy")
            XCTAssertEqual(server.runtime.pairing.owner, ownerIdentity.pairingIdentity)
            XCTAssertEqual(server.activePackage?.assets["index.html"]?.data, originalAssets?["index.html"]?.data)
            XCTAssertEqual(try vault.record(owner: PeerPin.hex(ownerIdentity.pin), revision: revision.revision), savedGrant)
        }
        let first = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        XCTAssertEqual(server.pairingCode, first.code, "Pending code must coexist with the active screen for overlay presentation")
        try assertContentPreserved()
        server.cancelPairing()
        XCTAssertNil(server.pairingCode)
        XCTAssertNil(server.runtime.pairing.session)
        try assertContentPreserved()
        _ = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        clock.advance(PairingLimits.expirySeconds + 1)
        server.expirePairingIfNeeded()
        XCTAssertNil(server.pairingCode)
        XCTAssertThrowsError(try server.confirmLocally())
        try assertContentPreserved()
        let final = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        try server.confirmLocally()
        XCTAssertTrue(server.awaitingControllerConfirm)
        XCTAssertEqual(server.pairingCode, final.code)
        try client.confirmPairing(code: final.code)
        XCTAssertNil(server.pairingCode)
        XCTAssertFalse(server.awaitingControllerConfirm)
        try assertContentPreserved()
    }
}

private final class PairingTestClock: PairingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}
