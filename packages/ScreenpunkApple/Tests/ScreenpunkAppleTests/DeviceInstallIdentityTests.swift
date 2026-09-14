import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceInstallIdentityTests: XCTestCase {
    func testIdentityIsStableDistinctAndBonjourSafe() {
        let phone = [UInt8](repeating: 1, count: 32)
        let tablet = [UInt8](repeating: 2, count: 32)
        let id = DeviceInstallIdentity.deviceID(for: phone)
        XCTAssertEqual(id, DeviceInstallIdentity.deviceID(for: phone))
        XCTAssertNotEqual(id, DeviceInstallIdentity.deviceID(for: tablet))
        XCTAssertEqual(id.count, 39)
        XCTAssertNotNil(id.range(of: "^device-[a-f0-9]{32}$", options: .regularExpression))
    }

    func testUpgradePreservesPairingPackageAndHomeAssistantAcrossRelaunch() async throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "device-migration")
        let owner = PairingIdentityFactory.make(role: .controller)
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let saved = StoredRevision.offlineFixture
        let record = DeploymentRecord(deploymentId: "existing-deploy", revision: saved.revision,
                                      dashboardId: saved.dashboardId, deviceId: "phone-local", phase: .active)
        try store.save(.init(owner: owner, activeRevision: saved.revision, activeStoredRevision: saved, lastDeployment: record))
        let files = try PackageAssetStore.bundledOfflineFixture().assets.values.map { (path: $0.path, data: $0.data) }
        try store.activatePackage(staged: store.stagePackage(files))
        let credentials = MemoryCredentialStore()
        let vault = HomeAssistantDeviceVault(store: credentials)
        let config = HomeAssistantProvisioning(dashboardId: saved.dashboardId, connectionId: "ha", provisioningId: "existing-grant",
            revision: saved.revision, origin: "https://ha.example", token: "fixture-token")
        try vault.provision(config, owner: PeerPin.hex(owner.publicKey))
        let generation = try vault.record(owner: PeerPin.hex(owner.publicKey), revision: saved.revision).generation

        func makeServer(_ id: String) -> DeviceLANServer {
            let runtime = DeviceRuntime(identity: deviceIdentity.pairingIdentity,
                profile: .init(deviceId: id, name: "iPad"),
                advertisement: .init(deviceId: id, host: "127.0.0.1", port: 0, source: .advertised))
            return DeviceLANServer(runtime: runtime, identity: deviceIdentity, store: store, homeAssistantVault: vault)
        }
        let upgraded = makeServer("phone-local")
        let stableID = DeviceInstallIdentity.deviceID(for: deviceIdentity.pin)
        XCTAssertEqual(upgraded.runtime.profile.deviceId, stableID)
        XCTAssertEqual(upgraded.runtime.advertisement.deviceId, stableID)
        XCTAssertEqual(upgraded.runtime.pairing.owner, owner)
        XCTAssertEqual(upgraded.runtime.identity, deviceIdentity.pairingIdentity)
        XCTAssertEqual(upgraded.runtime.activeRevision, saved.revision)
        XCTAssertEqual(upgraded.runtime.lastDeployment?.deploymentId, record.deploymentId)
        XCTAssertEqual(upgraded.runtime.lastDeployment?.deviceId, stableID)
        XCTAssertEqual(store.load()?.lastDeployment?.deviceId, stableID)
        XCTAssertEqual(store.load()?.activeStoredRevision, saved)
        XCTAssertEqual(upgraded.activePackage?.assets["index.html"]?.data, files.first { $0.path == "index.html" }?.data)
        XCTAssertEqual(try vault.record(owner: PeerPin.hex(owner.publicKey), revision: saved.revision).generation, generation)
        let reloaded = makeServer(DeviceInstallIdentity.pendingID)
        XCTAssertEqual(reloaded.runtime.profile.deviceId, stableID)
        XCTAssertEqual(reloaded.runtime.pairing.owner, owner)
        XCTAssertEqual(reloaded.runtime.activeRevision, saved.revision)
        XCTAssertEqual(try vault.record(owner: PeerPin.hex(owner.publicKey), revision: saved.revision).configuration, config)
    }

    func testFreshDevicesDifferAndExplicitFixtureIDsRemainUnchanged() throws {
        let one = try TLSIdentity.make(role: .device, commonName: "fresh-phone")
        let two = try TLSIdentity.make(role: .device, commonName: "fresh-ipad")
        func server(_ identity: TLSIdentityMaterial, id: String = DeviceInstallIdentity.pendingID) -> DeviceLANServer {
            DeviceLANServer(runtime: .init(identity: identity.pairingIdentity, profile: .init(deviceId: id, name: "Test"),
                advertisement: .init(deviceId: id, host: "127.0.0.1", port: 0, source: .advertised)), identity: identity,
                homeAssistantVault: .init(store: MemoryCredentialStore()))
        }
        let phone = server(one), tablet = server(two)
        XCTAssertNotEqual(phone.runtime.profile.deviceId, tablet.runtime.profile.deviceId)
        XCTAssertFalse(phone.runtime.isPaired)
        XCTAssertNil(tablet.runtime.activeRevision)
        XCTAssertEqual(server(one, id: "fixture-device").runtime.profile.deviceId, "fixture-device")
    }
}
