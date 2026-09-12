import Foundation

public struct SafeAreaInsets: Codable, Sendable, Equatable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

public struct ManifestTarget: Codable, Sendable, Equatable {
    public var profileId: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var orientation: String
    public var safeArea: SafeAreaInsets?

    public init(
        profileId: String,
        width: Int,
        height: Int,
        scale: Double,
        orientation: String,
        safeArea: SafeAreaInsets? = nil
    ) {
        self.profileId = profileId
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
        self.safeArea = safeArea
    }
}

public struct ManifestOperation: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var maxAgeSeconds: Int?
}

public struct ManifestConnection: Codable, Sendable, Equatable {
    public var alias: String
    public var required: Bool
    public var operations: [ManifestOperation]?
}

public struct ManifestFile: Codable, Sendable, Equatable {
    public var path: String
    public var bytes: Int
    public var sha256: String
}

public struct DashboardManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var dashboardId: String
    public var name: String
    public var revision: String
    public var entrypoint: String
    public var sdkVersion: String
    public var digest: String?
    public var target: ManifestTarget
    public var connections: [ManifestConnection]
    public var files: [ManifestFile]
}
