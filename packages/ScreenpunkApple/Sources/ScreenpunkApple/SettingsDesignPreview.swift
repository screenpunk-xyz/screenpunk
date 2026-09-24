#if DEBUG
import SwiftUI
import ScreenpunkCore
#if os(iOS)
import UIKit
#endif

// Preview fixtures only: no device host, Keychain, network calls, or saved app settings.
private struct DesignControlState: Decodable, Equatable {
    var scenario = "Partly ready"
    var screen = "TV remote"
    var count = 2
    var view = "menu"
    var guided = "Not set up"
    var appearance: String? = "System"
    var presentation: String? = "Current"
    var revision = 0
}
private struct PreviewRequirement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let required: Bool
    var connectorName: String = "Home Assistant"
    var settingsPage: PreviewPage? = nil
}
private enum PreviewPage: Hashable { case menu, screens, guided, settings, display, googleTV, googleAccounts, calendars(String), setup(String) }

private struct DeviceMenuDesignPreview: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var control = DesignControlState()
    @State private var selected = "TV remote"
    @State private var menuVisible = true
    @State private var availableWidth: CGFloat = 800
    @State private var wideSelection: PreviewPage? = .googleTV
    @State private var availableHeight: CGFloat = 1000
    @State private var welcomeHeaderHeight: CGFloat = 104
    @State private var welcomeRowsHeight: CGFloat = 320
    @State private var navigationPath: [PreviewPage] = []
    @State private var showingSettings = false
    private var page: PreviewPage {
        get { navigationPath.last ?? (showingSettings ? .settings : .menu) }
        nonmutating set {
            if newValue == .menu { showingSettings = false; navigationPath = [] }
            else if newValue == .settings { showingSettings = true; navigationPath = [] }
            else if newValue != page { navigationPath.append(newValue) }
        }
    }
    @State private var googleAccounts = ["Personal", "Work"]
    @State private var calendarChoices: Set<String> = []
    @State private var tvPaired = true
    @State private var channelsPaired = false
    @State private var tvAddress = "192.168.1.120"
    @State private var tvCode = ""
    @State private var waitingTVCode = false
    @State private var connectionPort = "38355"
    @State private var pairingPort = ""
    @State private var debuggingCode = ""
    @State private var tvFeedback: String?
    @State private var developerFeedback: String?
    @State private var previewPendingPairing = false
    @State private var showForgetTV = false
    @State private var completed: [String: Bool] = [:]
    @State private var permissionDraft = false
    @State private var settings = DeviceSettings()
    @State private var savedMessage: String?
    @State private var guidedConfirmed = false
    private let updates = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private var captionColor: Color {
#if os(iOS)
        Color(uiColor: .secondaryLabel)
#else
        Color(nsColor: .secondaryLabelColor)
#endif
    }
    private var validConnectionPort: Bool {
        guard !connectionPort.isEmpty, connectionPort.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(connectionPort) else { return false }
        return (1...65535).contains(port)
    }
    private var effectiveColorScheme: ColorScheme {
        control.appearance == "Dark" ? .dark : control.appearance == "Light" ? .light : systemColorScheme
    }
    private var accent: Color {
        effectiveColorScheme == .dark ? Color(red: 0.38, green: 0.61, blue: 1) : Color(red: 0.18, green: 0.36, blue: 0.85)
    }

    private var screens: [String] {
        guard control.scenario != "New device", control.count > 0 else { return [] }
        let choices = [control.screen] + ["TV remote", "Daily information", "Home controls", "Family photos", "Kitchen", "Weather", "Calendar", "Music", "Front door", "Lights", "Travel", "Quiet time"].filter { $0 != control.screen }
        return Array(choices.prefix(control.count))
    }
    private var requirements: [PreviewRequirement] {
        if selected == "TV remote" {
            return [.init(id: "volume", title: "Volume and mute", detail: "Pair this iPad with your Google TV to adjust the volume.", required: true, connectorName: "Google TV", settingsPage: .googleTV),
                    .init(id: "channels", title: "Channel selection", detail: "Pair developer access on your Google TV to use this screen’s channels.", required: true, connectorName: "Google TV", settingsPage: .googleTV),
                    .init(id: "power", title: "TV power", detail: "Pair developer access to use TV power controls.", required: false, connectorName: "Google TV", settingsPage: .googleTV)]
        }
        if ["Calendar", "Daily information"].contains(selected) {
            return [.init(id: "calendar", title: "Calendar connection", detail: "Connect Google Calendar and choose calendars for this screen.", required: true, connectorName: "Google Calendar", settingsPage: .googleAccounts)]
        }
        if selected == "Home controls" { return [.init(id: "home", title: "Home connection", detail: "Connect to Home Assistant and choose the devices this screen can control.", required: true)] }
        return []
    }
    private func ready(_ item: PreviewRequirement) -> Bool {
        if item.id == "calendar" { return calendarChoices.contains(where: { $0.hasPrefix(selected + "|") }) }
        if selected == "TV remote" { return item.id == "volume" ? tvPaired : channelsPaired }
        return completed[selected + ":" + item.id] ?? (control.scenario == "Ready" || control.scenario == "Needs attention" || (control.scenario == "Partly ready" && item.id == requirements.first?.id))
    }
    private var missing: [PreviewRequirement] { requirements.filter { $0.required && !ready($0) } }
    private var blocksScreen: Bool { !screens.isEmpty && !missing.isEmpty }
    private var guidedStatus: String { control.guided == "Active" ? "Active" : guidedConfirmed || control.guided == "Enabled, inactive" ? "Ready to start" : "Optional setup" }

    private func reloadControls() {
#if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
           let window = scene.windows.first(where: \.isKeyWindow) {
            availableWidth = window.bounds.width
            availableHeight = window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom
        }
#endif
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("design-state.json")
        guard let data = try? Data(contentsOf: url), let next = try? JSONDecoder().decode(DesignControlState.self, from: data), next != control else { return }
        control = next; selected = next.screen; completed = [:]; guidedConfirmed = false; savedMessage = nil
        menuVisible = next.view != "screen"
        page = ["settings", "googleTV"].contains(next.view) ? .settings : .menu
        if next.view == "googleTV" { page = .googleTV; wideSelection = .googleTV }
        tvPaired = next.scenario != "New device"
        channelsPaired = next.scenario == "Ready"
        previewPendingPairing = next.scenario == "Needs attention"
        developerFeedback = previewPendingPairing ? "TV accepted pairing. Check Connection port, then Retry connection. This failure is simulated." : nil
    }
    private func openMenu() { page = .menu; savedMessage = nil; menuVisible = true }
    private func advance(_ offset: Int) {
        guard !menuVisible, screens.count > 1, let index = screens.firstIndex(of: selected) else { return }
        selected = screens[(index + offset + screens.count) % screens.count]
    }
    private func openRequirement(_ item: PreviewRequirement) {
        if let destination = item.settingsPage {
            page = .settings; page = destination; wideSelection = destination; menuVisible = true
            return
        }
        permissionDraft = ready(item); savedMessage = nil; page = .setup(item.id); menuVisible = true
    }

    var body: some View {
        previewGestures {
            ZStack {
                backgroundScreen
                    .allowsHitTesting(!blocksScreen && !menuVisible)
                    .accessibilityHidden(blocksScreen || menuVisible)
                if blocksScreen && !menuVisible { requirementGate }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            availableHeight = size.height; availableWidth = size.width
        }
        .sheet(isPresented: $menuVisible) {
            sheetContents
                .environment(\.colorScheme, effectiveColorScheme)
        }
        .onAppear(perform: reloadControls)
        .onReceive(updates) { _ in reloadControls() }
        .accessibilityAction(named: "Open Screenpunk menu", openMenu)
        .accessibilityAction(named: "Next screen") { advance(1) }
    }

    @ViewBuilder private func previewGestures<Content: View>(@ViewBuilder content: () -> Content) -> some View {
#if os(iOS)
        PreviewGestureHost(content: content().environment(\.colorScheme, effectiveColorScheme), hold: openMenu, swipe: advance)
#else
        content()
#endif
    }
    private var backgroundScreen: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.24), Color(red: 0.04, green: 0.07, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                HStack { Image(systemName: "rectangle.stack.fill"); Text("Screenpunk").font(.headline); Spacer() }.foregroundStyle(.white.opacity(0.65))
                Spacer().frame(height: 18)
                Text(screens.isEmpty ? "Your screens start here" : selected).font(.system(size: 38, weight: .bold))
                Text(screens.isEmpty ? "Add a screen from Screenpunk on your Mac." : selected == "TV remote" ? "What would you like to watch?" : "A little space for your everyday.").font(.title3).foregroundStyle(.white.opacity(0.7))
                if !screens.isEmpty {
                    if control.scenario == "Needs attention", !requirements.isEmpty {
                        Label("Connection unavailable · check Settings", systemImage: "wifi.exclamationmark").font(.callout).padding().background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    HStack(spacing: 18) {
                        screenTile(selected == "TV remote" ? "CNBC" : "Today", icon: selected == "TV remote" ? "play.tv.fill" : "sun.max.fill", color: .blue)
                        screenTile(selected == "TV remote" ? "Power" : "At a glance", icon: selected == "TV remote" ? "power" : "calendar", color: .indigo)
                    }
                }
                Spacer()
            }.padding(40).foregroundStyle(.white)
        }
    }
    private func screenTile(_ title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 26) { Image(systemName: icon).font(.largeTitle); Text(title).font(.title2.bold()) }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.42), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var appIcon: some View {
#if os(iOS)
        if let icon = UIImage(contentsOfFile: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenpunkAppIcon.png").path) {
            Image(uiImage: icon).resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityLabel("Screenpunk app icon")
        }
#endif
    }

    private var usesSplitSettings: Bool { availableWidth >= 1000 && showingSettings }
    @ViewBuilder private var sheetContents: some View {
        if #available(iOS 18, macOS 15, *), control.presentation != "iOS 16–17" {
            ZStack {
                if usesSplitSettings {
                    splitSettings.transition(.identity)
                } else if showingSettings {
                    compactSettings.transition(.identity)
                } else {
                    menuPanel.transition(.identity)
                }
            }
            .frame(width: usesSplitSettings ? min(1100, availableWidth - 80) : 580,
                   height: page == .menu
                    ? min(welcomeHeaderHeight + welcomeRowsHeight + 44, availableHeight - 64)
                    : max(400, availableHeight - 64))
            .presentationSizing(.fitted.fitted(horizontal: true, vertical: true))
            .animation(.easeInOut(duration: 0.55), value: showingSettings)

        } else {
#if os(iOS)
            Group {
                if showingSettings { compactSettings } else { menuPanel }
            }.presentationDetents([.height(page == .menu
                ? min(welcomeHeaderHeight + welcomeRowsHeight + 44, availableHeight - 64)
                : max(400, availableHeight - 64))])
#else
            menuPanel
#endif
        }
    }
    @available(iOS 18, macOS 15, *)
    private var splitSettings: some View {
        NavigationSplitView {
            List(selection: $wideSelection) {
                Section("Connections") {
                    Label("Google TV", systemImage: "tv").tag(PreviewPage.googleTV)
                    Label("Google Calendar", systemImage: "calendar").tag(PreviewPage.googleAccounts)
                }
                Section("This device") {
                    Label("Display and behavior", systemImage: "sun.max").tag(PreviewPage.display)
                }
            }
            .navigationTitle("Settings")
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, macOS 26, *), control.presentation == nil || control.presentation == "Current" {
                        Button { page = .menu } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                            .padding(.top, 8)
                            .accessibilityLabel("Back to Welcome")
                    } else {
                        Button { page = .menu } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back to Welcome")
                    }
                }
            }
        } detail: {
            NavigationStack {
                panelContents(for: wideSelection ?? .googleTV)
                    .navigationTitle(title(for: wideSelection ?? .googleTV))
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .navigationDestination(for: PreviewPage.self) { destination in
                        panelContents(for: destination)
                            .navigationTitle(title(for: destination))
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { closeButton } }
            }.id(wideSelection)
        }
        .tint(accent)
        .foregroundStyle(Color.primary)
    }

    private var compactSettings: some View {
        NavigationStack(path: Binding(
            get: { navigationPath },
            set: { navigationPath = $0 }
        )) {
            panelContents(for: .settings)
                .navigationTitle("Settings")
#if os(iOS)
                .navigationBarTitleDisplayMode(.large)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { page = .menu } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back to Welcome")
                    }
                    ToolbarItem(placement: .confirmationAction) { closeButton }
                }
                .navigationDestination(for: PreviewPage.self) { destination in
                    panelContents(for: destination)
                        .navigationTitle(title(for: destination))
#if os(iOS)
                        .navigationBarTitleDisplayMode(.large)
#endif
                        .toolbar { ToolbarItem(placement: .confirmationAction) { closeButton } }
                }
        }.tint(accent).foregroundStyle(Color.primary)
    }

    private var menuPanel: some View {
        NavigationStack(path: $navigationPath) {
            panelContents(for: .menu)
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { page = .settings } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .confirmationAction) { closeButton }
                }
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
#endif
                .navigationDestination(for: PreviewPage.self) { destination in
                    panelContents(for: destination)
                        .navigationTitle(title(for: destination))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { closeButton }
                        }
#if os(iOS)
                        .navigationBarTitleDisplayMode(.large)
                        .toolbar(.visible, for: .navigationBar)
#endif
                }
        }
        .tint(accent)
        .foregroundStyle(Color.primary)
    }
    private var closeButton: some View {
        Button { menuVisible = false; page = .menu } label: {
            Image(systemName: "xmark")
        }.accessibilityLabel("Close")
    }

    private func panelContents(for destination: PreviewPage) -> some View {
        VStack(spacing: 0) {
            if destination == .menu {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(for: destination)).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(destination == .menu ? "Office iPad" : "Screenpunk")
                            .font(.subheadline).foregroundStyle(captionColor)
                    }
                    Spacer(minLength: 0)
                    if destination == .menu { appIcon.fixedSize() }
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { welcomeHeaderHeight = $0 }
                Divider().opacity(0.5)
            }
            if isConnectionPage(destination) {
                connectionForm(for: destination)
            } else if destination == .display {
                DeviceSettingsEditor(settings: $settings, manifest: nil)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { pageContent(for: destination) }
                        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, destination == .menu ? 48 : 24).frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if destination == .menu { welcomeRowsHeight = height }
                        }
                }
            }
        }
    }
    private func title(for destination: PreviewPage) -> String {
        switch destination {
        case .menu: return "Welcome to Screenpunk"
        case .screens: return "Choose a screen"
        case .guided: return "Lock Screenpunk on screen"
        case .settings: return "Settings"
        case .display: return "Display and behavior"
        case .googleTV: return "Google TV"
        case .googleAccounts: return "Google Calendar"
        case .calendars(let screen): return screen
        case .setup(let id): return requirements.first { $0.id == id }?.title ?? "Screen setup"
        }
    }
    @ViewBuilder private func pageContent(for destination: PreviewPage) -> some View {
        switch destination {
        case .menu:
            menuRow("Come back anytime", subtitle: "Hold two fingers on the screen for five seconds to open this menu.", icon: "hand.tap", chevron: false)
            Button { page = .guided } label: {
                menuRow("Lock Screenpunk on screen", subtitle: "Guided Access · Kiosk mode", icon: "lock.display", chevron: true)
            }.buttonStyle(.plain)
            if screens.isEmpty {
                menuRow("No screens yet", subtitle: "Add your first screen from your Mac", icon: "rectangle.badge.plus", chevron: false)
            } else if screens.count > 1 {
                Button { page = .screens } label: { menuRow("Current screen", subtitle: selected, icon: "rectangle.stack", chevron: true, detail: "\(screens.count) screens") }.buttonStyle(.plain)
            } else {
                menuRow("Current screen", subtitle: selected, icon: "rectangle.stack", chevron: false)
            }
        case .screens:
            Text("Choose a screen to open it. You can also swipe with two fingers to move between screens.").foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                ForEach(screens, id: \.self) { name in
                    Button { selected = name; menuVisible = false; page = .menu } label: {
                        HStack {
                            Image(systemName: "rectangle").font(.title3).frame(width: 30)
                            Text(name).font(.headline)
                            Spacer()
                            if name == selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityValue(name == selected ? "Current screen" : "")
                }
            }
        case .guided:
            Text("Guided Access keeps this iPad in Screenpunk and helps prevent accidental exits. It’s optional.").foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
            if control.guided == "Active" { Label("Guided Access is active", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            instruction("1", "Turn it on in iPad Settings", "Open Settings → Accessibility → Guided Access. Turn it on. In Passcode Settings, choose a passcode and, optionally, Face ID or Touch ID.")
            instruction("2", "Start it in Screenpunk", "Return here and close this menu. Triple-click the top button, or the Home button on older iPads. Choose Guided Access if prompted, then tap Start. Keep Touch enabled for screen controls and two-finger gestures.")
            instruction("3", "End a session", "Triple-click the same button, authenticate, then tap End. On iPadOS 18 or earlier, use a double-click to authenticate instead.")
            Text("For an always-on display, review Display Auto-Lock in Guided Access settings.").font(.footnote).foregroundStyle(captionColor)
            Link("Apple’s Guided Access instructions", destination: URL(string: "https://support.apple.com/en-us/111795")!).font(.subheadline)
        case .settings, .googleTV, .googleAccounts, .calendars, .display: EmptyView()
        case .setup(let id):
            if let item = requirements.first(where: { $0.id == id }) {
                Text(item.detail).foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
                Label(item.required ? "Required by \(selected)" : "Optional for \(selected)", systemImage: "rectangle.stack").font(.subheadline)
                Toggle("Allow for this screen", isOn: $permissionDraft).padding(18).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                Text("Design preview: this stands in for the connection and approval steps.").font(.footnote).foregroundStyle(captionColor)
                Button("Save setup") {
                    let key = selected + ":" + item.id
                    completed[key] = permissionDraft
                    savedMessage = "Saved for this screen"
                    if missing.isEmpty { menuVisible = false; page = .menu }
                    else { page = .settings }
                }.buttonStyle(.borderedProminent)
                if let savedMessage { Label(savedMessage, systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
        }
    }
    private func isConnectionPage(_ destination: PreviewPage) -> Bool {
        switch destination {
        case .settings, .googleTV, .googleAccounts, .calendars: return true
        default: return false
        }
    }
    private var calendarScreens: [String] {
        screens.filter { ["Calendar", "Daily information"].contains($0) }
    }
    private func selectionBinding(_ key: String, calendars: Bool) -> Binding<Bool> {
        Binding(get: { calendarChoices.contains(key) }, set: { enabled in
            if enabled { calendarChoices.insert(key) } else { calendarChoices.remove(key) }
        })
    }
    @ViewBuilder private func connectionForm(for destination: PreviewPage) -> some View {
        Form {
            switch destination {
            case .settings:
                Section {
                    NavigationLink(value: PreviewPage.googleTV) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Google TV")
                                Text(tvPaired && channelsPaired ? "Living room TV · Ready" : tvPaired || channelsPaired ? "Living room TV · Finish setup" : "Not connected").font(.subheadline).foregroundStyle(captionColor)
                            }
                        } icon: { Image(systemName: "tv").foregroundStyle(accent) }
                    }
                    NavigationLink(value: PreviewPage.googleAccounts) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Google Calendar")
                                Text(googleAccounts.isEmpty ? "Not connected" : "\(googleAccounts.count) accounts · Calendars").font(.subheadline).foregroundStyle(captionColor)
                            }
                        } icon: { Image(systemName: "calendar").foregroundStyle(accent) }
                    }
                } header: { Text("Connections") }
                Section("This device") {
                    NavigationLink(value: PreviewPage.display) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Display and behavior")
                                Text("Brightness and screen preferences").font(.subheadline).foregroundStyle(captionColor)
                            }
                        } icon: { Image(systemName: "sun.max").foregroundStyle(accent) }
                    }
                }
            case .googleTV:
                Section("Your TV") {
                    DisclosureGroup("Basic setup guide") {
                        Text("Connect the iPad and TV to the same network. Find the TV’s IP address in Settings → Network & Internet. Pair volume and mute using the code shown on the TV.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IP address").font(.caption).foregroundStyle(captionColor)
                        TextField("TV IP address", text: $tvAddress)
                    }
                    Button("Update TV address") {
                        tvFeedback = tvAddress.isEmpty ? "Enter a valid TV IP address." : "Address saved in preview. Pairing and permissions preserved."
                    }.disabled(!tvPaired)
                    Text("Verifies the same TV before saving. Pairing and permissions are kept.").font(.footnote).foregroundStyle(captionColor)
                    HStack {
                        Label(tvPaired ? "Connected" : "Not connected", systemImage: tvPaired ? "checkmark.circle" : "circle")
                        Spacer()
                        if tvPaired { Button("Disconnect", role: .destructive) { tvPaired = false } }
                        else { Button("Pair") { tvPaired = true; tvFeedback = "Volume and mute paired in preview." } }
                    }
                    if let tvFeedback { Text(tvFeedback).font(.footnote) }
                }
                Section {
                    DisclosureGroup("1. Enable Developer options on your TV") {
                        Text("Open Settings → System → About. Select Android TV OS build repeatedly until Developer options are enabled.")
                    }
                    DisclosureGroup("2. Turn on wireless debugging") {
                        Text("Enable Wireless debugging on your trusted home network. Its main page shows Connection port. Choose Pair device with pairing code for Pairing port and a six-digit code.")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Connection port").font(.caption).foregroundStyle(captionColor)
                            TextField("e.g. 38355", text: $connectionPort).accessibilityLabel("Connection port")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pairing port").font(.caption).foregroundStyle(captionColor)
                            TextField("For new pairing", text: $pairingPort).accessibilityLabel("Pairing port")
                        }
                    }
                    Text("Connection port: on the main Wireless debugging page. Pairing port: in ‘Pair device with pairing code’; only needed when pairing.").font(.footnote).foregroundStyle(captionColor)
                    if !validConnectionPort { Text("Enter a Connection port from 1–65535.").font(.footnote).foregroundStyle(.red) }
                    if channelsPaired {
                        Button("Verify and save connection") { developerFeedback = "Connection saved in preview. Existing pairing and screen permissions preserved." }
                            .disabled(!validConnectionPort)
                        Text("Saves the IP address above and Connection port after checking the existing TV identity. No pairing code needed.").font(.footnote).foregroundStyle(captionColor)
                    } else if !previewPendingPairing {
                        SecureField("Six-digit pairing code", text: $debuggingCode)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Developer pairing").font(.caption).foregroundStyle(captionColor)
                            Text(previewPendingPairing ? "Paired · connection incomplete" : channelsPaired ? "Connected" : "Not connected")
                        }
                        Spacer()
                        if previewPendingPairing {
                            Button("Retry connection") { channelsPaired = true; previewPendingPairing = false; developerFeedback = "Connection saved in preview. No new pairing code needed." }.disabled(!validConnectionPort)
                        } else if channelsPaired {
                            Button("Disconnect", role: .destructive) { channelsPaired = false; developerFeedback = "Preview connection removed." }
                        } else {
                            Button("Pair") { previewPendingPairing = true; debuggingCode = ""; developerFeedback = "TV accepted pairing. Simulated connection failure: check Connection port, then Retry connection." }
                                .disabled(!validConnectionPort || pairingPort.isEmpty || debuggingCode.count != 6)
                        }
                    }
                    if let developerFeedback { Text(developerFeedback).font(.footnote) }
                } header: { Text("Channels and power") } footer: {
                    Text("Wireless debugging grants this iPad debugging access to the TV. Screenpunk uses it for the channels and power controls defined by your screens.")
                }
                Section("Connection help") {
                    Button("Check connections") { developerFeedback = "Preview check complete. No TV contacted." }
                    Text("If the TV’s address changed, update it above, then verify and save each connection. If only wireless debugging’s port changed, update Connection port and verify and save. Disconnect removes saved trust and permissions; it is not needed for an address change.").font(.footnote).foregroundStyle(captionColor)
                    Button("Forget Google TV", role: .destructive) { showForgetTV = true }
                        .confirmationDialog("Forget this TV’s connections?", isPresented: $showForgetTV, titleVisibility: .visible) {
                            Button("Forget TV", role: .destructive) { tvPaired = false; channelsPaired = false; previewPendingPairing = false }
                        }
                    Text("Interactive design preview. Pair simulates an incomplete connection so Retry can be reviewed; no TV is contacted.").font(.footnote).foregroundStyle(captionColor)
                }
            case .googleAccounts:
                Section {
                    ForEach(googleAccounts, id: \.self) { account in
                        HStack {
                            Label(account, systemImage: "person.crop.circle")
                            Spacer()
                            Text("Connected").font(.subheadline).foregroundStyle(captionColor)
                        }
                    }.onDelete { offsets in
                        let removed = offsets.map { googleAccounts[$0] }
                        googleAccounts.remove(atOffsets: offsets)
                        calendarChoices = calendarChoices.filter { key in !removed.contains(where: { key.contains("|" + $0 + "|") }) }
                    }
                    Button {
                        var number = 3
                        while googleAccounts.contains("Account \(number)") { number += 1 }
                        googleAccounts.append("Account \(number)")
                    } label: { Label("Connect a calendar account", systemImage: "plus") }
                } header: { Text("Calendar accounts") } footer: { Text("Connect calendars from multiple Google accounts. Swipe an account to remove its calendar connection.") }
                Section {
                    ForEach(calendarScreens, id: \.self) { screen in
                        NavigationLink(value: PreviewPage.calendars(screen)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(screen)
                                Text("\(calendarChoices.filter { $0.hasPrefix(screen + "|") }.count) calendars selected").font(.subheadline).foregroundStyle(captionColor)
                            }
                        }
                    }
                    if calendarScreens.isEmpty { Text("Add a calendar screen to choose which calendars it can show.").foregroundStyle(captionColor) }
                } header: { Text("Calendars by screen") } footer: { Text("A screen can show calendars from more than one account.") }
                Section { Text("Design preview · accounts and calendars are samples. Adding an account does not sign in to Google.").font(.footnote).foregroundStyle(captionColor) }
            case .calendars(let screen):
                ForEach(googleAccounts, id: \.self) { account in
                    Section(account) {
                        ForEach(["Primary calendar", "Shared calendar"], id: \.self) { calendar in
                            Toggle(calendar, isOn: selectionBinding(screen + "|" + account + "|" + calendar, calendars: true))
                        }
                    }
                }
                Section { Text("Only the selected calendars are shared with this screen.").font(.footnote).foregroundStyle(captionColor) }
            default: EmptyView()
            }
        }
    }

    private func menuRow(_ title: String, subtitle: String, icon: String, chevron: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 22, alignment: .top)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(Color.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let detail { Text(detail).font(.caption).foregroundStyle(captionColor) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(captionColor).padding(.leading, 4) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18)).contentShape(RoundedRectangle(cornerRadius: 18))
    }
    private func instruction(_ number: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).foregroundStyle(accent).frame(width: 30, height: 30).background(accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); Text(body).font(.subheadline).foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var requirementGate: some View {
        ZStack {
            Color.black.opacity(0.34).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(accent)
                Text("Set up \(missing.first?.connectorName ?? selected)").font(.title2.bold())
                Text("A few things need to be connected before you can use this screen.").foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
                if #available(iOS 26, macOS 26, *), control.presentation == nil || control.presentation == "Current" {
                    Button("Open settings") { if let first = missing.first { openRequirement(first) } }
                        .buttonStyle(.glass).controlSize(.large)
                } else {
                    Button("Open settings") { if let first = missing.first { openRequirement(first) } }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Divider()
                Text("You can swipe with two fingers to another screen, or hold two fingers for five seconds to open the Screenpunk menu.").font(.footnote).foregroundStyle(captionColor).fixedSize(horizontal: false, vertical: true)
            }.padding(30).frame(maxWidth: 490).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).padding(24)
        }.accessibilityAddTraits(.isModal)
    }
}

#if os(iOS)
private struct PreviewGestureHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let hold: () -> Void
    let swipe: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(hold: hold, swipe: swipe) }
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.numberOfTouchesRequired = 2; hold.minimumPressDuration = 5; hold.cancelsTouchesInView = false; hold.delegate = context.coordinator
        controller.view.addGestureRecognizer(hold)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let gesture = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            gesture.numberOfTouchesRequired = 2; gesture.direction = direction; gesture.cancelsTouchesInView = false; gesture.delegate = context.coordinator
            controller.view.addGestureRecognizer(gesture)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content; context.coordinator.hold = hold; context.coordinator.swipe = swipe
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var hold: () -> Void; var swipe: (Int) -> Void
        init(hold: @escaping () -> Void, swipe: @escaping (Int) -> Void) { self.hold = hold; self.swipe = swipe }
        @objc func held(_ sender: UILongPressGestureRecognizer) { if sender.state == .began { hold() } }
        @objc func swiped(_ sender: UISwipeGestureRecognizer) { if sender.state == .ended { swipe(sender.direction == .left ? 1 : -1) } }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

struct SettingsDesignPreview_Previews: PreviewProvider {
    static var previews: some View { DeviceMenuDesignPreview().previewDisplayName("Screenpunk menu and onboarding") }
}
#endif
