import Foundation
import ScreenpunkCore

/// Materializes a device-sized package without modifying the reusable source screen.
public enum ScreenPackagePreparation {
    public static func prepare(_ source: DashboardRevisionRecord, for device: DeviceProfile, orientation: DeviceOrientation, root: URL) throws -> DashboardRevisionRecord {
        let settings = try ScreenDesignSettings.read(files: source.files)
        guard settings.orientations.allows(orientation) else {
            throw ControllerError.validationFailed(detail: "This screen supports \(settings.orientations.rawValue) only.")
        }
        var profile = device
        profile.apply(orientation: orientation)
        let target = ManifestTarget(profileId: device.deviceId, width: profile.width, height: profile.height, scale: source.manifest.target.scale, orientation: orientation.rawValue, safeArea: source.manifest.target.safeArea)
        let directory = root.appendingPathComponent("device-packages/\(UUID().uuidString.lowercased())")
        let store = try DashboardPackageStore(root: directory)
        return try store.putDashboard(dashboardId: source.manifest.dashboardId, name: source.manifest.name, baseRevision: nil, target: target, connections: source.manifest.connections, files: source.files.map { DashboardFileInput(path: $0.key, base64: $0.value.base64EncodedString()) })
    }
}
