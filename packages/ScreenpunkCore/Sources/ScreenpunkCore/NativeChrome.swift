/// Native-owned chrome. Dashboard JavaScript must not draw or dismiss these.

public enum UnlinkGestureSpec: Sendable {
    public static let fingers = 2
    public static let holdSeconds = OfflineOverlaySpec.holdSecondsForUnlink
    public static let actionTitle = "Unlink"
    public static let actionCount = 1
    public static let worksOverTerminatedWebContent = true
    public static let voiceOverEquivalent = true
    public static let explanation =
        "Unlinking removes the dashboard and connection credentials."
}

public enum OfflineOverlayLayout: Sendable {
    public static let ringPoints = OfflineOverlaySpec.ringPoints
    public static let labelPoints = 14
    public static let tabPaddingPoints = 12
    public static let label = OfflineOverlaySpec.label
    public static let interceptsTouches = false
    public static let blinks = false
    public static let hideableByDashboardCSS = false
    public static let usesSystemRed = OfflineOverlaySpec.usesSystemRed
    public static let lightDangerHex = OfflineOverlaySpec.lightDangerHex
    public static let darkDangerHex = OfflineOverlaySpec.darkDangerHex
    public static let lightLabelHex = SemanticTokens.Light.onAction
    public static let darkLabelHex = SemanticTokens.Dark.onAction
}

public enum ConnectionHealth: Sendable {
    /// No package connections means no connection-driven Offline overlay.
    public static func overlayVisible(requiredFailedOrStale: Bool, connectionCount: Int) -> Bool {
        connectionCount > 0 && requiredFailedOrStale
    }
}
