import Foundation

public enum PackageIssue: String, Sendable, Equatable {
    case unsupportedVersion
    case validationFailed
    case missingEntrypoint
    case duplicatePath
    case pathTraversal
    case sizeLimit
    case hashMismatch
    case symlinkRejected
    case credentialLeak
    case digestMismatch
}

public struct PackageValidationError: Error, Equatable {
    public var issues: [PackageIssue]
}

public enum PackagePath {
    private static let traversal = try! NSRegularExpression(
        pattern: #"(^|/)\.\.(/|$)|\\|\0|^/|^[A-Za-z]:"#
    )

    public static func normalize(_ path: String) throws -> String {
        if path.lowercased().contains("%2e%2e") || traversal.firstMatch(
            in: path,
            range: NSRange(path.startIndex..., in: path)
        ) != nil {
            throw PackageValidationError(issues: [.pathTraversal])
        }
        return path
    }
}

public enum PackageValidator {
    public static func validate(_ manifest: DashboardManifest) throws {
        var issues: [PackageIssue] = []
        if manifest.schemaVersion != PackageLimits.schemaMajor {
            issues.append(.unsupportedVersion)
        }
        if manifest.sdkVersion != "1" {
            issues.append(.validationFailed)
        }
        if ["portrait", "landscape"].contains(manifest.target.orientation) == false {
            issues.append(.validationFailed)
        }

        let blob = "\(manifest.dashboardId)\(manifest.name)\(manifest.entrypoint)"
        if blob.range(of: "password|secret|token|api[_-]?key|bearer", options: .regularExpression) != nil {
            issues.append(.credentialLeak)
        }

        var seen = Set<String>()
        var expanded = 0
        for file in manifest.files {
            do {
                let path = try PackagePath.normalize(file.path)
                if seen.contains(path) { issues.append(.duplicatePath) }
                seen.insert(path)
            } catch {
                issues.append(.pathTraversal)
            }
            expanded += file.bytes
        }
        if manifest.files.count > PackageLimits.maxFiles || expanded > PackageLimits.expandedBytes {
            issues.append(.sizeLimit)
        }
        if let entry = try? PackagePath.normalize(manifest.entrypoint), !seen.contains(entry) {
            issues.append(.missingEntrypoint)
        }
        if issues.isEmpty == false {
            throw PackageValidationError(issues: Array(Set(issues)))
        }
    }
}

public enum RuntimeBounds {
    public static let stateCacheBytes = 5 * 1024 * 1024
    public static let logBytes = 5 * 1024 * 1024
    public static let httpTimeoutSeconds = 15
    public static let httpResponseBytes = 2 * 1024 * 1024
    public static let websocketMessageBytes = 256 * 1024
    public static let minPollSeconds = 15
    public static let weatherPollSeconds = 15 * 60
    public static let backoffCapSeconds = 60
    public static let readyTimeoutSeconds = 15
}

public enum RenderState: String, Sendable {
    case pending
    case ready
    case timeout
    case contentProcessTerminated
}

public struct RenderReadiness: Sendable {
    public var state: RenderState
    public init(state: RenderState = .pending) {
        self.state = state
    }

    public var connectionsHealthy: Bool { false }
}
