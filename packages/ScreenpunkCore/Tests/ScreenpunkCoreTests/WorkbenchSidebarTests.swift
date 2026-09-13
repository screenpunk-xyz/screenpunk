import XCTest
@testable import ScreenpunkCore

final class WorkbenchSidebarTests: XCTestCase {
    private let owner = PairingIdentityFactory.make(role: .controller, bytes: [UInt8](repeating: 0x02, count: 32))

    private let loopback = AdvertisedDevice(deviceId: "phone-1", host: "127.0.0.1", port: 7843, source: .loopback)
    private let manualDuplicate = AdvertisedDevice(
        deviceId: "manual:127.0.0.1:7843", host: "127.0.0.1", port: 7843, source: .manual
    )
    private let phone = AdvertisedDevice(
        deviceId: "phone-local",
        host: "fe80::cc4a:22ff:feda:f1b3%en14",
        port: 53151,
        source: .advertised,
        name: "iPhone"
    )

    private func paired(_ id: String, name: String, code: String? = nil) -> PairedDevice {
        PairedDevice(profile: DeviceProfile(deviceId: id, name: name), owner: owner, pairingCode: code)
    }

    // The exact sidebar Guy saw: loopback fixture, a manual duplicate of its
    // address, and the real phone as a raw IPv6 link-local.
    func testOwnerViewShowsOnlyTheRealPhoneByName() {
        let ads = [manualDuplicate, loopback, phone]
        let nearby = WorkbenchSidebar.nearby(advertisements: ads, devices: [], developer: false)
        XCTAssertEqual(nearby.map(\.id), ["phone-local"])
        XCTAssertEqual(nearby[0].title, "iPhone")
        XCTAssertEqual(nearby[0].subtitle, WorkbenchCopy.onYourNetwork)
        XCTAssertFalse(nearby[0].title.contains("fe80"))
        XCTAssertFalse(nearby[0].subtitle.contains("fe80"))
    }

    func testDeveloperViewShowsEverythingWithRawAddresses() {
        let ads = [manualDuplicate, loopback, phone]
        let nearby = WorkbenchSidebar.nearby(advertisements: ads, devices: [], developer: true)
        XCTAssertEqual(nearby.count, 3)
        XCTAssertEqual(nearby.map(\.advertisement.source), [.advertised, .manual, .loopback])
        XCTAssertEqual(nearby[0].subtitle, "advertised · [fe80::cc4a:22ff:feda:f1b3%en14]:53151")
        XCTAssertEqual(nearby[2].title, WorkbenchCopy.simulatorDevice)
    }

    func testPairedDevicesLeaveNearbyAndSimulatorLeavesDevices() {
        let devices = [paired("phone-1", name: "Loopback iPhone"), paired("phone-local", name: "phone-local")]
        let ads = [loopback, phone]
        XCTAssertTrue(WorkbenchSidebar.nearby(advertisements: ads, devices: devices, developer: false).isEmpty)

        let visible = WorkbenchSidebar.visibleDevices(devices, advertisements: ads, developer: false)
        XCTAssertEqual(visible.map(\.id), ["phone-local"])
        XCTAssertEqual(
            WorkbenchSidebar.visibleDevices(devices, advertisements: ads, developer: true).count, 2
        )
        XCTAssertEqual(WorkbenchSidebar.advertisement(for: devices[1], in: ads)?.deviceId, "phone-local")
        XCTAssertNil(WorkbenchSidebar.advertisement(for: paired("gone", name: "gone"), in: ads))
    }

    func testIdentifierNamesFallBackToHumanCopy() {
        let ads = [loopback]
        XCTAssertEqual(
            WorkbenchSidebar.title(for: paired("phone-local", name: "phone-local"), advertisements: ads),
            WorkbenchCopy.pairedDevice
        )
        XCTAssertEqual(
            WorkbenchSidebar.title(for: paired("x", name: "fe80::1%en0"), advertisements: ads),
            WorkbenchCopy.pairedDevice
        )
        XCTAssertEqual(
            WorkbenchSidebar.title(for: paired("x", name: "192.168.1.20"), advertisements: ads),
            WorkbenchCopy.pairedDevice
        )
        XCTAssertEqual(
            WorkbenchSidebar.title(for: paired("phone-local", name: "Guy's iPhone"), advertisements: ads),
            "Guy's iPhone"
        )
        XCTAssertEqual(
            WorkbenchSidebar.title(for: paired("phone-1", name: "Loopback iPhone"), advertisements: ads),
            "Loopback iPhone"
        )
        var unnamed = phone
        unnamed.name = nil
        XCTAssertEqual(WorkbenchSidebar.title(for: unnamed), WorkbenchCopy.nearbyDevice)
        XCTAssertEqual(WorkbenchSidebar.title(for: manualDuplicate), "127.0.0.1:7843")
    }

    func testAdvertisedNameIsSanitizedAndOptionalOnTheWire() throws {
        let noisy = AdvertisedDevice(
            deviceId: "d", host: "10.0.0.8", port: 1, source: .advertised, name: "  Guy's\u{0}iPad\n "
        )
        XCTAssertEqual(noisy.name, "Guy'siPad")
        XCTAssertNil(AdvertisedDevice(deviceId: "d", host: "h", port: 1, source: .advertised, name: "   ").name)
        XCTAssertEqual(
            DeviceDisplayName.sanitize(String(repeating: "a", count: 80))?.count,
            DeviceDisplayName.maxLength
        )

        let hello = LANHello(role: .device, deviceId: "phone-local", pinHex: "00", name: "iPhone")
        let json = try LANCodec.encodePayload(hello)
        XCTAssertEqual(try LANCodec.decodePayload(LANHello.self, json: json), hello)

        // A peer that predates the field still decodes; the name is simply absent.
        let legacy = #"{"role":"device","deviceId":"phone-local","pinHex":"00","protocolMajor":1}"#
        let decoded = try LANCodec.decodePayload(LANHello.self, json: legacy)
        XCTAssertNil(decoded.name)
        XCTAssertEqual(decoded.deviceId, "phone-local")
        XCTAssertFalse(json.contains("sk-"))
    }

    func testDeviceSubtitleReadsAsStatusNotFlags() {
        var device = paired("phone-local", name: "iPhone")
        XCTAssertEqual(WorkbenchSidebar.subtitle(for: device), "Ready · Portrait · No dashboard")
        device.activeRevision = StoredRevision.offlineFixture.revision
        XCTAssertEqual(WorkbenchSidebar.subtitle(for: device), "Ready · Portrait · Offline fixture")
        device.reachable = false
        device.profile.apply(orientation: .landscape)
        XCTAssertEqual(WorkbenchSidebar.subtitle(for: device), "Unreachable · Landscape · Offline fixture")
        device.pairingCode = "833492"
        XCTAssertEqual(WorkbenchSidebar.subtitle(for: device), WorkbenchCopy.pairingInProgress)
    }

    func testManualAddressParsing() {
        XCTAssertEqual(WorkbenchSidebar.normalizeHost(" [fe80::1%en0] "), "fe80::1%en0")
        XCTAssertEqual(WorkbenchSidebar.normalizeHost("192.168.1.20"), "192.168.1.20")
        XCTAssertNil(WorkbenchSidebar.normalizeHost("   "))
        XCTAssertEqual(WorkbenchSidebar.parsePort(" 53151 "), 53151)
        XCTAssertNil(WorkbenchSidebar.parsePort(""))
        XCTAssertNil(WorkbenchSidebar.parsePort("0"))
        XCTAssertNil(WorkbenchSidebar.parsePort("70000"))
        XCTAssertNil(WorkbenchSidebar.parsePort("7,843"))
    }

    func testManualEntryDedupesAgainstAdvertisedSameAddress() {
        let manual = AdvertisedDevice(
            deviceId: "manual:10.0.0.8:53151", host: "10.0.0.8", port: 53151, source: .manual
        )
        let advertised = AdvertisedDevice(
            deviceId: "phone-local", host: "10.0.0.8", port: 53151, source: .advertised, name: "iPad"
        )
        let nearby = WorkbenchSidebar.nearby(advertisements: [manual, advertised], devices: [], developer: false)
        XCTAssertEqual(nearby.map(\.id), ["phone-local"])
        XCTAssertEqual(nearby[0].title, "iPad")

        let alone = WorkbenchSidebar.nearby(advertisements: [manual], devices: [], developer: false)
        XCTAssertEqual(alone.map(\.title), ["10.0.0.8:53151"])
        XCTAssertEqual(alone[0].subtitle, WorkbenchCopy.addedByAddress)
    }
}
