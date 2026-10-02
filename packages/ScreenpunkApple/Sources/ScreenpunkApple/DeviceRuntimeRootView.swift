import SwiftUI
import ScreenpunkCore
#if canImport(UIKit)
import UIKit
#endif

/// iOS device: advertise over TLS 1.3, pair with one owner, then show the deployed dashboard.
@MainActor
public struct DeviceRuntimeRootView: View {
    @State private var fallback: DeviceRuntime
    @State private var confirmError: String?
    @State private var showDeviceMenu = false
    @State private var showSettings = false
#if os(iOS)
    @State private var onboardingRoute = "welcome"
    @State private var pairingSessionCode: String?
    @State private var showScreens = false
    @State private var showOnboarding = false
    @State private var generalAfterOnboarding = false
    @State private var onboardingAfterDismissal = false
    @State private var initialSetupPage: DeviceSetupPage?
    @State private var connectorRevision = UUID()
#endif
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var brightness = DeviceBrightnessController()
    @State private var renderedSettingsRevision: String?
    @State private var brightnessSettingsRevision: String?
    @State private var genericConnections: ConnectionRuntime?
    @State private var genericRuntimeID = UUID()
#if canImport(Network) && canImport(Security)
    @StateObject private var host: DeviceLANHost
#endif

    public init(runtime: DeviceRuntime) {
        _fallback = State(initialValue: runtime)
#if canImport(Network) && canImport(Security)
        _host = StateObject(wrappedValue: DeviceLANHost(runtime: runtime))
#endif
    }

#if canImport(Network) && canImport(Security)
    public init(host: DeviceLANHost) {
        _fallback = State(initialValue: host.runtime)
        _host = StateObject(wrappedValue: host)
    }
#endif

    /// Name the Mac shows for this device. iOS 16+ returns the generic model
    /// name ("iPhone", "iPad") unless the app holds the user-assigned-name
    /// entitlement; either is a human label, never an address.
    public static func localDeviceName() -> String {
#if canImport(UIKit) && !os(watchOS)
        return DeviceDisplayName.sanitize(UIDevice.current.name) ?? "iPhone"
#else
        return "This iPhone"
#endif
    }

    public static func unpairedLoopback() -> DeviceRuntimeRootView {
        DeviceRuntimeRootView(runtime: unpairedRuntime())
    }

    public static func unpairedRuntime() -> DeviceRuntime {
        let identity = PairingIdentityFactory.make(role: .device)
        var profile = DeviceProfile(deviceId: DeviceInstallIdentity.pendingID, name: localDeviceName(), model: DeviceModelName.current)
#if os(iOS)
        let bounds = UIScreen.main.bounds
        profile.width = Int(min(bounds.width, bounds.height))
        profile.height = Int(max(bounds.width, bounds.height))
#endif
        let ad = AdvertisedDevice(
            deviceId: profile.deviceId,
            host: "127.0.0.1",
            port: 7843,
            source: .advertised
        )
        var runtime = DeviceRuntime(identity: identity, profile: profile, advertisement: ad)
#if !canImport(Network) || !canImport(Security)
        runtime.advertise(on: LoopbackDiscovery.shared)
#endif
        return runtime
    }

    public var body: some View {
        Group {
#if canImport(Network) && canImport(Security)
            lanBody
                .onAppear { host.start(); host.setForeground(scenePhase == .active); applyBrightness() }
                .onChange(of: host.settingsSnapshot?.revision) { _ in applyBrightness() }
                .onChange(of: host.runtime.isPaired) { _ in applyBrightness() }
                .onChange(of: scenePhase) { phase in
                    host.setForeground(phase == .active)
                    if phase == .active { host.resume() }
                    applyBrightness()
                }
                .onReceive(brightness.$isApplied) { _ in
                    Task { @MainActor in acknowledgeSettings() }
                }
                .onDisappear { brightness.stop(); host.setForeground(false) }
#if os(iOS)
                .modifier(DeviceMenuContainer(isPresented: $showDeviceMenu, onDismiss: presentQueuedOnboarding) {
                    DeviceSetupMenu(host: host, initialPage: initialSetupPage, onConnectionsChanged: { connectorRevision = UUID() }, onConnect: queueOnboarding)
                        .onDisappear { initialSetupPage = nil; connectorRevision = UUID() }
                })
                .onAppear {
                    // Existing paired devices adopt the simplified capability model without re-pairing.
                    var basic = GoogleTVConfiguration.load()
                    if basic.pin.count == 32 { basic.automaticScreenAccess = true; try? basic.save() }
                    var developer = GoogleTVADBConfiguration.load()
                    if developer.serverPin.count == 32 { developer.automaticScreenAccess = true; try? developer.save() }
                }
#endif
                #if os(iOS)
                .sheet(isPresented: $showSettings, onDismiss: presentQueuedOnboarding) { NavigationStack { DeviceProductionGeneral(host: host, connect: queueOnboarding).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showSettings = false } } } } }
#else
                .sheet(isPresented: $showSettings) { DeviceLocalSettingsSheet(host: host) }
#endif
#if os(iOS)
                .fullScreenCover(isPresented: $showOnboarding, onDismiss: { if generalAfterOnboarding { generalAfterOnboarding = false; showSettings = true } }) { NavigationStack { productionLanding.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { if host.server != nil { host.cancelPairing() }; pairingSessionCode = nil; onboardingRoute = "welcome"; showOnboarding = false } } } } }
                .sheet(isPresented: $showScreens) { NavigationStack { DeviceProductionScreens(host: host, opened: { showScreens = false }).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showScreens = false } } } } }
#endif
                .task(id: "\(host.runtime.activeRevision ?? "none"):\(host.genericConnectionGeneration.uuidString)") {
                    if let genericConnections { try? await genericConnections.clearCredentials() }
                    genericConnections = nil
                    genericRuntimeID = UUID()
                    guard let server = host.server else { return }
                    let runtime = try? await server.makeGenericConnectionRuntime()
                    guard !Task.isCancelled else {
                        if let runtime { try? await runtime.clearCredentials() }
                        return
                    }
                    genericConnections = runtime
                    genericRuntimeID = UUID()
                }
#else
            localBody
#endif
        }
    }

#if canImport(Network) && canImport(Security)
    private var lanBody: some View {
        Group {
            if let revision = host.runtime.activeRevision, !localOnboardingActive {
                GeometryReader { geometry in
                    let profile = host.runtime.profile
                    let width = CGFloat(profile.width), height = CGFloat(profile.height)
                    let rotate = (geometry.size.width > geometry.size.height) != (width > height)
                    let displayWidth = rotate ? height : width
                    let displayHeight = rotate ? width : height
                    let scale = min(geometry.size.width / displayWidth, geometry.size.height / displayHeight)
                    deployedDashboard(revision: revision, package: host.activePackage) { showSettings = true }
                        .frame(width: width, height: height)
                        .rotationEffect(.degrees(rotate ? 90 : 0))
                        .scaleEffect(scale)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }.ignoresSafeArea().background(.black)
                    .deviceScreenSwipes(screens: host.screenSet?.screens.map(\.entry) ?? [],
                                        selectedID: host.screenSet?.selectedDashboardId,
                                        enabled: !showDeviceMenu && !showSettings && host.pairingCode == nil) { offset in
                        host.advanceScreen(by: offset)
                    }
                    .ignoresSafeArea()
                    .accessibilityAction(named: "Next screen") { host.advanceScreen(by: 1) }
                    .accessibilityAction(named: "Previous screen") { host.advanceScreen(by: -1) }
            } else {
#if os(iOS)
                productionLanding
#else
                UnpairedHostView(detail: host.port == 0 ? nil : "TLS 1.3 · port \(host.port)", paired: host.runtime.isPaired)
#endif
            }
        }
        .allowsHitTesting((!legacyPairingOverlayActive || localOnboardingActive) && !showDeviceMenu)
        .accessibilityHidden((legacyPairingOverlayActive && !localOnboardingActive) || showDeviceMenu)
#if !os(iOS)
        .overlay {
            if showDeviceMenu {
                UnlinkPanelView(onUnlink: { showDeviceMenu = false; host.unlink() },
                    onDismiss: { showDeviceMenu = false }, screens: host.screenSet?.screens.map(\.entry) ?? [],
                    selectedDashboardId: host.screenSet?.selectedDashboardId,
                    onSettings: { showDeviceMenu = false; showSettings = true }) { dashboardId in
                        host.selectScreen(dashboardId)
                        if host.errorMessage == nil { showDeviceMenu = false }
                    }
            }
        }
#else
        .overlay {
            if !showDeviceMenu, !localOnboardingActive, !showOnboarding, host.pairingCode == nil, let missing = missingConnector {
                connectorGate(missing)
            }
        }
#endif
        .overlay {
            if let code = host.pairingCode, legacyPairingOverlayActive {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    PairingCodeView(code: code, waiting: host.awaitingControllerConfirm,
                                    onCancel: { host.cancelPairing() }) { host.confirm() }
                        .frame(maxWidth: 420).padding(24)
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .overlay(alignment: .bottom) {
            if host.errorMessage != nil && !localOnboardingActive {
                VStack(spacing: 8) {
                    Text(host.server == nil ? "The local connection could not start. Unlock this device, close Screenpunk, then open it again." : "The local connection could not start. Unlock this device and try again.")
                        .font(.footnote).multilineTextAlignment(.center)
                    if host.server != nil { Button("Try again") { host.resume() } }
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
            }
        }
    }

#endif

#if os(iOS)
    private func queueOnboarding() {
        onboardingAfterDismissal = true
        showDeviceMenu = false
        showSettings = false
    }

    private func presentQueuedOnboarding() {
        guard onboardingAfterDismissal else { return }
        onboardingAfterDismissal = false
        pairingSessionCode = nil
        onboardingRoute = "welcome"
        showOnboarding = true
    }

    private var productionAppIcon: Image? {
        guard let url = Bundle.module.url(forResource: "ScreenpunkAppIcon", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
    }

    @ViewBuilder private var productionLanding: some View {
        if onboardingRoute == "local" {
            let displayedRequest = host.pendingPairingRequest
            let displayedRequestID = displayedRequest?.sessionNonceHex
            let displayedCode = displayedRequest?.code
            DeviceOnboardingLocalView(state: localPairingState(code: displayedCode, requestID: displayedRequestID), confirm: {
                guard let displayedRequestID else { return }
                pairingSessionCode = displayedRequestID
                host.confirm(expectedSessionNonceHex: displayedRequestID)
            }, decline: {
                guard let displayedRequestID else { return }
                host.cancelPairing(expectedSessionNonceHex: displayedRequestID)
                pairingSessionCode = nil
            }, retry: { if host.server != nil { host.cancelPairing(); host.resume() } else { onboardingRoute = "welcome" }; pairingSessionCode = nil }, cancel: {
                if host.server != nil { host.cancelPairing() }; pairingSessionCode = nil; onboardingRoute = "welcome"
                if showOnboarding { showOnboarding = false }
            }, done: { onboardingRoute = "connected"; if showOnboarding { generalAfterOnboarding = true; showOnboarding = false } else { showSettings = true } })
        } else if onboardingRoute == "cloud" {
            DeviceOnboardingCloudView(message: "Cloud sign-in is not available in this version.", cancel: { onboardingRoute = "welcome" })
        } else if host.runtime.isPaired && !showOnboarding {
            DeviceOnboardingConnectedView(connectionDescription: "Connected to Screenpunk on your Mac", hasScreens: !(host.server?.installedManifests.isEmpty ?? true), screens: { showScreens = true }, settings: { initialSetupPage = .settings; showDeviceMenu = true })
        } else {
            DeviceOnboardingWelcomeView(appIcon: productionAppIcon, cloud: { onboardingRoute = "cloud" }, local: { pairingSessionCode = nil; onboardingRoute = "local" })
        }
    }
    private func localPairingState(code: String?, requestID: String?) -> DeviceOnboardingLocalState {
        if host.server == nil { return .failed(message: "The local connection could not start. Unlock this device, close Screenpunk, then open it again.") }
        if host.errorMessage != nil { return .failed(message: "The connection could not be completed. Try again from Screenpunk on your Mac.") }
        if let code, requestID != nil {
            if host.awaitingControllerConfirm { return .approving }
            return .request(macName: "a Mac", code: code)
        }
        if let pairingSessionCode, host.completedPairingSessionNonceHex == pairingSessionCode { return .completed(macName: "the Mac") }
        return .waiting
    }

    private var missingConnector: DeviceSetupPage? {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-required-connection") { return .googleTV }
#endif
        _ = connectorRevision
        return DeviceConnectorCatalog(manifests: host.server?.installedManifests ?? []).missing(for: host.screenSet?.selectedDashboardId ?? host.server?.installedManifests.first?.dashboardId)
    }
    private func connectorGate(_ page: DeviceSetupPage) -> some View {
        DeviceMenuHold(content: ZStack {
            Color.black.opacity(0.34).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(.blue)
                Text(page == .googleTV ? "Set up Google TV" : "Set up Google Calendar").font(.title2.bold())
                Text("A few things need to be connected before you can use this screen.").foregroundStyle(.secondary)
                if #available(iOS 26, *) {
                    Button("Open settings") { initialSetupPage = page; showDeviceMenu = true }.buttonStyle(.glass).controlSize(.large)
                } else { Button("Open settings") { initialSetupPage = page; showDeviceMenu = true }.buttonStyle(.bordered).controlSize(.large) }
                Divider()
                Text("You can swipe with two fingers to another screen, or hold two fingers for five seconds to open the Screenpunk menu.").font(.footnote).foregroundStyle(.secondary)
            }.padding(30).frame(maxWidth: 490).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).padding(24)
        }, open: { initialSetupPage = nil; showDeviceMenu = true })
        .deviceScreenSwipes(screens: host.screenSet?.screens.map(\.entry) ?? [], selectedID: host.screenSet?.selectedDashboardId, enabled: true) { host.advanceScreen(by: $0) }
    }
#endif

    private var localBody: some View {
        Group {
            if let revision = fallback.activeRevision {
                deployedDashboard(revision: revision, package: nil) {
                    fallback.unlink()
                }
            } else if let code = fallback.pairingCode {
                PairingCodeView(code: code) {
                    do {
                        try fallback.confirmPairing(
                            code: code,
                            presentedOwner: fallback.pairing.session?.candidateOwner
                                ?? PairingIdentityFactory.make(role: .controller),
                            clock: FixedClock(Date())
                        )
                        confirmError = nil
                    } catch {
                        confirmError = String(describing: error)
                    }
                }
                .padding(24)
            } else {
                UnpairedHostView()
            }
        }
        .overlay(alignment: .bottom) {
            if let confirmError {
                Text(confirmError)
                    .font(.footnote)
                    .padding()
            }
        }
    }

    private var legacyPairingOverlayActive: Bool {
#if os(iOS)
        host.pairingCode != nil && !localOnboardingActive && host.runtime.isPaired && !showOnboarding
#else
        host.pairingCode != nil
#endif
    }

    private var localOnboardingActive: Bool {
#if os(iOS)
        onboardingRoute == "local"
#else
        false
#endif
    }

    private var currentSettings: DeviceSettings {
#if canImport(Network) && canImport(Security)
        host.settingsSnapshot?.value ?? .init()
#else
        .init()
#endif
    }

    private var settingsAppliedCallback: (Bool) -> Void {
#if canImport(Network) && canImport(Security)
        let revision = host.settingsSnapshot?.revision
        return { accepted in
            guard revision == host.settingsSnapshot?.revision else { return }
            renderedSettingsRevision = accepted ? revision : nil
            acknowledgeSettings()
        }
#else
        return { _ in }
#endif
    }

#if canImport(Network) && canImport(Security)
    private func applyBrightness() {
        brightness.setActive(scenePhase == .active && host.runtime.isPaired)
        brightness.update(settings: currentSettings.brightness)
        brightnessSettingsRevision = host.settingsSnapshot?.revision
        acknowledgeSettings()
    }

    private func acknowledgeSettings() {
        guard let snapshot = host.settingsSnapshot else { return }
        let rendererAccepted = host.runtime.activeRevision == nil || renderedSettingsRevision == snapshot.revision
        if scenePhase == .active && brightness.isApplied && brightnessSettingsRevision == snapshot.revision && rendererAccepted {
            host.markSettingsApplied(revision: snapshot.revision)
        } else {
            host.markSettingsUnapplied(revision: snapshot.revision)
        }
    }
#endif

    private var currentScreenName: String {
#if canImport(Network) && canImport(Security)
        host.screenSet?.screens.first(where: { $0.revision.dashboardId == host.screenSet?.selectedDashboardId })?.name ?? "Screen"
#else
        "Screen"
#endif
    }

    private var homeAssistantRuntime: HomeAssistantDeviceRuntime? {
#if canImport(Network) && canImport(Security)
        host.server?.homeAssistantRuntime
#else
        nil
#endif
    }

    /// Renders the package delivered over the LAN for `revision`. `.id("\(revision):\(genericRuntimeID.uuidString)")`
    /// rebuilds the web view when a new revision activates.
    @ViewBuilder
    private func deployedDashboard(
        revision: String,
        package: PackageAssetStore?,
        onUnlink: @escaping () -> Void
    ) -> some View {
        if let package {
            DashboardRuntimeView(store: package, homeAssistant: homeAssistantRuntime, publicReads: host.server?.publicReadSession(), revision: revision,
                                 connections: genericConnections, settings: currentSettings,
                                 onSettingsApplied: settingsAppliedCallback, screenName: currentScreenName,
                                 onMenu: { showDeviceMenu = true }, onUnlink: onUnlink)
                .ignoresSafeArea()
                .id("\(revision):\(genericRuntimeID.uuidString)")
        } else if revision == StoredRevision.offlineFixture.revision,
                  let store = try? PackageAssetStore.bundledOfflineFixture()
        {
            DashboardRuntimeView(store: store, settings: currentSettings,
                                 onSettingsApplied: settingsAppliedCallback, screenName: currentScreenName,
                                 onMenu: { showDeviceMenu = true }, onUnlink: onUnlink)
                .ignoresSafeArea()
                .id("\(revision):\(genericRuntimeID.uuidString)")
        } else {
            UnpairedHostView(detail: "Deployed revision \(revision.prefix(8)) has no package on this device. Deploy again from the Mac.")
        }
    }
}

#if os(iOS)
private struct DeviceMenuContainer<Menu: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: menu)
        } else {
            content.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    menu()
                }
            }
        }
    }
}
#endif
