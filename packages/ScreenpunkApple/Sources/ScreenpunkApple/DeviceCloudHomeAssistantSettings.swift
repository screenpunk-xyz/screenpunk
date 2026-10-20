#if os(iOS)
import SwiftUI
import ScreenpunkCore

public struct DeviceCloudHomeAssistantSettings: View {
    private let installationID: UUID
    private let manifests: [DashboardManifest]
    public init(installationID: UUID, manifests: [DashboardManifest]) {
        self.installationID = installationID; self.manifests = manifests
    }
    @State private var origin = ""
    @State private var token = ""
    @State private var insecure = false
    @State private var refresh = 0
    public var body: some View {
        Form {
            Section("Connection") {
                Text("Connect this iPad to Home Assistant, then approve each screen’s requested access below.")
                TextField("Home Assistant URL", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("home-assistant.url")
                SecureField("Access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Allow HTTP on my local network", isOn: $insecure)
                Text("Use the address that opens Home Assistant on this iPad, without a dashboard or API path. Create a long-lived access token in Home Assistant → your profile → Security.").font(.footnote)
                Text("Credentials stay on this device. Saved connection details can be reused when you approve another screen.").font(.footnote)
            }
            Section("Screens with access") {
                Text("Review the access requested by each screen. New versions require your approval.").font(.footnote)
            }
            ForEach(manifests.filter { $0.connections.contains { $0.alias == "home" } }, id: \.dashboardId) { manifest in
                CloudHomeApproval(installationID: installationID, manifest: manifest,
                    origin: $origin, token: $token, insecure: $insecure, refresh: $refresh)
            }
        }.navigationTitle("Home Assistant")
    }
}
private struct CloudHomeApproval: View {
    let installationID: UUID
    let manifest: DashboardManifest
    @Binding var origin: String
    @Binding var token: String
    @Binding var insecure: Bool
    @Binding var refresh: Int
    @State private var approved = false
    @State private var savedConnection = false
    @State private var message: String?
    private var declaration: ManifestConnection? { manifest.connections.first { $0.alias == "home" } }
    var body: some View {
        Section(manifest.name) {
                Text(approved ? "This version is approved on this device." : "Approve this screen’s access to your local Home Assistant.")

                Text("Requested access").font(.subheadline.bold())
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

                if savedConnection && !approved {
                    Button("Approve using saved Home Assistant connection") {
                        do { try DeviceCloudHomeAssistantStore.shared.approveSaved(installationID: installationID, manifest: manifest); approved = true; message = "Approved. Return to your screen." }
                        catch { message = "Could not approve the saved connection. Enter connection details above." }
                    }
                }
                Button("Approve access and save connection") {
                    do {
                        try DeviceCloudHomeAssistantStore.shared.approve(installationID: installationID, manifest: manifest,
                            origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines), allowInsecureHTTP: insecure)
                        token = ""; approved = true; refresh += 1; message = "Saved. Return to your screen to use Home Assistant."
                    } catch { message = "Could not save. Check the URL, access token and local HTTP setting." }
                }.disabled(origin.isEmpty || token.isEmpty)
                if approved {
                    Button("Remove this screen’s access", role: .destructive) {
                        do { try DeviceCloudHomeAssistantStore.shared.revoke(installationID: installationID, dashboardID: manifest.dashboardId); approved = false; refresh += 1; message = "Access removed." }
                        catch { message = "Could not remove access. Try again." }
                    }
                }
                if let message { Text(message).font(.callout) }
        }
            .task(id: refresh) { savedConnection = (try? DeviceCloudHomeAssistantStore.shared.hasSavedConnection(installationID: installationID)) == true; approved = (try? DeviceCloudHomeAssistantStore.shared.configuration(installationID: installationID, manifest: manifest)) != nil }
    }
}
#endif
