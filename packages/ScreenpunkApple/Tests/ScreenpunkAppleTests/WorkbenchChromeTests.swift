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
