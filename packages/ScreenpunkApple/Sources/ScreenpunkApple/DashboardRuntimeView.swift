import SwiftUI
import ScreenpunkCore

/// Shared iOS 16 + Mac host: custom-scheme WKWebView, native Offline ring, Unlink.
public struct DashboardRuntimeView: View {
    public var store: PackageAssetStore
    public var connectionCount: Int
    public var requiredFailedOrStale: Bool
    public var onUnlink: () -> Void

    public var homeAssistant: HomeAssistantDeviceRuntime?
    public var revision: String
    @State private var connectionUnhealthy = false
    @State private var showUnlink = false

    public init(
        store: PackageAssetStore,
        homeAssistant: HomeAssistantDeviceRuntime? = nil,
        revision: String = "",
        connectionCount: Int = 0,
        requiredFailedOrStale: Bool = false,
        onUnlink: @escaping () -> Void = {}
    ) {
        self.homeAssistant = homeAssistant
        self.revision = revision
        self.store = store
        self.connectionCount = connectionCount
        self.requiredFailedOrStale = requiredFailedOrStale
        self.onUnlink = onUnlink
    }

    public static func offlineFixture() throws -> DashboardRuntimeView {
        let store = try PackageAssetStore.bundledOfflineFixture()
        return DashboardRuntimeView(store: store, connectionCount: 0, requiredFailedOrStale: false)
    }

    private var showOffline: Bool {
        NativeChromeHost.shouldShowOffline(
            requiredFailedOrStale: requiredFailedOrStale,
            connectionCount: connectionCount
        )
    }

    public var body: some View {
        ZStack {
#if canImport(WebKit)
            DashboardWebView(store: store, homeAssistant: homeAssistant, revision: revision,
                             onConnectionHealth: { connectionUnhealthy = !$0 }, onUnlinkHold: { showUnlink = true })
#else
            Text("WKWebView unavailable")
#endif
            if showOffline || connectionUnhealthy {
                OfflineRingOverlay()
            }
            if showUnlink {
                UnlinkPanelView(
                    onUnlink: {
                        showUnlink = false
                        onUnlink()
                    },
                    onDismiss: { showUnlink = false }
                )
            }
        }
        .accessibilityAction(named: Text(UnlinkGestureSpec.actionTitle)) {
            showUnlink = true
        }
        .accessibilityHint(UnlinkGestureSpec.explanation)
    }
}
