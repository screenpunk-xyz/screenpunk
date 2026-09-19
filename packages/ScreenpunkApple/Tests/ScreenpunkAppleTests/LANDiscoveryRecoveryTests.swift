import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

#if canImport(Network) && canImport(Security)
final class LANDiscoveryRecoveryTests: XCTestCase {
    func testBrowserRelaunchFindsRunningDeviceAndNewListener() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "discovery-recovery")
        let id = "recovery-\(UUID().uuidString.prefix(8))"
        let runtime = DeviceRuntime(
            identity: identity.pairingIdentity,
            profile: DeviceProfile(deviceId: id, name: id),
            advertisement: AdvertisedDevice(deviceId: id, host: "127.0.0.1", port: 0, source: .advertised)
        )
        let server = DeviceLANServer(runtime: runtime, identity: identity)
        try server.start()
        defer { server.stop() }
        let hub = LoopbackDiscovery()
        let browser = LANAdvertisementBrowser(hub: hub)
        defer { browser.stop() }
        browser.start()
        try eventually { hub.browse().contains { $0.name == id && $0.port == Int(server.port) } }

        browser.stop()
        try eventually { hub.browse().isEmpty }
        browser.start()
        try eventually { hub.browse().contains { $0.name == id && $0.port == Int(server.port) } }

        server.stop()
        try server.start()
        try eventually { hub.browse().contains { $0.name == id && $0.port == Int(server.port) } }
        browser.stop()
        try eventually { hub.browse().isEmpty }
    }

    private func eventually(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("Discovery did not recover before its deadline")
        throw TransferFailure.deviceOffline
    }
}
#endif
