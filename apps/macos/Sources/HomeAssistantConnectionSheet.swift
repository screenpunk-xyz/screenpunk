import SwiftUI

struct HomeAssistantConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ConnectionsStore
    @State private var address: String
    @State private var token = ""
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false
    init(store: ConnectionsStore) {
        self.store = store
        _address = State(initialValue: store.homeAssistant?.address ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) { ConnectionLogo(name: "Home Assistant", size: 36); Text("Home Assistant").font(.title2.weight(.semibold)) }
            Text("Connect your Home Assistant server to Screenpunk.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Open your Home Assistant profile and find Long-lived access tokens. Create a token named Screenpunk.")
                Text("2. Enter your server address and paste the token below. Screenpunk stores the token in this Mac’s Keychain.")
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Server Address").font(.callout.weight(.medium))
                TextField("http://homeassistant.local:8123", text: $address).textFieldStyle(.roundedBorder)
                Text("Access Token").font(.callout.weight(.medium)).padding(.top, 8)
                SecureField(store.homeAssistant == nil ? "Paste your access token" : "Leave blank to keep the saved token", text: $token).textFieldStyle(.roundedBorder)
            }.disabled(busy)
            Text("Apply a screen that uses Home Assistant to securely install this connection on the phone. The phone then connects directly and keeps working with the Mac closed. Available entities and actions follow the token’s Home Assistant user permissions.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Home Assistant setup guide ↗", destination: URL(string: "https://developers.home-assistant.io/docs/api/rest/")!).font(.callout)
            if let result { Text(result).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Test Connection") { connect(save: false) }.workbenchButton().disabled(busy || address.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).workbenchButton().disabled(busy)
                Button("Save") { connect(save: true) }.workbenchButton(prominent: true).keyboardShortcut(.defaultAction).disabled(busy || address.isEmpty)
            }
        }.padding(28).frame(width: 560).interactiveDismissDisabled(busy)
            .onChange(of: address) { _, _ in result = nil }
            .onChange(of: token) { _, _ in result = nil }
    }
    private func connect(save: Bool) {
        busy = true; result = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.verify(address: address, token: token, save: save)
                failed = false; result = "Connection verified on this Mac."
                if save { token = ""; dismiss() }
            } catch {
                failed = true
                if let network = error as? URLError, [.timedOut, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(network.code) {
                    result = "Couldn’t reach Home Assistant. Check the server address, make sure it is running, and allow Screenpunk to access your local network."
                } else { result = error.localizedDescription }
            }
        }
    }
}
