import Foundation
import ScreenpunkCore

public enum ScreenOrientationSupport: String, Codable, CaseIterable, Sendable {
    case portrait, landscape, both
    public func allows(_ orientation: DeviceOrientation) -> Bool { self == .both || rawValue == orientation.rawValue }
}

/// Portable authoring settings, shipped as an ordinary local package asset.
/// This keeps the deployment manifest compatible with existing phone builds.
public struct ScreenDesignSettings: Codable, Sendable {
    public static let path = "screenpunk-screen.json"
    public var orientations: ScreenOrientationSupport
    public init(orientations: ScreenOrientationSupport = .both) { self.orientations = orientations }
    public static func read(files: [String: Data]) throws -> ScreenDesignSettings {
        guard let data = files[path] else { return ScreenDesignSettings() }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
}
