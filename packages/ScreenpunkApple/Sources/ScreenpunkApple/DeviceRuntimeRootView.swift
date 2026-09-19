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
        return DeviceRuntimeRootView(runtime: runtime)
    }

    public var body: some View {
        Group {
#if canImport(Network) && canImport(Security)
            lanBody
                .onAppear { host.start(); applyBrightness() }
                .onChange(of: host.settingsSnapshot?.revision) { _ in applyBrightness() }
                .onChange(of: host.runtime.isPaired) { _ in applyBrightness() }
                .onChange(of: scenePhase) { _ in applyBrightness() }
                .onReceive(brightness.$isApplied) { _ in
                    Task { @MainActor in acknowledgeSettings() }
                }
                .onDisappear { brightness.stop() }
                .sheet(isPresented: $showSettings) { DeviceLocalSettingsSheet(host: host) }
                .task(id: "\(host.runtime.activeRevision ?? "none"):\(host.genericConnectionGeneration.uuidString)") {
                    if let genericConnections { try? await genericConnections.clearCredentials() }
                    genericConnections = nil
                    genericRuntimeID = UUID()
                    guard let server = host.server, host.runtime.isPaired else { return }
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
            if let revision = host.runtime.activeRevision {
                GeometryReader { geometry in
                    let profile = host.runtime.profile
                    let width = CGFloat(profile.width), height = CGFloat(profile.height)
                    let rotate = (geometry.size.width > geometry.size.height) != (width > height)
                    let displayWidth = rotate ? height : width
                    let displayHeight = rotate ? width : height
                    let scale = min(geometry.size.width / displayWidth, geometry.size.height / displayHeight)
                    deployedDashboard(revision: revision, package: host.activePackage) { host.unlink() }
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
                UnpairedHostView(
                    detail: host.port == 0 ? nil : "TLS 1.3 · port \(host.port)",
                    paired: host.runtime.isPaired
                )
            }
        }
        .allowsHitTesting(host.pairingCode == nil && !showDeviceMenu)
        .accessibilityHidden(host.pairingCode != nil || showDeviceMenu)
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
        .overlay {
            if let code = host.pairingCode {
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
            if let confirmError = host.errorMessage {
                Text(confirmError)
                    .font(.footnote)
                    .padding()
            }
        }
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
            DashboardRuntimeView(store: package, homeAssistant: homeAssistantRuntime, revision: revision,
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
