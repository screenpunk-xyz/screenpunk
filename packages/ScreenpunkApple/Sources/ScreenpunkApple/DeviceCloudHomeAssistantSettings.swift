#if os(iOS)
import SwiftUI
import ScreenpunkCore

public struct DeviceCloudHomeAssistantSettings: View {
    private let installationID: UUID
    private let manifests: [DashboardManifest]
    @State private var origin = ""
    @State private var token = ""
    @State private var insecure = false
    @State private var saved = false
    @State private var saving = false
    @State private var approved: Set<String> = []
    @State private var message: String?
    @State private var scanner: ScannerPresentation?
    @State private var saveTask: Task<Void, Never>?
    private enum ScannerPresentation: String, Identifiable { case token; var id: String { rawValue } }
    public init(installationID: UUID, manifests: [DashboardManifest]) {
        self.installationID = installationID; self.manifests = manifests
    }
    private var screens: [DashboardManifest] { manifests.filter { $0.connections.contains { $0.alias == "home" } } }
    public var body: some View {
        Form {
            Section("Connection") {
                TextField("Home Assistant URL", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("home-assistant.url")
                SecureField(saved ? "Access token (saved; leave blank to keep)" : "Access token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { scanner = .token } label: { Label("Scan token QR code", systemImage: "qrcode.viewfinder") }
                Toggle("Allow HTTP on my local network", isOn: $insecure)
                Button(action: save) {
                    HStack { if saving { ProgressView() }; Text(saving ? "Checking connection…" : "Save connection") }
                }.disabled(saving || origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!saved && token.isEmpty))
                Text("Enter a hostname or IP address, including the port if needed. HTTPS is tried first; HTTP is tried only when allowed above. Create a token in Home Assistant → your profile → Security, then paste it or scan its QR code.").font(.footnote)
                if let message { Text(message).font(.callout).accessibilityIdentifier("home-assistant.status") }
            }.disabled(saving)
            Section {
                ForEach(screens, id: \.dashboardId) { manifest in
                    Toggle(manifest.name, isOn: Binding(get: { approved.contains(manifest.dashboardId) }, set: { setAccess($0, manifest: manifest) }))
                        .disabled(!saved || saving)
                        .accessibilityIdentifier("home-assistant.access." + manifest.dashboardId)
                }
            } header: { Text("Screens with access") }
            footer: { Text(saved ? "Enable access for screens you trust. A changed screen version needs your approval again." : "Save your connection to enable screen access. Credentials stay on this device.") }
        }.navigationTitle("Home Assistant")
            .task { load() }
            .onDisappear { saveTask?.cancel() }
            .sheet(item: $scanner) { _ in
                HomeAssistantTokenScanner { value in
                    do { token = try HomeAssistantConnectionSetup.scannedToken(value); message = "Token scanned. Tap Save connection to check and save it."; scanner = nil }
                    catch { message = error.localizedDescription; scanner = nil }
                }
            }
    }
    private func load() {
        do {
            if let connection = try DeviceCloudHomeAssistantStore.shared.savedConnection(installationID: installationID) {
                origin = connection.origin; insecure = connection.allowInsecureHTTP; saved = true
            }
            approved = Set(try screens.filter { try DeviceCloudHomeAssistantStore.shared.configuration(installationID: installationID, manifest: $0) != nil }.map(\.dashboardId))
        } catch { message = "Could not read the saved connection. Try reopening Settings." }
    }
    private func save() {
        let address = origin, allowHTTP = insecure, entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true; message = nil
        saveTask = Task { @MainActor in
            defer { saving = false }
            do {
                let secret = entered.isEmpty ? try DeviceCloudHomeAssistantStore.shared.savedConnection(installationID: installationID)?.token ?? "" : entered
                let normalized = try await HomeAssistantConnectionSetup.verify(address: address, token: secret, allowHTTP: allowHTTP)
                try Task.checkCancellation()
                try DeviceCloudHomeAssistantStore.shared.saveConnection(installationID: installationID, origin: normalized, token: secret, allowInsecureHTTP: allowHTTP)
                origin = normalized; token = ""; saved = true; message = "Connection saved. Choose which screens can use it below."
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    private func setAccess(_ enabled: Bool, manifest: DashboardManifest) {
        do {
            if enabled { try DeviceCloudHomeAssistantStore.shared.approveSaved(installationID: installationID, manifest: manifest); approved.insert(manifest.dashboardId) }
            else { try DeviceCloudHomeAssistantStore.shared.revoke(installationID: installationID, dashboardID: manifest.dashboardId); approved.remove(manifest.dashboardId) }
            message = enabled ? "Access enabled for \(manifest.name)." : "Access disabled for \(manifest.name)."
        } catch { message = "Could not update screen access. Check the saved connection and try again." }
    }
}
#endif
