import Foundation
import ScreenpunkCore

/// A device's existing Keychain TLS identity is its stable installation identity.
/// Deriving the discovery ID avoids another identifier that could diverge on restore.
public enum DeviceInstallIdentity {
    public static let pendingID = "device-pending"

    public static func deviceID(for pin: [UInt8]) -> String {
        "device-" + PeerPin.hex(PeerPin.sha256(Data(pin))).prefix(32)
    }

    /// Explicit caller-supplied fixture IDs remain intact. Production launches use
    /// pendingID; upgrades from the first host used the shared "phone-local" ID.
    /// Returns true only when an existing persisted deployment record changed.
    @discardableResult
    static func migrate(_ runtime: inout DeviceRuntime, pin: [UInt8]) -> Bool {
        let legacyIDs: Set<String> = ["phone-local", pendingID]
        guard legacyIDs.contains(runtime.profile.deviceId) else { return false }
        let id = deviceID(for: pin)
        runtime.profile.deviceId = id
        runtime.advertisement.deviceId = id
        if let recordID = runtime.lastDeployment?.deviceId, legacyIDs.contains(recordID) {
            runtime.lastDeployment?.deviceId = id
            return true
        }
        return false
    }
}
