import ScreenpunkCore

/// Host-owned overlay and unlink scaffolding. Not first-party designed chrome yet.
public enum NativeChromeHost: Sendable {
    public static var overlayOwnedByWebContent: Bool { false }
    public static var gestureOwnedByWebContent: Bool { false }
    public static var unlinkActionTitle: String { UnlinkGestureSpec.actionTitle }
    public static var unlinkActionCount: Int { UnlinkGestureSpec.actionCount }
    public static var holdSeconds: Int { UnlinkGestureSpec.holdSeconds }
    public static var ringUsesSystemRed: Bool { OfflineOverlayLayout.usesSystemRed }
    public static var lightDangerHex: String { OfflineOverlayLayout.lightDangerHex }
    public static var darkDangerHex: String { OfflineOverlayLayout.darkDangerHex }

    public static func shouldShowOffline(requiredFailedOrStale: Bool, connectionCount: Int) -> Bool {
        ConnectionHealth.overlayVisible(
            requiredFailedOrStale: requiredFailedOrStale,
            connectionCount: connectionCount
        )
    }
}
