import Foundation
import ScreenpunkCore

#if os(macOS)
protocol WorkbenchDeviceNamePort {
    func deviceSettings(_ deviceId: String) throws -> DeviceSettingsSnapshot
    func updateDeviceSettings(_ deviceId: String, expectedRevision: String,
                              value: DeviceSettings) throws -> DeviceSettingsSnapshot
}

extension WorkbenchBrokerClient: WorkbenchDeviceNamePort {}

/// Forward the old Mac Rename Device action through the broker's device-owned
/// settings CAS. No local pairing-directory write or second device link occurs
/// in the GUI process.
public enum WorkbenchDeviceNameForwarder {
    public enum Failure: Error, Equatable {
        case invalidName, invalidSnapshot, outcomeUnknown
    }

    public static func rename(client: WorkbenchBrokerClient, deviceId: String,
                              rawName: String) throws -> DeviceSettingsSnapshot {
        try rename(port: client, deviceId: deviceId, rawName: rawName)
    }

    static func rename(port: any WorkbenchDeviceNamePort, deviceId: String,
                       rawName: String) throws -> DeviceSettingsSnapshot {
        guard let name = DeviceDisplayName.sanitize(rawName) else { throw Failure.invalidName }
        let before = try port.deviceSettings(deviceId)
        guard !before.revision.isEmpty else { throw Failure.invalidSnapshot }
        if before.value.displayName == name { return before }
        var value = before.value
        value.displayName = name
        try value.validate()
        let after = try port.updateDeviceSettings(deviceId,
            expectedRevision: before.revision, value: value)
        guard !after.revision.isEmpty, after.revision != before.revision,
              after.value == value else { throw Failure.outcomeUnknown }
        return after
    }
}
#endif
