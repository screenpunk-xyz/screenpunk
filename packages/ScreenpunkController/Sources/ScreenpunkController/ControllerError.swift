import Foundation

public enum ControllerErrorCode: String, Sendable, Equatable, CaseIterable {
    case notPaired = "not_paired"
    case permissionRequired = "permission_required"
    case revisionConflict = "revision_conflict"
    case unsupportedVersion = "unsupported_version"
    case deviceOffline = "device_offline"
    case renderTimeout = "render_timeout"
    case validationFailed = "validation_failed"
    case snapshotUnavailable = "snapshot_unavailable"
}

public struct ControllerError: Error, Equatable, Sendable {
    public var code: ControllerErrorCode
    public var detail: String

    public init(code: ControllerErrorCode, detail: String) {
        self.code = code
        self.detail = detail
    }

    public static func notPaired(_ detail: String = "no paired device") -> ControllerError {
        ControllerError(code: .notPaired, detail: detail)
    }

    public static func permissionRequired(_ detail: String) -> ControllerError {
        ControllerError(code: .permissionRequired, detail: detail)
    }

    public static func revisionConflict(_ detail: String) -> ControllerError {
        ControllerError(code: .revisionConflict, detail: detail)
    }

    public static func validationFailed(detail: String) -> ControllerError {
        ControllerError(code: .validationFailed, detail: detail)
    }

    public static func renderTimeout(_ detail: String = "preview helper did not become ready") -> ControllerError {
        ControllerError(code: .renderTimeout, detail: detail)
    }

    public static func snapshotUnavailable(reason: String) -> ControllerError {
        ControllerError(code: .snapshotUnavailable, detail: "SNAPSHOT_UNAVAILABLE reason=\(reason)")
    }

    public var mcpText: String {
        "\(code.rawValue): \(detail)"
    }
}

public enum PNGMagic: Sendable {
    public static let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && data.starts(with: bytes)
    }
}
