#if os(macOS)
import XCTest
import ScreenpunkCore
@testable import ScreenpunkController
final class ControllerCloudDeviceIdentityTests: XCTestCase {
    func testOnlyAuthenticatedStatusAssociatesCloudInstallationAndNamesNeverMatch() throws {
        let root = URL(fileURLWithPath:"/private/tmp/sp-cloud-device-id-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let identity = PairingIdentityFactory.make(role:.controller)
        let fixture = FakeLANDevice(deviceId:"fixture",name:"Same device name")
        let installation = UUID().uuidString.lowercased(); fixture.cloudInstallationId = installation
        let coordinator = DeviceCoordinator(directory:DeviceDirectory(url:root.appendingPathComponent("devices.json")),linkFactory:FakeLANLinkFactory(device:fixture,controllerIdentity:identity))
        _ = try coordinator.requestPairing(deviceId:nil,host:fixture.host,port:Int(fixture.port)); fixture.confirmLocally()
        let paired = try coordinator.confirmPairing(deviceId:"fixture")
        XCTAssertNil(paired.cloudInstallationId,"Pairing/advertisement names provide no installation evidence")
        let authenticated = try coordinator.device("fixture",probe:true)
        let read = WorkbenchDeviceRead(authenticated,currentIdentity:identity)
        XCTAssertTrue(ControllerCloudDeviceIdentity.matches(local:read,installationId:installation))
        XCTAssertFalse(ControllerCloudDeviceIdentity.matches(local:read,installationId:UUID().uuidString.lowercased()))
        XCTAssertFalse(ControllerCloudDeviceIdentity.matches(local:read,installationId:"Same device name"))
        let otherController = WorkbenchDeviceRead(authenticated,currentIdentity:PairingIdentityFactory.make(role:.controller))
        XCTAssertNil(otherController.cloudInstallationId)
        fixture.controllerApproved = true; fixture.localControllerPinHex = PeerPin.hex(identity.publicKey)
        let approved = try coordinator.device("fixture", probe: true)
        XCTAssertEqual(approved.approvedControllerIdentity, identity)
        var secondary = approved; secondary.device.owner = PairingIdentityFactory.make(role: .controller)
        XCTAssertTrue(WorkbenchDeviceRead(secondary, currentIdentity: identity).ownerMatchesCurrent)
        fixture.localControllerPinHex = PeerPin.hex(PairingIdentityFactory.make(role: .controller).publicKey)
        let wrongPeer = try coordinator.device("fixture", probe: true)
        XCTAssertNil(wrongPeer.approvedControllerIdentity)
        XCTAssertFalse(WorkbenchDeviceRead(wrongPeer, currentIdentity: identity).ownerMatchesCurrent)
        fixture.controllerApproved = false; fixture.localControllerPinHex = PeerPin.hex(identity.publicKey)
        let revoked = try coordinator.device("fixture", probe: true)
        XCTAssertFalse(WorkbenchDeviceRead(revoked, currentIdentity: identity).ownerMatchesCurrent)
        fixture.controllerApproved = nil; fixture.localControllerPinHex = nil
        fixture.cloudInstallationId = "name-or-advertised-id"
        let invalid = try coordinator.device("fixture",probe:true); XCTAssertNil(invalid.cloudInstallationId)
        fixture.cloudInstallationId = nil
        let disconnected = try coordinator.device("fixture",probe:true); XCTAssertNil(disconnected.cloudInstallationId)
        let encoded = try JSONEncoder().encode(disconnected)
        XCTAssertNil(try JSONDecoder().decode(PairedDeviceRecord.self,from:encoded).cloudInstallationId)
    }
}
#endif
