import Foundation

/// Host isolation policy for untrusted dashboard packages.
/// Native networking only; the page must not make direct egress.
public enum IsolationPolicy: Sendable {
    public static let customScheme = "screenpunk"
    public static let packageHost = "package"
    public static let nativeNetworkingOnly = true
    public static let unlinkGestureSurvivesContentProcessDeath = true

    /// Immutable CSP injected by the native host. `connect-src 'none'` is the
    /// page-level deny; native adapters perform approved HTTP/WS.
    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "connect-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "media-src 'self'"
    ].joined(separator: "; ")

    public static let contentRuleListJSON = """
    [
      {
        "trigger": { "url-filter": "^https?://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss?://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^file://" },
        "action": { "type": "block" }
      }
    ]
    """
}

public enum IsolationRequestKind: String, Sendable, Codable, CaseIterable {
    case fetch
    case xhr
    case websocket
    case script
    case stylesheet
    case image
    case media
    case iframe
    case form
    case navigation
    case filePath
    case traversal
    case bridgeSpoof
}

public struct IsolationRequest: Sendable, Equatable {
    public var kind: IsolationRequestKind
    public var url: String
    public var isMainFrame: Bool
    public var initiatorOrigin: String

    public init(
        kind: IsolationRequestKind,
        url: String,
        isMainFrame: Bool = true,
        initiatorOrigin: String = "screenpunk://package/"
    ) {
        self.kind = kind
        self.url = url
        self.isMainFrame = isMainFrame
        self.initiatorOrigin = initiatorOrigin
    }
}

public enum IsolationDecision: String, Sendable, Equatable {
    case allowLocalAsset
    case denyDirectEgress
    case denyRemoteCode
    case denyNavigation
    case denyFrame
    case denyTraversal
    case denyBridgeSpoof
    case denyFilePath
}

public enum IsolationEvaluator: Sendable {
    public static func decide(_ request: IsolationRequest) -> IsolationDecision {
        if request.kind == .bridgeSpoof {
            return .denyBridgeSpoof
        }

        if containsTraversal(request.url) {
            return .denyTraversal
        }

        if request.kind == .filePath || request.url.lowercased().hasPrefix("file:") {
            return .denyFilePath
        }

        if request.kind == .iframe || request.kind == .form {
            return .denyFrame
        }

        if isRemote(request.url) {
            if request.kind == .script || request.kind == .stylesheet {
                return .denyRemoteCode
            }
            if request.kind == .navigation {
                return .denyNavigation
            }
            return .denyDirectEgress
        }

        if request.kind == .navigation && !isLocalPackageURL(request.url) {
            return .denyNavigation
        }

        if isLocalPackageURL(request.url) {
            return .allowLocalAsset
        }

        return .denyDirectEgress
    }

    public static func isLocalPackageURL(_ url: String) -> Bool {
        let prefix = "\(IsolationPolicy.customScheme)://\(IsolationPolicy.packageHost)/"
        guard url.hasPrefix(prefix) else { return false }
        let rest = String(url.dropFirst(prefix.count))
        if rest.isEmpty { return false }
        if containsTraversal(rest) { return false }
        return rest.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "/" || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    private static func isRemote(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http:")
            || lower.hasPrefix("https:")
            || lower.hasPrefix("ws:")
            || lower.hasPrefix("wss:")
    }

    private static func containsTraversal(_ url: String) -> Bool {
        url.split(separator: "/").contains("..") || url.contains("\\..") || url.lowercased().contains("%2e%2e")
    }

}

public enum ContentProcessFailure: Sendable {
    public static let recoveryReloadsActivePackage = true
    public static let unlinkGestureRemainsAvailable = true

    public static func simulateTermination() -> String {
        "content-process-terminated"
    }
}
