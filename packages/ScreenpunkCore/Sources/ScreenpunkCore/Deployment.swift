import Foundation

public enum DeviceOrientation: String, Sendable, Codable, Equatable {
    case portrait
    case landscape
}

public struct DeviceProfile: Sendable, Equatable, Codable {
    public var deviceId: String
    public var name: String
    public var orientation: DeviceOrientation
    public var width: Int
    public var height: Int
    public var model: String?

    public init(
        deviceId: String,
        name: String,
        orientation: DeviceOrientation = .portrait,
        width: Int = 390,
        height: Int = 844,
        model: String? = nil
    ) {
        self.deviceId = deviceId
        self.name = name
        self.orientation = orientation
        self.width = width
        self.height = height
        self.model = model
    }

    public mutating func apply(orientation: DeviceOrientation) {
        if self.orientation == orientation { return }
        let (w, h) = (width, height)
        if orientation == .landscape {
            width = max(w, h)
            height = min(w, h)
        } else {
            width = min(w, h)
            height = max(w, h)
        }
        self.orientation = orientation
    }
}

public enum DeploymentPhase: String, Sendable, Codable, Equatable {
    case queued
    case transferring
    case validating
    case activating
    case active
    case failed
}

public struct DeploymentRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: String { deploymentId }
    public var deploymentId: String
    public var revision: String
    public var dashboardId: String
    public var deviceId: String
    public var phase: DeploymentPhase
    public var error: String?

    public init(
        deploymentId: String,
        revision: String,
        dashboardId: String,
        deviceId: String,
        phase: DeploymentPhase,
        error: String? = nil
    ) {
        self.deploymentId = deploymentId
        self.revision = revision
        self.dashboardId = dashboardId
        self.deviceId = deviceId
        self.phase = phase
        self.error = error
    }
}

public struct StoredRevision: Sendable, Equatable, Codable, Identifiable {
    public var id: String { revision }
    public var revision: String
    public var dashboardId: String
    public var name: String
    public var digest: String
    public var orientation: DeviceOrientation
    public var width: Int
    public var height: Int

    public init(
        revision: String,
        dashboardId: String,
        name: String,
        digest: String,
        orientation: DeviceOrientation,
        width: Int,
        height: Int
    ) {
        self.revision = revision
        self.dashboardId = dashboardId
        self.name = name
        self.digest = digest
        self.orientation = orientation
        self.width = width
        self.height = height
    }

    public static let offlineFixture = StoredRevision(
        revision: "22222222-2222-4222-8222-222222222222",
        dashboardId: "11111111-1111-4111-8111-111111111111",
        name: "Offline fixture",
        digest: "bd091f72ea19147c42be65292b7e482daa7ed7097fce7d4865d29a1c46225c82",
        orientation: .portrait,
        width: 390,
        height: 844
    )

    public func matches(profile: DeviceProfile) -> Bool {
        orientation == profile.orientation && width == profile.width && height == profile.height
    }
}

public enum WorkbenchCopy: Sendable {
    public static let livePreview = "Live preview — actions control your devices"
    public static let forgetUnreachable =
        "This Mac has forgotten the device. To remove its dashboard and pairing, hold two fingers on its screen for 5 seconds, then choose Disconnect in the device menu and confirm."
}

public enum TransferFailure: String, Error, Sendable, Equatable {
    case notPaired
    case targetMismatch
    case validationFailed
    case interrupted
    case deviceOffline
}
