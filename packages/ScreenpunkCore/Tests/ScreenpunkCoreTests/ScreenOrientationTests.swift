import XCTest
@testable import ScreenpunkCore

final class ScreenOrientationTests: XCTestCase {
    func testLegacyProfileDecodesWithoutInventingModel() throws {
        let data = Data(#"{"deviceId":"old-phone","name":"Phone","orientation":"portrait","width":390,"height":844}"#.utf8)
        let legacy = try JSONDecoder().decode(DeviceProfile.self, from: data)
        XCTAssertNil(legacy.model)
        let known = DeviceProfile(deviceId: "new-phone", name: "Desk", width: 375, height: 812, model: "iPhone 13 mini")
        XCTAssertEqual(try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(known)), known)
    }

    func testOrientationActivatesAtomicallyAndRejectsDifferentDeviceSize() throws {
        let owner = PairingIdentityFactory.make(role: .controller)
        var phone = DeviceRuntime(identity: PairingIdentityFactory.make(role: .device), profile: DeviceProfile(deviceId: "phone", name: "Phone"), advertisement: AdvertisedDevice(deviceId: "phone", host: "localhost", port: 7843, source: .advertised))
        phone.pairing.owner = owner
        var screen = StoredRevision.offlineFixture
        screen.orientation = .landscape; screen.width = 844; screen.height = 390
        func deployment(_ id: String) -> DeploymentRecord { DeploymentRecord(deploymentId: id, revision: screen.revision, dashboardId: screen.dashboardId, deviceId: "phone", phase: .queued) }
        let failed = try phone.receiveDeployment(deployment("failed"), revision: screen, failAt: .activating)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(phone.profile.orientation, .portrait)
        XCTAssertNil(phone.activeRevision)
        let activated = try phone.receiveDeployment(deployment("success"), revision: screen)
        XCTAssertEqual(activated.phase, .active)
        XCTAssertEqual(phone.profile.orientation, .landscape)
        screen.width = 1024
        XCTAssertEqual(try phone.receiveDeployment(deployment("bad-size"), revision: screen).phase, .failed)
        XCTAssertEqual(phone.profile.width, 844)
    }
}
