#if os(iOS)
import SwiftUI
import UIKit
import ScreenpunkCore

enum DeviceSetupPage: Hashable { case settings, googleTV, googleCalendar, display, screens, guided }

@MainActor
struct DeviceConnectorCatalog {
    let manifests: [DashboardManifest]
    var usesTV: Bool { manifests.contains { $0.connections.contains { $0.alias == "googleTV" } } }
    var usesCalendar: Bool { manifests.contains { $0.connections.contains { ["googleCalendar", "google-calendar"].contains($0.alias) } } }
    var showsTV: Bool { usesTV || !GoogleTVConfiguration.load().host.isEmpty || !GoogleTVADBConfiguration.load().host.isEmpty }
    func missing(for dashboardID: String?) -> DeviceSetupPage? {
        guard let manifest = manifests.first(where: { $0.dashboardId == dashboardID }) else { return nil }
        for connection in manifest.connections where connection.required {
            if connection.alias == "googleTV" {
                let operations = connection.operations?.map(\.name) ?? []
                let basic = operations.isEmpty || operations.contains(where: { !["launchChannel", "togglePower"].contains($0) })
                let developer = operations.contains("launchChannel") || operations.contains("togglePower")
                if (basic && GoogleTVConfiguration.load().pin.count != 32) || (developer && GoogleTVADBConfiguration.load().serverPin.count != 32) { return .googleTV }
            }
            if ["googleCalendar", "google-calendar"].contains(connection.alias) { return .googleCalendar }
        }
        return nil
    }
}

@MainActor
struct DeviceSetupMenu: View {
    @ObservedObject var host: DeviceLANHost
    let initialPage: DeviceSetupPage?
    let onConnectionsChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsOpen = false
    @State private var path: [DeviceSetupPage] = []
    @State private var selection: DeviceSetupPage? = .googleTV
    @State private var windowSize = CGSize(width: 800, height: 1000)
    @State private var headerHeight: CGFloat = 105
    @State private var rowsHeight: CGFloat = 340
    @State private var connectionsRevision = UUID()
    @AppStorage("guidedAccessSetupConfirmed") private var guidedConfirmed = false
    private let clock = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private var catalog: DeviceConnectorCatalog { .init(manifests: host.server?.installedManifests ?? []) }
    private var wide: Bool { settingsOpen && windowSize.width >= 1000 }
    private var screens: [LANScreenSetEntry] { host.screenSet?.screens.map(\.entry) ?? [] }
    private var currentName: String { screens.first { $0.dashboardId == host.screenSet?.selectedDashboardId }?.name ?? "No screens installed" }
    private var compact: Bool { !settingsOpen && path.isEmpty }
    private var preferredWidth: CGFloat { wide ? min(1100, windowSize.width - 80) : min(580, windowSize.width - 32) }
    private var preferredHeight: CGFloat {
        let available = max(200, windowSize.height - 96)
        return compact ? min(headerHeight + rowsHeight + 56, available) : available
    }
    var body: some View {
        ZStack {
            if wide { split.transition(.identity) }
            else if settingsOpen { settingsStack.transition(.identity) }
            else { welcomeStack.transition(.identity) }
        }
        // An ideal size requests the preferred sheet bounds without forcing the navigation
        // container beyond the smaller proposal iPadOS may supply to a presented sheet.
        .frame(minWidth: 0, idealWidth: preferredWidth, maxWidth: preferredWidth,
               minHeight: 0, idealHeight: preferredHeight, maxHeight: preferredHeight)
        .modifier(DeviceMenuPresentation(height: preferredHeight))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: settingsOpen)
        .onAppear {
            updateSize()
            if let initialPage { settingsOpen = true; selection = initialPage; if initialPage != .settings { path = [initialPage] } }
            else { selection = catalog.showsTV ? .googleTV : catalog.usesCalendar ? .googleCalendar : .display }
        }
        .onReceive(clock) { _ in updateSize() }
        .tint(.blue)
    }
    private func updateSize() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }), let window = scene.windows.first(where: \.isKeyWindow) else { return }
        windowSize = CGSize(width: window.bounds.width, height: window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom)
    }
    private var close: some View { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .regular)).foregroundStyle(Color.primary) }.tint(.primary).accessibilityLabel("Close") }
    @ViewBuilder private func detailClose(_ page: DeviceSetupPage) -> some View {
        if #available(iOS 18, *) { close }
        else if page != .display { close }
    }
    private var back: some View { Button { settingsOpen = false; path = [] } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .regular)).foregroundStyle(Color.primary) }.tint(.primary).accessibilityLabel("Back to Welcome") }
    private var welcomeStack: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to Screenpunk").font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(host.settingsSnapshot?.value.displayName ?? host.runtime.profile.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let image = UIImage(named: "Screenpunk76x76") ?? UIImage(named: "AppIcon") {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                }.padding(.horizontal, 28).padding(.vertical, 24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                Divider().opacity(0.5)
                ScrollView {
                    VStack(spacing: 22) {
                        row("Come back anytime", subtitle: "Hold two fingers on the screen for five seconds to open this menu.", icon: "hand.tap", disclosure: false)
                        NavigationLink(value: DeviceSetupPage.guided) { row("Lock Screenpunk on screen", subtitle: "Guided Access · Kiosk mode", icon: "lock.display", disclosure: true) }.buttonStyle(.plain)
                        if screens.count > 1 {
                            NavigationLink(value: DeviceSetupPage.screens) { row("Current screen", subtitle: currentName, icon: "rectangle", disclosure: true, detail: "\(screens.count) screens") }.buttonStyle(.plain)
                        } else { row("Current screen", subtitle: currentName, icon: "rectangle", disclosure: false) }
                    }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { settingsOpen = true; path = [] } label: { Image(systemName: "gearshape").font(.system(size: 17, weight: .regular)).foregroundStyle(Color.primary) }.tint(.primary).accessibilityLabel("Settings") }
                ToolbarItem(placement: .topBarTrailing) { close }
            }
            .navigationDestination(for: DeviceSetupPage.self) { page in destination(page).navigationTitle(title(page)).navigationBarTitleDisplayMode(.large).toolbar { ToolbarItem(placement: .topBarTrailing) { detailClose(page) } } }
        }
    }
    private var settingsStack: some View {
        NavigationStack(path: $path) {
            settingsList.navigationTitle("Settings").navigationBarTitleDisplayMode(.large)
                .toolbar { ToolbarItem(placement: .topBarLeading) { back }; ToolbarItem(placement: .topBarTrailing) { close } }
                .navigationDestination(for: DeviceSetupPage.self) { page in destination(page).navigationTitle(title(page)).navigationBarTitleDisplayMode(.large).toolbar { ToolbarItem(placement: .topBarTrailing) { detailClose(page) } } }
        }
    }
    private var split: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if catalog.showsTV || catalog.usesCalendar {
                    Section("Connections") {
                        if catalog.showsTV { Label("Google TV", systemImage: "tv").tag(DeviceSetupPage.googleTV) }
                        if catalog.usesCalendar { Label("Google Calendar", systemImage: "calendar").tag(DeviceSetupPage.googleCalendar) }
                    }
                }
                Section("This device") { Label("Display and behavior", systemImage: "sun.max").tag(DeviceSetupPage.display) }
            }.navigationTitle("Settings").modifier(DeviceMenuSidebarToolbar()).navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    if #available(iOS 26, *) { back.buttonStyle(.glass).buttonBorderShape(.circle).padding(.top, 8) } else { back }
                } }
        } detail: {
            NavigationStack {
                destination(selection ?? .display).navigationTitle(title(selection ?? .display)).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { detailClose(selection ?? .display) } }
            }.id(selection)
        }
    }
    private var settingsList: some View {
        Form {
            if catalog.showsTV || catalog.usesCalendar {
                Section("Connections") {
                    if catalog.showsTV { NavigationLink(value: DeviceSetupPage.googleTV) {
                        Label { VStack(alignment: .leading, spacing: 4) { Text("Google TV"); Text(catalog.usesTV ? "TV connection and pairing" : "Not used by any screen").font(.subheadline).foregroundStyle(.secondary) } } icon: { Image(systemName: "tv").foregroundStyle(.blue) }
                    } }
                    if catalog.usesCalendar { NavigationLink(value: DeviceSetupPage.googleCalendar) {
                        Label { VStack(alignment: .leading, spacing: 4) { Text("Google Calendar"); Text("Calendar connection").font(.subheadline).foregroundStyle(.secondary) } } icon: { Image(systemName: "calendar").foregroundStyle(.blue) }
                    } }
                }
            }
            Section("This device") {
                NavigationLink(value: DeviceSetupPage.display) { Label { VStack(alignment: .leading, spacing: 4) { Text("Display and behavior"); Text("Brightness and screen preferences").font(.subheadline).foregroundStyle(.secondary) } } icon: { Image(systemName: "sun.max").foregroundStyle(.blue) } }
            }
        }
    }
    @ViewBuilder private func destination(_ page: DeviceSetupPage) -> some View {
        switch page {
        case .settings: settingsList
        case .googleTV: DeviceGoogleTVSettings { connectionsRevision = UUID(); onConnectionsChanged() }
        case .googleCalendar: Form { Section { Text("Google Calendar is not available in this device build yet."); Text("This screen requests Google Calendar. Account sign-in and calendar selection will be available when the connector is implemented.").foregroundStyle(.secondary) } }
        case .display: DeviceLocalSettingsSheet(host: host, embedded: true)
        case .screens: List(screens, id: \.dashboardId) { screen in Button { host.selectScreen(screen.dashboardId); if host.errorMessage == nil { dismiss() } } label: { HStack { Text(screen.name); Spacer(); if screen.dashboardId == host.screenSet?.selectedDashboardId { Image(systemName: "checkmark") } } } }
        case .guided: ScrollView { VStack(alignment: .leading, spacing: 24) {
            Text("Guided Access keeps this iPad in Screenpunk and helps prevent accidental exits.").foregroundStyle(.secondary)
            instruction("1. Turn it on", "Open Settings → Accessibility → Guided Access. Turn it on and set a passcode under Passcode Settings. Set Display Auto-Lock to Never if available.")
            instruction("2. Start it in Screenpunk", "Close this guide. Triple-click the top button, or the Home button on older iPads. Choose Guided Access if prompted, then tap Start. Leave Touch enabled for screen controls.")
            instruction("End a session", "Use the Guided Access shortcut, authenticate, then tap End. On iOS 18 or earlier, the authentication shortcut may use a double-click.")
            Button(guidedConfirmed ? "Setup confirmed" : "I’ve turned on Guided Access") { guidedConfirmed = true }.disabled(guidedConfirmed)
        }.padding(28) }
        }
    }
    private func title(_ page: DeviceSetupPage) -> String {
        switch page { case .settings: return "Settings"; case .googleTV: return "Google TV"; case .googleCalendar: return "Google Calendar"; case .display: return "Display and behavior"; case .screens: return "Choose a screen"; case .guided: return "Lock Screenpunk on screen" }
    }
    private func instruction(_ title: String, _ text: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary) } }
    private func row(_ title: String, subtitle: String, icon: String, disclosure: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(.blue).frame(width: 30, height: 22, alignment: .top)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if disclosure { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }
}

// The menu is available on every supported iPad. Only its presentation adopts
// newer APIs; older systems must not fall back to the unrelated display form.
private struct DeviceMenuPresentation: ViewModifier {
    let height: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.fitted.fitted(horizontal: true, vertical: true))
        } else if #available(iOS 16.4, *) {
            // Older iPads keep a system-sized sheet even when the content has a
            // smaller frame. Draw only our fitted panel, not that outer canvas.
            content
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .presentationBackground(.clear)
                .presentationDragIndicator(.hidden)
                .presentationDetents([.height(height)])
        } else {
            content.presentationDetents([.height(height)])
        }
    }
}

private struct DeviceMenuSidebarToolbar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}
#endif
