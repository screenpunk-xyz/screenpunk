#if os(iOS)
import SwiftUI
import UIKit
import ScreenpunkCore

/// Device-only content for the existing menu. No identity or enrollment authority.
@_spi(ManagedRender) public struct DeviceCloudMenuContent {
    let deviceName: String
    let connectionNeedsAttention: Bool
    let connectionDescription: String
    let screenSummary: String
    let screenCount: Int?
    let installedManifests: [DashboardManifest]
    let settings: AnyView
    let screens: AnyView
    public init<Settings: View, Screens: View>(deviceName: String, connectionDescription: String, connectionNeedsAttention: Bool = false,
        screenSummary: String, screenCount: Int?, installedManifests: [DashboardManifest] = [], settings: Settings, screens: Screens) {
        self.deviceName = deviceName; self.connectionDescription = connectionDescription
        self.connectionNeedsAttention = connectionNeedsAttention
        self.screenSummary = screenSummary; self.screenCount = screenCount
        self.installedManifests = installedManifests
        self.settings = AnyView(settings); self.screens = AnyView(screens)
    }
}

@_spi(ManagedRender) public enum DeviceCloudMenuPage { case welcome, settings, cloud, screens }

/// Reuses the standard menu even while a device-only host is reconnecting.
@_spi(ManagedRender) public struct DeviceCloudMenuView: View {
    private let host: DeviceLANHost?
    private let cloud: DeviceCloudMenuContent
    private let page: DeviceCloudMenuPage
    private let availableSize: CGSize
    private let onUserNavigation: () -> Void
    public init(host: DeviceLANHost?, cloud: DeviceCloudMenuContent, page: DeviceCloudMenuPage = .welcome,
                availableSize: CGSize, onUserNavigation: @escaping () -> Void = {}) {
        self.host = host; self.cloud = cloud; self.page = page; self.availableSize = availableSize
        self.onUserNavigation = onUserNavigation
    }
    private var initialPage: DeviceSetupPage? {
        switch page { case .welcome: return nil; case .settings: return .settings; case .cloud: return .cloud; case .screens: return .screens }
    }
    public var body: some View {
        DeviceSetupMenu(host: host, initialPage: initialPage, onConnectionsChanged: { host?.refresh() },
            cloud: cloud, onUserNavigation: onUserNavigation, availableSize: availableSize)
    }
}

/// The same two-finger menu covers native rendered content and explicit empty selections.
@_spi(ManagedRender) public struct DeviceCloudDisplayView<Display: View>: View {
    private let host: DeviceLANHost?
    private let cloud: DeviceCloudMenuContent
    private let emptyGeneration: UUID?
    private let installationIdentity: UUID?
    private let menuEnabled: Bool
    private let hasDisplayContent: Bool
    private let emptyMounted: (UUID) -> Void
    private let display: Display
    @State private var showMenu = false
    @State private var page = DeviceCloudMenuPage.welcome
    @State private var automaticallyPresentedMenu = false
    // Open once for an installation. Later empty selections stay quiet and keep
    // the normal Settings and two-finger/accessibility menu entries available.
    @State private var automaticallyOpenedEmpty = false
    @State private var observedInstallationIdentity: UUID?
    private struct PresentationState: Equatable {
        let installationIdentity: UUID?
        let emptyGeneration: UUID?
        let hasDisplayContent: Bool
        let menuEnabled: Bool
    }
    private var presentationState: PresentationState {
        .init(installationIdentity: installationIdentity, emptyGeneration: emptyGeneration,
            hasDisplayContent: hasDisplayContent, menuEnabled: menuEnabled)
    }
    public init(host: DeviceLANHost?, cloud: DeviceCloudMenuContent, installationIdentity: UUID?, emptyGeneration: UUID?, hasDisplayContent: Bool,
                menuEnabled: Bool = true, emptyMounted: @escaping (UUID) -> Void = { _ in },
                @ViewBuilder display: () -> Display) {
        self.host = host; self.cloud = cloud; self.installationIdentity = installationIdentity; self.emptyGeneration = emptyGeneration
        self.menuEnabled = menuEnabled; self.hasDisplayContent = hasDisplayContent
        self.emptyMounted = emptyMounted; self.display = display()
    }
    public var body: some View {
        GeometryReader { geometry in
            // Keep the sheet owner outside the UIKit hosting controller whose root
            // content changes when a rendered screen becomes an empty display.
            ZStack {
                DeviceMenuHold(content: displayedContent
                    .allowsHitTesting(!showMenu).accessibilityHidden(showMenu), open: { open(.welcome) })
                    .accessibilityAction(named: "Open Screenpunk menu") { open(.welcome) }
            }
                .sheet(isPresented: $showMenu, onDismiss: { automaticallyPresentedMenu = false }) {
                    DeviceCloudMenuView(host: host, cloud: cloud, page: page, availableSize: geometry.size,
                        onUserNavigation: { automaticallyPresentedMenu = false })
                }
                .onAppear { updatePresentation(presentationState) }
                .onChange(of: presentationState) { state in updatePresentation(state) }
        }
    }
    @ViewBuilder private var displayedContent: some View {
        if hasDisplayContent { display }
        else {
            DeviceOnboardingConnectedView(connectionDescription: cloud.connectionDescription,
                hasScreens: (cloud.screenCount ?? 0) > 0,
                screens: { open(.screens) }, settings: { open(cloud.connectionNeedsAttention ? .cloud : .settings) },
                title: "Screenpunk Cloud", emptyMessage: emptyMessage)
                .id(emptyGeneration)
                .onAppear { if let emptyGeneration { emptyMounted(emptyGeneration) } }
        }
    }
    private var emptyMessage: String {
        if cloud.connectionNeedsAttention { return "Screen updates are not connected. Open Settings to check the Cloud connection and retry." }
        guard emptyGeneration != nil else { return "Open Settings to view this device’s Cloud connection." }
        return cloud.screenCount == 0
            ? "Assign your first screen in Screenpunk Cloud."
            : "No screen is selected. Assign a screen in Screenpunk Cloud."
    }
    private func open(_ page: DeviceCloudMenuPage) {
        guard menuEnabled else { return }
        self.page = page; automaticallyPresentedMenu = false; showMenu = true
    }
    private func updatePresentation(_ state: PresentationState) {
        // A single new input value avoids mixing an old rendered state with a
        // newly observed installation or empty generation in separate callbacks.
        if observedInstallationIdentity != state.installationIdentity {
            observedInstallationIdentity = state.installationIdentity
            automaticallyOpenedEmpty = false
        }
        if state.hasDisplayContent {
            if automaticallyPresentedMenu { automaticallyPresentedMenu = false; showMenu = false }
            return
        }
        guard state.menuEnabled, state.emptyGeneration != nil, !automaticallyOpenedEmpty else { return }
        automaticallyOpenedEmpty = true
        guard !showMenu else { return }
        page = .welcome; automaticallyPresentedMenu = true; showMenu = true
    }
}
#endif
