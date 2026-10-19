import Foundation
import ScreenpunkCore

#if os(macOS)
/// Shares the one broker-owned, pinned native DeviceCoordinator. The same
/// coordinator's deployScreenSet sends once after durable M4 admission.
struct WorkbenchNativeDeploymentPeer: WorkbenchDeploymentPeer {
    let devices: DeviceCoordinator

    func observe(deviceId: String) throws -> WorkbenchDeploymentObservation {
        let (profile, screens, selected, observedAt, name, active) = try devices.observeScreenSetWithGeneration(deviceId)
        var observation = WorkbenchDeploymentObservation(deviceId: deviceId, name: name, profile: profile,
                     screens: screens, selectedDashboardId: selected, observedAt: observedAt)
        observation.stateGenerationId = active.stateGenerationId
        observation.commonEntries = active.commonEntries
        observation.configuredEntryId = active.configuredEntryId
        observation.activeGenerationId = active.activeGenerationId
        observation.activeEntryId = active.activeEntryId
        return observation
    }

    func sendUnified(_ body: LANUnifiedScreenInstall, deviceId: String, preSend: () throws -> Void) throws -> LANActiveQuery {
        try devices.installUnifiedScreens(deviceId: deviceId, body: body, preSend: preSend)
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
