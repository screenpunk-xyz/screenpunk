import Combine
import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class WorkbenchChromeTests: XCTestCase {
    func testLivePreviewCopyAndDiscoveryType() {
        let model = WorkbenchModel(hub: LoopbackDiscovery())
        XCTAssertEqual(model.session.livePreviewLabel, WorkbenchCopy.livePreview)
        XCTAssertEqual(DiscoveryService.type, "_screenpunk._tcp")
        XCTAssertEqual(model.session.drafts.first?.revision, StoredRevision.offlineFixture.revision)
        XCTAssertFalse(NativeChromeHost.ringUsesSystemRed)
    }

    /// Owner view hides the in-process loopback fixture and anything at its
    /// address; the developer toggle brings them back with raw addresses.
    func testOwnerSidebarHidesSimulatorAndDuplicates() {
        let hub = LoopbackDiscovery()
        let model = WorkbenchModel(hub: hub, browsesLAN: false)
        XCTAssertEqual(model.manualHost, "")
        XCTAssertEqual(model.manualPort, "")
        XCTAssertFalse(model.canAddByAddress)

        // The stale default that produced "manual 127.0.0.1:7843".
        _ = hub.addManual(host: "127.0.0.1", port: 7843)
        hub.advertise(AdvertisedDevice(
            deviceId: "phone-local",
            host: "fe80::cc4a:22ff:feda:f1b3%en14",
            port: 53151,
            source: .advertised,
            name: "iPhone"
        ))
        model.refresh()
        XCTAssertEqual(model.session.advertisements.count, 3)

        let owner = model.nearby(developer: false)
        XCTAssertEqual(owner.map(\.title), ["iPhone"])
        XCTAssertEqual(owner.map(\.subtitle), [WorkbenchCopy.onYourNetwork])

        let developer = model.nearby(developer: true)
        XCTAssertEqual(developer.count, 3)
        XCTAssertTrue(developer.contains { $0.subtitle.hasPrefix("loopback · 127.0.0.1:7843") })
    }

    func testSimulatorPairingStaysAvailableButOutOfTheOwnerList() throws {
        let hub = LoopbackDiscovery()
        let model = WorkbenchModel(hub: hub, browsesLAN: false)
        let loopback = try XCTUnwrap(model.session.advertisements.first { $0.source == .loopback })
        model.startPairing(advertised: loopback)
        XCTAssertNil(model.status)
        let device = try XCTUnwrap(model.session.selectedDevice)
        XCTAssertEqual(device.pairingCode, "833492")
        XCTAssertTrue(model.isSimulator(device))
        XCTAssertTrue(model.visibleDevices(developer: false).isEmpty)
        XCTAssertEqual(model.visibleDevices(developer: true).map(\.id), [device.id])
        XCTAssertEqual(model.title(for: device), "Loopback iPhone")

        model.confirmPairing()
        XCTAssertNil(model.status)
        XCTAssertNil(model.session.selectedDevice?.pairingCode)
        // A known device is not offered again under Add Device; Pair Again covers it.
        XCTAssertTrue(model.nearby(developer: false).isEmpty)
        XCTAssertNotNil(model.repairAdvertisement(for: device))
    }

    func testAddByAddressRejectsBlankAndRecordsTheEntryOtherwise() {
        let hub = LoopbackDiscovery()
        let model = WorkbenchModel(hub: hub, browsesLAN: false)
        XCTAssertFalse(model.addByAddress(pair: false))
        XCTAssertEqual(model.status, WorkbenchCopy.invalidAddress)
        XCTAssertFalse(model.session.advertisements.contains { $0.source == .manual })

        model.manualHost = " [fe80::1%en0] "
        model.manualPort = "0"
        XCTAssertFalse(model.canAddByAddress)

        model.manualHost = "192.0.2.10"
        model.manualPort = "53151"
        XCTAssertTrue(model.canAddByAddress)
        XCTAssertTrue(model.addByAddress(pair: false))
        XCTAssertNil(model.status)
        XCTAssertTrue(model.session.advertisements.contains { $0.source == .manual && $0.host == "192.0.2.10" })
        XCTAssertEqual(model.manualHost, "")
        XCTAssertEqual(model.manualPort, "")
        XCTAssertEqual(model.nearby(developer: false).map(\.title), ["192.0.2.10:53151"])
    }

    func testPollDiscoveryOnlyWritesOnChange() {
        let hub = LoopbackDiscovery()
        let model = WorkbenchModel(hub: hub, browsesLAN: false)
        var changes = 0
        let token = model.$session.dropFirst().sink { _ in changes += 1 }
        defer { token.cancel() }
        model.pollDiscovery()
        XCTAssertEqual(changes, 0)
        hub.advertise(AdvertisedDevice(deviceId: "new", host: "192.0.2.11", port: 1, source: .advertised))
        model.pollDiscovery()
        XCTAssertEqual(changes, 1)
        model.pollDiscovery()
        XCTAssertEqual(changes, 1)
    }

    func testSidebarGeometryFollowsTheGuide() {
        XCTAssertGreaterThanOrEqual(WorkbenchSidebarLayout.pairButtonMinimumHeight, 24)
        XCTAssertEqual(WorkbenchModel.discoveryPollSeconds, 2)
        XCTAssertEqual(WorkbenchSidebarLayout.developerViewKey, "workbench.developerView")
    }

    func testUnlinkClearsDeviceRuntime() throws {
        var runtime = DeviceRuntime(
            identity: PairingIdentityFactory.make(role: .device, bytes: [UInt8](repeating: 1, count: 32)),
            profile: DeviceProfile(deviceId: "p", name: "p"),
            advertisement: AdvertisedDevice(deviceId: "p", host: "127.0.0.1", port: 1, source: .loopback)
        )
        runtime.activeRevision = StoredRevision.offlineFixture.revision
        runtime.unlink()
        XCTAssertNil(runtime.activeRevision)
        XCTAssertFalse(runtime.isPaired)
    }
}
