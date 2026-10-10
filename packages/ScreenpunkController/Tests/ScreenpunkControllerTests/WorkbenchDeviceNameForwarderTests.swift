import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private final class FakeDeviceNamePort: WorkbenchDeviceNamePort {
    var snapshot = DeviceSettingsSnapshot(revision: "before",
        value: DeviceSettings(displayName: "Old",
            brightness: DeviceBrightnessSettings(mode: .fixed, fixedLevel: 0.3)))
    var updateCount = 0
    var seenRevision: String?
    var seenValue: DeviceSettings?
    var stale = false
    var corruptReply = false

    func deviceSettings(_ deviceId: String) throws -> DeviceSettingsSnapshot {
        XCTAssertEqual(deviceId, "device-a")
        return snapshot
    }
    func updateDeviceSettings(_ deviceId: String, expectedRevision: String,
                              value: DeviceSettings) throws -> DeviceSettingsSnapshot {
        updateCount += 1
        seenRevision = expectedRevision; seenValue = value
        if stale { throw DeviceSettingsFailure.conflict }
        snapshot = DeviceSettingsSnapshot(revision: "after", value: value)
        if corruptReply { return DeviceSettingsSnapshot(revision: "after", value: .init()) }
        return snapshot
    }
}

final class WorkbenchDeviceNameForwarderTests: XCTestCase {
    func testRenameUsesExactSettingsRevisionAndPreservesOtherSettings() throws {
        let fake = FakeDeviceNamePort()
        let after = try WorkbenchDeviceNameForwarder.rename(port: fake,
            deviceId: "device-a", rawName: "  Kitchen  ")
        XCTAssertEqual(fake.seenRevision, "before")
        XCTAssertEqual(fake.seenValue?.brightness.fixedLevel, 0.3)
        XCTAssertEqual(after.value.displayName, "Kitchen")
        XCTAssertEqual(fake.updateCount, 1)
    }

    func testStaleRevisionIsNotRetried() {
        let fake = FakeDeviceNamePort(); fake.stale = true
        XCTAssertThrowsError(try WorkbenchDeviceNameForwarder.rename(port: fake,
            deviceId: "device-a", rawName: "Kitchen")) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .conflict)
        }
        XCTAssertEqual(fake.updateCount, 1)
    }

    func testInvalidNameAndUnexpectedReplyFailClosed() {
        let fake = FakeDeviceNamePort()
        XCTAssertThrowsError(try WorkbenchDeviceNameForwarder.rename(port: fake,
            deviceId: "device-a", rawName: "\n")) {
            XCTAssertEqual($0 as? WorkbenchDeviceNameForwarder.Failure, .invalidName)
        }
        XCTAssertEqual(fake.updateCount, 0)
        fake.corruptReply = true
        XCTAssertThrowsError(try WorkbenchDeviceNameForwarder.rename(port: fake,
            deviceId: "device-a", rawName: "Kitchen")) {
            XCTAssertEqual($0 as? WorkbenchDeviceNameForwarder.Failure, .outcomeUnknown)
        }
        XCTAssertEqual(fake.updateCount, 1)
    }
}
#endif
