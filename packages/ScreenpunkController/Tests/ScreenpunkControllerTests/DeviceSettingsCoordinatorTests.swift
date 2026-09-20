import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class DeviceSettingsCoordinatorTests: XCTestCase {
    func testConflictIsNotRetriedAndOfflineApplyIsNeverReplayedOnReconnect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = FakeLANDevice(deviceId: "settings-device", name: "Phone")
        let owner = PairingIdentityFactory.make(role: .controller)
        let directory = DeviceDirectory(url: root.appendingPathComponent("devices.json"))
        let coordinator = DeviceCoordinator(directory: directory,
            linkFactory: FakeLANLinkFactory(device: phone, controllerIdentity: owner))
        let request = try coordinator.requestPairing(deviceId: nil, host: phone.host, port: Int(phone.port))
        phone.confirmLocally()
        _ = try coordinator.confirmPairing(deviceId: request.deviceId)
        let mac = try coordinator.fetchDeviceSettings(deviceId: request.deviceId)
        let local = try phone.settingsSnapshot.replacing(with: .init(expectedRevision: mac.revision,
            value: .init(brightness: .init(mode: .fixed, fixedLevel: 0.9))))
        phone.settingsSnapshot = local
        XCTAssertThrowsError(try coordinator.updateDeviceSettings(deviceId: request.deviceId,
            update: .init(expectedRevision: mac.revision, value: .init()))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .conflict)
        }
        XCTAssertEqual(phone.settingsUpdateAttempts, 1, "device conflict is a final verdict, never replayed")
        XCTAssertEqual(directory.get(request.deviceId)?.settingsSnapshot, mac, "failed apply preserves last confirmed snapshot")
        phone.online = false
        XCTAssertThrowsError(try coordinator.updateDeviceSettings(deviceId: request.deviceId,
            update: .init(expectedRevision: local.revision, value: .init())))
        XCTAssertEqual(phone.settingsUpdateAttempts, 1)
        phone.online = true
        let refreshed = try coordinator.fetchDeviceSettings(deviceId: request.deviceId)
        XCTAssertEqual(refreshed, local, "reconnect reads current settings and never queues the failed edit")
        XCTAssertEqual(phone.settingsUpdateAttempts, 1)
        let saved = try coordinator.updateDeviceSettings(deviceId: request.deviceId,
            update: .init(expectedRevision: refreshed.revision, value: .init()))
        XCTAssertEqual(directory.get(request.deviceId)?.settingsSnapshot, saved)
    }

    func testUnpairedControllerCannotFetchOrApplyDeviceSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = FakeLANDevice(deviceId: "settings-device", name: "Phone")
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: root.appendingPathComponent("devices.json")),
            linkFactory: FakeLANLinkFactory(device: phone, controllerIdentity: PairingIdentityFactory.make(role: .controller)))
        XCTAssertThrowsError(try coordinator.fetchDeviceSettings(deviceId: "settings-device"))
        XCTAssertThrowsError(try coordinator.updateDeviceSettings(deviceId: "settings-device",
            update: .init(expectedRevision: phone.settingsSnapshot.revision, value: .init())))
        XCTAssertEqual(phone.settingsUpdateAttempts, 0)
    }
}
