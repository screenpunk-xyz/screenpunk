import Foundation
import ScreenpunkCore

#if os(macOS)
/// Shares the one broker-owned, pinned native DeviceCoordinator. The same
/// coordinator's deployScreenSet sends once after durable M4 admission.
struct WorkbenchNativeDeploymentPeer: WorkbenchDeploymentPeer {
    let devices: DeviceCoordinator

    func observe(deviceId: String) throws -> WorkbenchDeploymentObservation {
        let (profile, screens, selected, observedAt, name) = try devices.observeScreenSet(deviceId)
        return .init(deviceId: deviceId, name: name, profile: profile,
                     screens: screens, selectedDashboardId: selected, observedAt: observedAt)
    }

    func send(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        try devices.deployScreenSet(body)
    }

    func send(_ body: LANScreenSetDeployBody,
              preSend: () throws -> Void) throws -> LANScreenSetReceipt {
        try devices.deployScreenSet(body, preSend: preSend)
    }
}
#endif
