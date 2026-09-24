#if os(iOS)
import SwiftUI

/// Live device form. Uses the same pairing sessions and saved identities as the original setup UI.
@MainActor
struct DeviceGoogleTVSettings: View {
    @StateObject private var basic = GoogleTVSetup()
    @StateObject private var developer = GoogleTVADBSetup()
    @State private var refresh = UUID()
    @State private var confirmForget = false
    @Environment(\.scenePhase) private var scenePhase
    var onChange: () -> Void
    private var basicPaired: Bool { GoogleTVConfiguration.load().pin.count == 32 }
    private var developerPaired: Bool { GoogleTVADBConfiguration.load().serverPin.count == 32 }
    private var validPort: Bool { (UInt16(developer.connectionPort) ?? 0) > 0 }
    private var busy: Bool { basic.busy || developer.busy }

    var body: some View {
        Form {
            Section("Your TV") {
                DisclosureGroup {
                    Text("1. Connect to the same network").font(.headline)
                    Text("Keep the iPad and TV on the same network. Allow Screenpunk Local Network access in iPad Settings.")
                    Text("2. Find your TV’s address").font(.headline)
                    Text("On Google TV, open Settings → Network & Internet and select your network to find its IP address. Enter it below. Menu names vary by TV.")
                    Text("Also enter the connection port from Wireless debugging. The steps below explain how to enable it. This port is collected now for channels and power.")
                    Text("3. Pair this iPad").font(.headline)
                    Text("Tap Pair and enter the six-character code shown on the TV to connect volume and mute.")
                } label: { VStack(alignment: .leading, spacing: 4) {
                    Text("Basic setup guide")
                    Text("Connect for volume and mute").font(.subheadline).foregroundStyle(.secondary)
                } }
                HStack(alignment: .top, spacing: 16) {
                    field("IP address", placeholder: "TV address", text: $basic.host)
                        .frame(maxWidth: 240, alignment: .leading)
                    field("Port", placeholder: "Port", text: $developer.connectionPort)
                        .frame(width: 100, alignment: .leading)
                    Spacer(minLength: 0)
                }.disabled(busy || basic.waitingCode)
                if !validPort { Text("Enter the connection port from Wireless debugging (1–65535).").font(.footnote).foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    status(basic.host.isEmpty ? "Google TV" : basic.host, connected: basicPaired, waiting: basic.waitingCode)
                        .frame(maxWidth: 240, alignment: .leading)
                    Group {
                        if basic.waitingCode { Button("Cancel") { basic.stop(); basic.waitingCode = false } }
                        else if basicPaired { Button(role: .destructive) { basic.forget(); changed() } label: { Text("Disconnect").foregroundStyle(.red) } }
                        else { Button("Pair") { basic.pair() }.disabled(!validPort || !GoogleTVConfiguration.validHost(basic.host)) }
                    }.buttonStyle(.borderless).frame(width: 100, alignment: .leading)
                    Spacer(minLength: 0)
                }.disabled(busy)
                if basic.waitingCode {
                    TextField("Six-character TV code", text: $basic.code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Confirm code", action: basic.finish).disabled(busy || basic.code.trimmingCharacters(in: .whitespacesAndNewlines).count != 6 || !validPort)
                }
            }
            Section {
                DisclosureGroup("1. Enable Developer options on your TV") {
                    Text("Open Settings → System → About. Select Android TV OS build repeatedly until Developer options are enabled. Return to System and open Developer options. Names may vary by TV.")
                }
                DisclosureGroup("2. Turn on wireless debugging") {
                    Text("Enable Wireless debugging on your trusted home network. Enter its connection port under Your TV. Choose Pair device with pairing code, then enter the six-digit code and separate pairing port below. USB debugging is not required.")
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                        SecureField("Six-digit code", text: $developer.code).keyboardType(.numberPad)
                    }.frame(maxWidth: 240, alignment: .leading)
                    field("Developer port", placeholder: "Port", text: $developer.pairingPort).frame(width: 100, alignment: .leading)
                    Spacer(minLength: 0)
                }.disabled(busy)
                HStack(spacing: 16) {
                    status("Developer pairing", connected: developerPaired).frame(maxWidth: 240, alignment: .leading)
                    Group {
                        if developerPaired { Button(role: .destructive) { developer.forget(); changed() } label: { Text("Disconnect").foregroundStyle(.red) } }
                        else { Button("Pair") { developer.host = basic.host; developer.pair() }
                            .disabled(!validPort || (UInt16(developer.pairingPort) ?? 0) == 0 || developer.code.count != 6 || !developer.code.allSatisfy(\.isNumber)) }
                    }.buttonStyle(.borderless).frame(width: 100, alignment: .leading)
                    Spacer(minLength: 0)
                }.disabled(busy)
            } header: { Text("Channels and power") } footer: {
                Text("Wireless debugging grants this iPad debugging access to the TV. Screenpunk uses it for the channels and power controls defined by your screens.")
            }
            Section("Connection help") {
                Button("Check connections") { if basicPaired { basic.check() }; if developerPaired { developer.host = basic.host; developer.check() } }.disabled(busy)
                DisclosureGroup("Connection changed or stopped working?") {
                    Text("Check the network and Local Network permission. Update the connection port if the TV’s debugging service restarted. Pair again if the TV address changed.")
                    Button("Save connection port") { savePort(); changed() }.disabled(!validPort || busy || !developerPaired)
                    Button("Refresh TV trust") { developer.host = basic.host; developer.refreshTrust() }.disabled(!developerPaired || busy || !validPort)
                    Text("Only refresh trust when the saved address and connection port match your TV.").font(.footnote)
                }
                if basic.busy || developer.busy { ProgressView(); Button("Cancel") { basic.stop(); developer.stop() } }
                if !basic.message.isEmpty { Text(basic.message).font(.footnote).foregroundStyle(.secondary) }
                if !developer.message.isEmpty { Text(developer.message).font(.footnote).foregroundStyle(.secondary) }
                Button(role: .destructive) { confirmForget = true } label: { Text("Forget Google TV").foregroundStyle(.red) }
                    .confirmationDialog("Forget this TV’s connections?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget TV", role: .destructive) { basic.forget(); developer.forget(); changed() }
                    }
            }
        }
        .tint(.blue)
        .onAppear {
            if basic.host.isEmpty { basic.host = developer.host }
            if developer.connectionPort.isEmpty {
                let draft = UserDefaults.standard.integer(forKey: "screenpunk.googleTV.connectionPortDraft")
                if draft > 0 { developer.connectionPort = String(draft) }
            }
            basic.message = ""; developer.message = ""
        }
        .onChange(of: basic.busy) { value in if !value { savePort(); changed() } }
        .onChange(of: developer.busy) { value in if !value { changed() } }
        .onDisappear { basic.stop(); developer.stop() }
        .onChange(of: scenePhase) { if $0 == .background { basic.stop(); developer.stop() } }
        .accessibilityIdentifier(refresh.uuidString)
    }
    private func changed() {
        // Pairing grants the installed screens bounded TV capabilities; no extra per-screen toggles.
        var b = GoogleTVConfiguration.load()
        if b.pin.count == 32 { b.automaticScreenAccess = true; try? b.save() }
        var d = GoogleTVADBConfiguration.load()
        if d.serverPin.count == 32 { d.automaticScreenAccess = true; try? d.save() }
        if basic.message.hasPrefix("Paired.") { basic.message = "Paired. Volume and mute are available to your screens." }
        if developer.message.hasPrefix("Paired and connected.") { developer.message = "Paired. Channels and power are available to your screens." }
        refresh = UUID(); onChange()
    }
    private func savePort() {
        guard let port = UInt16(developer.connectionPort), port > 0 else { return }
        UserDefaults.standard.set(Int(port), forKey: "screenpunk.googleTV.connectionPortDraft")
        var saved = GoogleTVADBConfiguration.load()
        if saved.host == basic.host, saved.serverPin.count == 32 { saved.port = port; try? saved.save() }
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
    private func status(_ caption: String, connected: Bool, waiting: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(waiting ? "Waiting for TV code" : connected ? "Connected" : "Not connected")
                Image(systemName: connected ? "checkmark.circle.fill" : "circle").foregroundStyle(connected ? Color.green : Color.secondary)
            }
        }
    }
}
#endif
