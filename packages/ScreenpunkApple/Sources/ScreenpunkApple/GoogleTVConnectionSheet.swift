import SwiftUI

@MainActor
final class GoogleTVSetup: ObservableObject {
    @Published var host = GoogleTVConfiguration.load().host
    @Published var code = ""
    @Published var dashboards = GoogleTVConfiguration.load().dashboardIDs.joined(separator: "\n")
    @Published var message = "Pair separately on the Mac and each iPad. No Home Assistant or running Mac is required."
    @Published var waitingCode = false
    @Published var busy = false
    private var pairingHost = ""
    private let session = GoogleTVSession()
    private var task: Task<Void, Never>?
    func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        task = Task { do { try await action() } catch is CancellationError { message = "Operation cancelled. You can try again." } catch { message = error.localizedDescription }; busy = false }
    }
    func pair() {
        guard GoogleTVConfiguration.validHost(host) else { message = "Enter the Google TV's local IP address or hostname, without a URL or port."; return }
        waitingCode = false; code = ""; pairingHost = host
        message = "Connecting to Google TV to request a pairing code…"
        run { [self] in try await session.beginPairing(host: pairingHost); waitingCode = true; message = "Enter the six-character code shown on your TV." }
    }
    func finish() {
        run { [self] in
            let pin = try await session.finishPairing(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            var saved = GoogleTVConfiguration.load()
            // A new TV must not silently inherit an existing screen's permissions.
            if saved.pin != pin { saved.dashboardIDs = []; saved.appLinks = []; saved.voicePhrases = []; dashboards = "" }
            saved.host = pairingHost; saved.pin = pin; try saved.save()
            host = pairingHost; waitingCode = false; code = ""; message = "Paired. Approve the screen IDs below, then save."
        }
    }
    func save() {
        do {
            var saved = GoogleTVConfiguration.load()
            guard saved.host == host else { throw GoogleTVError.message("Pair the changed host before saving.") }
            // Preserve existing link and voice approvals; this form only edits screen access.
            saved.dashboardIDs = lines(dashboards); try saved.save()
            message = "Permissions saved on this device. Screen packages contain no pairing credentials."
        } catch { message = error.localizedDescription }
    }
    private func lines(_ text: String) -> [String] { Array(Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
    func updateAddress() {
        let address = host
        guard GoogleTVConfiguration.validHost(address) else { message = "Enter a valid TV IP address or hostname."; return }
        run { [self] in
            let saved = GoogleTVConfiguration.load(); try saved.validate()
            message = "Verifying the paired TV at the new address…"
            try await session.connect(host: address, pin: saved.pin)
            try Task.checkCancellation()
            let current = GoogleTVConfiguration.load()
            guard current.host == saved.host, current.pin == saved.pin else { throw GoogleTVError.message("Connection changed during verification. Try again.") }
            var updated = current; updated.host = address; try updated.save()
            message = "Address saved. Existing pairing and permissions preserved."
        }
    }

    func check() {
        run { [self] in
            let saved = GoogleTVConfiguration.load(); try saved.validate()
            message = "Checking the volume connection…"
            try await session.connect(host: saved.host, pin: saved.pin)
            message = "Connected. No TV command was sent."
        }
    }
    func stop() { task?.cancel(); session.close() }
    func forget() { stop(); GoogleTVConfiguration.forget(); waitingCode = false; dashboards = ""; message = "Local TV connection and permissions removed. Screenpunk device pairing is unchanged." }
}

/// Native caregiver setup. Screens cannot start pairing or expand permissions.
public struct GoogleTVConnectionSheet: View {
    @StateObject private var model = GoogleTVSetup()
    @State private var directChannels = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    public init() {}
    public var body: some View {
        NavigationStack {
            Form {
                Section("Channels and TV power") {
                    Button("Set Up Channels and Power") { directChannels = true }
                    Text("Manage direct channel selection and the Power button on this device.").font(.caption)
                }
                Section("Volume and mute connection") {
                    Text("On Google TV, find its IP address in network settings. Keep both devices on the same LAN and allow Screenpunk Local Network access.")
                    TextField("Google TV IP address or hostname", text: $model.host).disabled(model.busy || model.waitingCode)
                    Button("Start Pairing", action: model.pair).disabled(model.busy)
                    Text(model.message).textSelection(.enabled)
                    if model.busy {
                        ProgressView()
                        Button("Cancel", action: model.stop)
                    }
                    if model.waitingCode {
                        TextField("Six-character TV code", text: $model.code)
                        Button("Confirm TV Code", action: model.finish).disabled(model.busy)
                    }
                }
                Section("Screen permissions") {
                    Text("Approved manifest dashboardId values, one per line. Approval applies to updates of these screens.").font(.caption)
                    TextEditor(text: $model.dashboards).frame(minHeight: 60)
                    Button("Save Screen Permissions", action: model.save).disabled(model.busy)
                }
                Section("Connection") {
                    Button("Check Connection", action: model.check).disabled(model.busy)
                    Text(model.message).textSelection(.enabled)
                }
                Section { Button("Forget Google TV Connection", role: .destructive, action: model.forget) }
            }
            .formStyle(.grouped)
            .navigationTitle("Google TV")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
#if os(macOS)
        .frame(minWidth: 620, minHeight: 650)
#endif
        .sheet(isPresented: $directChannels) { GoogleTVADBSetupSheet() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { phase in if phase == .background { model.stop() } }
    }
}
