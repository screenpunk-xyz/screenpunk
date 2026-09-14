import Foundation

public struct LANScreenSetItem: Codable, Equatable, Sendable {
    public var name: String
    public var deployment: LANDeployBody
    public var homeAssistant: HomeAssistantProvisioning?
    public init(name: String, deployment: LANDeployBody, homeAssistant: HomeAssistantProvisioning? = nil) {
        self.name = name; self.deployment = deployment; self.homeAssistant = homeAssistant
    }
}

public struct LANScreenSetEntry: Codable, Equatable, Sendable {
    public var dashboardId: String
    public var revision: String
    public var name: String
    public init(dashboardId: String, revision: String, name: String) {
        self.dashboardId = dashboardId; self.revision = revision; self.name = name
    }
}

public struct LANScreenSetDeployBody: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var deploymentId: String
    public var deviceId: String
    public var screens: [LANScreenSetItem]
    public var selectedDashboardId: String
    public init(schemaVersion: Int = 1, deploymentId: String, deviceId: String, screens: [LANScreenSetItem], selectedDashboardId: String) {
        self.schemaVersion = schemaVersion; self.deploymentId = deploymentId; self.deviceId = deviceId
        self.screens = screens; self.selectedDashboardId = selectedDashboardId
    }
    public func validate() throws {
        guard schemaVersion == 1, !deploymentId.isEmpty, !deviceId.isEmpty, (1...12).contains(screens.count),
              Set(screens.map { $0.deployment.revision.dashboardId }).count == screens.count,
              Set(screens.map { $0.deployment.revision.revision }).count == screens.count,
              screens.contains(where: { $0.deployment.revision.dashboardId == selectedDashboardId }) else {
            throw TransferFailure.validationFailed
        }
        for screen in screens {
            let body = screen.deployment
            guard !screen.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  body.deployment.deviceId == deviceId,
                  body.deployment.revision == body.revision.revision,
                  body.deployment.dashboardId == body.revision.dashboardId else { throw TransferFailure.validationFailed }
            if let config = screen.homeAssistant {
                try config.validate()
                guard config.dashboardId == body.revision.dashboardId, config.revision == body.revision.revision else {
                    throw TransferFailure.validationFailed
                }
            }
        }
    }
}

public struct LANScreenSetReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var deploymentId: String
    public var deviceId: String
    public var screens: [LANScreenSetEntry]
    public var selectedDashboardId: String
    public init(schemaVersion: Int = 1, deploymentId: String, deviceId: String, screens: [LANScreenSetEntry], selectedDashboardId: String) {
        self.schemaVersion = schemaVersion; self.deploymentId = deploymentId; self.deviceId = deviceId
        self.screens = screens; self.selectedDashboardId = selectedDashboardId
    }
}

/// References only immutable package directories and Keychain generations; never credentials.
public struct DeviceInstalledScreen: Codable, Equatable, Sendable {
    public var name: String
    public var revision: StoredRevision
    public var deployment: DeploymentRecord
    public var packageDirectory: String
    public init(name: String, revision: StoredRevision, deployment: DeploymentRecord, packageDirectory: String) {
        self.name = name; self.revision = revision; self.deployment = deployment; self.packageDirectory = packageDirectory
    }
    public var entry: LANScreenSetEntry { .init(dashboardId: revision.dashboardId, revision: revision.revision, name: name) }
}

public struct DeviceInstalledScreenSet: Codable, Equatable, Sendable {
    public var deploymentId: String
    public var contentDigest: String
    public var deployedSelectedDashboardId: String
    public var grantSet: String
    public var screens: [DeviceInstalledScreen]
    public var selectedDashboardId: String
    public init(deploymentId: String, contentDigest: String, grantSet: String, screens: [DeviceInstalledScreen], selectedDashboardId: String) {
        self.deploymentId = deploymentId; self.contentDigest = contentDigest; self.grantSet = grantSet
        self.deployedSelectedDashboardId = selectedDashboardId
        self.screens = screens; self.selectedDashboardId = selectedDashboardId
    }
}

/// Circular navigation uses the deployed order in both gestures and the chooser.
public enum ScreenCarousel {
    public static func index(from current: Int, offset: Int, count: Int) -> Int? {
        guard count > 0, (0..<count).contains(current) else { return nil }
        return ((current + offset % count) % count + count) % count
    }
}
