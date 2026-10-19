import Darwin
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
        let server = try DeviceLANServer(management: testManagementContext(), runtime: runtime, identity: identity)
        try server.start()
        defer { server.stop() }
        let hub = LoopbackDiscovery()
        let browser = LANAdvertisementBrowser(hub: hub)
        defer { browser.stop() }
        browser.start()
        try eventually { self.found(id, port: Int(server.port), in: hub) }

        browser.stop()
        try eventually { hub.browse().isEmpty }
        browser.start()
        try eventually { self.found(id, port: Int(server.port), in: hub) }

        server.stop()
        try server.start()
        try eventually { self.found(id, port: Int(server.port), in: hub) }
        browser.stop()
        try eventually { hub.browse().isEmpty }
    }

    /// DNS-SD address decoding used by discovery. These cases are pure so they
    /// do not open a socket to the TLS listener.
    func testBonjourResolvedAddressDecodesServicePortAndHost() {
        XCTAssertEqual(BonjourResolvedAddress.normalizeHost("iPad.local."), "iPad.local")
        XCTAssertEqual(BonjourResolvedAddress.normalizeHost("iPad.local"), "iPad.local")
        XCTAssertEqual(BonjourResolvedAddress.normalizeHost("192.0.2.10"), "192.0.2.10")
        XCTAssertNil(BonjourResolvedAddress.normalizeHost("."))
        XCTAssertNil(BonjourResolvedAddress.normalizeHost(" "))
        XCTAssertEqual(BonjourResolvedAddress.port(networkOrder: UInt16(7843).bigEndian), 7843)
        XCTAssertEqual(BonjourResolvedAddress.port(networkOrder: 0), 0)
    }

    func testBonjourResolvedAddressFormatsSocketAddressWithoutConnecting() {
        var v4 = sockaddr_in()
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        v4.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, "192.0.2.10", &v4.sin_addr), 1)
        let v4Described = withUnsafeBytes(of: &v4) { raw -> BonjourResolvedAddress.Candidate? in
            guard let base = raw.baseAddress else { return nil }
            return BonjourResolvedAddress.copy(base.assumingMemoryBound(to: sockaddr.self))
                .flatMap(BonjourResolvedAddress.describe)
        }
        XCTAssertEqual(v4Described, BonjourResolvedAddress.Candidate(host: "192.0.2.10", family: Int(AF_INET)))

        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "fe80::1", &v6.sin6_addr), 1)
        let v6Described = withUnsafeBytes(of: &v6) { raw -> BonjourResolvedAddress.Candidate? in
            guard let base = raw.baseAddress else { return nil }
            return BonjourResolvedAddress.copy(base.assumingMemoryBound(to: sockaddr.self))
                .flatMap(BonjourResolvedAddress.describe)
        }
        XCTAssertEqual(v6Described?.family, Int(AF_INET6))
        XCTAssertEqual(v6Described?.host.lowercased().hasPrefix("fe80:"), true)
        XCTAssertEqual(v6Described?.host.contains("%"), false)
    }

    func testBonjourResolvedAddressPrefersRoutableHostAndKeepsScope() {
        let addresses = [
            BonjourResolvedAddress.Candidate(host: "fe80::1%en0", family: Int(AF_INET6)),
            BonjourResolvedAddress.Candidate(host: "169.254.1.1", family: Int(AF_INET)),
            BonjourResolvedAddress.Candidate(host: "192.0.2.10", family: Int(AF_INET)),
            BonjourResolvedAddress.Candidate(host: "2001:db8::1", family: Int(AF_INET6)),
        ]
        XCTAssertEqual(BonjourResolvedAddress.pick(addresses), "192.0.2.10")
        XCTAssertEqual(
            BonjourResolvedAddress.pick([addresses[0], addresses[3]]),
            "2001:db8::1"
        )
        XCTAssertEqual(BonjourResolvedAddress.pick([addresses[0]]), "fe80::1%en0")
        XCTAssertNil(BonjourResolvedAddress.pick([]))
        XCTAssertEqual(BonjourResolvedAddress.appendingScope("fe80::1", scope: 0), "fe80::1")
        XCTAssertEqual(BonjourResolvedAddress.appendingScope("fe80::1%en0", scope: 1), "fe80::1%en0")
        XCTAssertEqual(BonjourResolvedAddress.appendingScope("fe80::1", scope: 99999), "fe80::1%99999")
    }

    private func found(_ name: String, port: Int, in hub: LoopbackDiscovery) -> Bool {
        hub.browse().contains { $0.name == name && $0.port == port && $0.host.isEmpty == false }
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
