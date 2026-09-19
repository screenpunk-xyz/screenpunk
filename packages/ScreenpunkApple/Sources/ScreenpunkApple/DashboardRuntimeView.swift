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
    public var connections: ConnectionRuntime?
    public var settings: DeviceSettings
    public var onSettingsApplied: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionUnhealthy = false
    @State private var showUnlink = false
    @State private var loaded = false
    public var onMenu: (() -> Void)?
    public var screenName: String

    public init(
        store: PackageAssetStore,
        homeAssistant: HomeAssistantDeviceRuntime? = nil,
        revision: String = "",
        connections: ConnectionRuntime? = nil,
        settings: DeviceSettings = .init(),
        onSettingsApplied: @escaping (Bool) -> Void = { _ in },
        connectionCount: Int = 0,
        requiredFailedOrStale: Bool = false,
        screenName: String = "Screen",
        onMenu: (() -> Void)? = nil,
        onUnlink: @escaping () -> Void = {}
    ) {
        self.onMenu = onMenu
        self.screenName = screenName
        self.homeAssistant = homeAssistant
        self.revision = revision
        self.connections = connections; self.settings = settings; self.onSettingsApplied = onSettingsApplied
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
                             connections: connections, settings: settings, active: scenePhase == .active, onSettingsApplied: onSettingsApplied,
                             onConnectionHealth: { connectionUnhealthy = !$0 },
                             onReady: { loaded = true }, onUnlinkHold: openMenu)
#else
            Text("WKWebView unavailable")
#endif
            if !loaded {
                ZStack {
                    Color.black
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.stack").font(.system(size: 44))
                        Text(screenName).font(.title2)
                        ProgressView("Opening screen…").tint(.white)
                    }.foregroundStyle(.white)
                }.allowsHitTesting(false).transition(.opacity)
            }
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
        .accessibilityAction(named: "Device menu", openMenu)
        .accessibilityHint("Hold two fingers for five seconds to open the device menu.")
    }
    private func openMenu() {
        if let onMenu { onMenu() } else { showUnlink = true }
    }
}
