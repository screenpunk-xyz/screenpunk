#if os(iOS)
import SwiftUI
import ScreenpunkCore

public struct DeviceCustomHTTPSettings: View {
    let installationID: UUID
    let manifests: [DashboardManifest]
    let alias: String
    public init(installationID: UUID, manifests: [DashboardManifest], alias: String) {
        self.installationID = installationID; self.manifests = manifests; self.alias = alias
    }
    public var body: some View {
        Form {
            ForEach(manifests.filter { $0.connections.contains { $0.alias == alias && $0.customHTTP != nil } }, id: \.dashboardId) { manifest in
                NavigationLink(manifest.name) { CustomHTTPApproval(installationID: installationID, manifest: manifest, alias: alias) }
            }
        }
    }
}
private struct CustomHTTPApproval: View {
    let installationID: UUID
    let manifest: DashboardManifest
    let alias: String
    @State private var origin = ""
    @State private var secret = ""
    @State private var local = false
    @State private var insecure = false
    @State private var approved = false
    @State private var saved = false
    @State private var message: String?
    private var declaration: CustomHTTPDeclaration { manifest.connections.first { $0.alias == alias }!.customHTTP! }
    var body: some View {
        Form {
            Section(manifest.name) {
                Text(approved ? "This version is approved on this device." : "This screen needs connection setup and your approval.")
                Text("Connection details stay on this device. Review access for each new screen version.").font(.footnote)
            }
            Section("Requested access") {
                ForEach(declaration.operations, id: \.name) { operation in
                    VStack(alignment: .leading) {
                        Text(operation.name)
                        Text(operation.method + " " + operation.path).font(.caption)
                        if operation.method != "GET" { Text("Can change data on this service").font(.caption).foregroundStyle(.secondary) }
                        ForEach(operation.parameters.keys.sorted(), id: \.self) { key in
                            Text(key + ": " + operation.parameters[key]!.joined(separator: ", ")).font(.caption)
                        }
                    }
                }
            }
            Section("Connection") {
                if saved && !approved {
                    Button("Approve using saved connection") {
                        perform { try DeviceCustomHTTPStore.shared.approveSaved(installationID: installationID, manifest: manifest, alias: alias) }
                    }
                }
                TextField("Service URL", text: $origin).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Enter only the origin, for example https://service.example.com, without a path.").font(.footnote)
                if declaration.authentication != "none" {
                    SecureField(declaration.authentication == "bearer" ? "Access token" : "API key", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("Allow access to my local network", isOn: $local)
                if local { Toggle("Allow HTTP on my local network", isOn: $insecure) }
                Button("Approve and save on this device") {
                    perform {
                        try DeviceCustomHTTPStore.shared.approve(installationID: installationID, manifest: manifest, alias: alias,
                            configuration: .init(origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), secret: secret,
                                allowLocalNetwork: local, allowInsecureHTTP: local && insecure))
                    }
                }.disabled(origin.isEmpty || (declaration.authentication != "none" && secret.isEmpty))
                if approved {
                    Button("Remove this screen’s access", role: .destructive) {
                        do { try DeviceCustomHTTPStore.shared.revoke(installationID: installationID, dashboardID: manifest.dashboardId, alias: alias); approved = false; message = "Access removed." }
                        catch { message = "Could not remove access. Try again." }
                    }
                }
                if let message { Text(message).font(.callout) }
            }
        }.navigationTitle(declaration.name)
            .task {
                approved = (try? DeviceCustomHTTPStore.shared.configuration(installationID: installationID, manifest: manifest, alias: alias)) != nil
                saved = (try? DeviceCustomHTTPStore.shared.hasSavedConnection(installationID: installationID, alias: alias, declaration: declaration)) == true
            }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); secret = ""; approved = true; saved = true; message = "Saved. Return to your screen to connect." }
        catch { message = "Could not save. Check the URL, authentication and local network settings." }
    }
}
#endif
