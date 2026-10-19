import Foundation
#if os(macOS)
/// Matching is limited to the installation UUID supplied by authenticated paired status.
/// Display names, host names, advertised IDs, and account sign-in are not evidence.
public enum ControllerCloudDeviceIdentity {
    public static func matches(local: WorkbenchDeviceRead, installationId: String) -> Bool {
        guard local.ownerMatchesCurrent, let observed = local.cloudInstallationId,
              let uuid = UUID(uuidString:installationId), uuid.uuidString.lowercased() == installationId else { return false }
        return observed == installationId
    }
}
#endif
