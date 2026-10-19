#if os(iOS)
import SwiftUI
import ScreenpunkCore

public struct DeviceCloudHomeAssistantSettings: View {
    private let installationID: UUID
    private let manifests: [DashboardManifest]
    public init(installationID: UUID, manifests: [DashboardManifest]) {
        self.installationID = installationID; self.manifests = manifests
    }
    public var body: some View {
        Section("Local connections") {
            ForEach(manifests.filter { $0.connections.contains { $0.alias == "home" } }, id: \.dashboardId) { manifest in
                NavigationLink("Home Assistant · " + manifest.name) {
                    CloudHomeApproval(installationID: installationID, manifest: manifest)
                }
            }
        }
    }
}
private struct CloudHomeApproval: View {
    let installationID: UUID
    let manifest: DashboardManifest
    @State private var origin = ""
    @State private var token = ""
    @State private var insecure = false
    @State private var approved = false
    @State private var message: String?
    private var declaration: ManifestConnection? { manifest.connections.first { $0.alias == "home" } }
    var body: some View {
        Form {
            Section(manifest.name) {
                Text(approved ? "This version is approved on this device." : "Approve this screen’s access to your local Home Assistant.")
                Text("Credentials stay on this device. A changed screen version requires a new approval.").font(.footnote)
            }
            Section("Requested access") {
                if declaration?.operations?.contains(where: { $0.name == "getStates" || $0.name == "stateChanged" }) == true {
                    Text("Read Home Assistant entity states")
                }
                ForEach(Array((declaration?.serviceCalls ?? []).enumerated()), id: \.offset) { _, call in
                    VStack(alignment: .leading) {
                        Text(call.domain + "." + call.service)
                        Text(call.allowUntargeted == true ? "May run without an entity target" : call.entityIds.joined(separator: ", ")).font(.caption)
                    }
                }
                ForEach(declaration?.cameraEntities ?? [], id: \.self) { Text("Camera: " + $0) }
            }
            Section("Connection") {
                TextField("Home Assistant URL", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Allow HTTP on my local network", isOn: $insecure)
                Button("Approve and save on this device") {
                    do {
                        try DeviceCloudHomeAssistantStore.shared.approve(installationID: installationID, manifest: manifest,
                            origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines), allowInsecureHTTP: insecure)
                        token = ""; approved = true; message = "Saved. Return to your screen to use Home Assistant."
                    } catch { message = "Could not save. Check the URL, access token and local HTTP setting." }
                }.disabled(origin.isEmpty || token.isEmpty)
                if approved {
                    Button("Remove this screen’s access", role: .destructive) {
                        do { try DeviceCloudHomeAssistantStore.shared.revoke(installationID: installationID, dashboardID: manifest.dashboardId); approved = false; message = "Access removed." }
                        catch { message = "Could not remove access. Try again." }
                    }
                }
                if let message { Text(message).font(.callout) }
            }
        }.navigationTitle("Home Assistant")
            .task { approved = (try? DeviceCloudHomeAssistantStore.shared.configuration(installationID: installationID, manifest: manifest)) != nil }
    }
}
#endif
