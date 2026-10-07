import SwiftUI
import ScreenpunkCore

/// Recovery remains accessible even when there is no admitted runtime host to
/// present the normal device settings or install the kiosk gesture handlers.
public struct DeviceManagementBlockedView: View {
    private let snapshot: DeviceRetainedContentSnapshot
    private let message: String
    private let diagnosticDetails: String?
    private let retryCount: Int
    private let resetLocalData: (() -> Void)?
    private let retry: () -> Void
    @State private var selectedID: String?
    @State private var showsHelp = false
    public init(snapshot: DeviceRetainedContentSnapshot,
                message: String? = nil, diagnosticDetails: String? = nil, retryCount: Int = 0, resetLocalData: (() -> Void)? = nil, retry: @escaping () -> Void) {
        self.snapshot = snapshot
        self.message = message ?? "Screenpunk could not start device management."
        self.diagnosticDetails = diagnosticDetails
        self.retryCount = retryCount
        self.resetLocalData = resetLocalData
        self.retry = retry
        _selectedID = State(initialValue: snapshot.selectedID)
    }
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let screen = snapshot.screens.first(where: { $0.id == selectedID }) ?? snapshot.screens.first {
                DashboardRuntimeView(store: screen.package, revision: screen.revision, settings: snapshot.settings, screenName: screen.name)
                    .id(screen.id)
                    .deviceScreenSwipes(screens: snapshot.screens.map { .init(dashboardId: $0.id, revision: $0.revision, name: $0.name) },
                                        selectedID: selectedID, enabled: snapshot.screens.count > 1) { advance(by: $0) }
                    .accessibilityAction(named: "Next screen") { advance(by: 1) }
                    .accessibilityAction(named: "Previous screen") { advance(by: -1) }
            }
            VStack {
                if !snapshot.screens.isEmpty { Spacer() }
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            .accessibilityHidden(true)
                        Text("Setup could not finish").font(.title2.bold())
                        Text("Screenpunk couldn’t finish preparing this device. You can retry or open recovery options.").font(.callout)
                        if retryCount > 0 {
                            Text("Setup still couldn’t finish after retry \(retryCount).")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("device-startup-retry-result")
                        }
                        Button("Retry startup", action: retry).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("device-startup-retry")
                        Button("Recovery options") { showsHelp = true }.buttonStyle(.bordered)
                            .accessibilityIdentifier("device-startup-help")
                    }
                    .multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: 480)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showsHelp) {
            DeviceStartupHelpView(message: message, diagnosticDetails: diagnosticDetails, deviceName: snapshot.settings.displayName, resetLocalData: resetLocalData, retry: retry)
        }
    }
    private func advance(by offset: Int) {
        guard let index = snapshot.screens.firstIndex(where: { $0.id == selectedID }), !snapshot.screens.isEmpty else { return }
        guard let next = ScreenCarousel.index(from: index, offset: offset, count: snapshot.screens.count) else { return }
        selectedID = snapshot.screens[next].id
    }
}

private struct DeviceStartupHelpView: View {
    let message: String
    let diagnosticDetails: String?
    let deviceName: String?
    let resetLocalData: (() -> Void)?
    let retry: () -> Void
    @State private var confirmsReset = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if resetLocalData != nil {
                    Section("Start again on this device") {
                        Text("Reset the saved Local data if you want to set up this device again.")
                        Button("Reset local device data", role: .destructive) { confirmsReset = true }
                            .accessibilityIdentifier("device-startup-reset")
                    }
                } else {
                    Section("Local reset") {
                        Text("A safe local reset is unavailable because Screenpunk could not verify the saved device state and reset scope. Share the startup details for help.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Recovery") {
                    Text("Retry checks the saved state again. It does not reset this device and may return the same error. If setup still cannot finish, share the startup details with Screenpunk support or the person managing this device.")
                    Button("Retry startup") { dismiss(); retry() }
                    ShareLink("Share startup details", item: "Screenpunk device setup could not finish\n\(message)\n\(diagnosticDetails ?? "No additional startup diagnostic was reported.")")
                }
                Section("Startup details") {
                    DisclosureGroup("Show startup details") {
                        if let deviceName { LabeledContent("Device name", value: deviceName) }
                        Text(message).textSelection(.enabled)
                        if let diagnosticDetails {
                            Text(diagnosticDetails).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Section("Device settings") {
                    Text("After startup succeeds, use Settings to name this device and connect it to Screenpunk. While a screen is running, hold two fingers for five seconds to open the Screenpunk menu, then choose Settings.")
                }
            }
            .navigationTitle("Recovery options")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .alert("Reset local device data?", isPresented: $confirmsReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset local device data", role: .destructive) {
                    guard let resetLocalData else { return }
                    dismiss()
                    resetLocalData()
                }
            } message: {
                Text("This removes this device’s saved screens, settings, saved Mac pairing, and Google Calendar, Home Assistant, and generic saved connection credentials. Google TV/ADB credentials and the TLS pairing transport identity are preserved, as are your Screenpunk Cloud account, server data, and Cloud installation credentials. Removed connections will need to be set up again.")
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
