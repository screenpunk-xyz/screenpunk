import SwiftUI

@MainActor
final class GoogleTVADBSetup: ObservableObject {
    @Published var host = GoogleTVADBConfiguration.load().host
    @Published var connectionPort = GoogleTVADBConfiguration.load().port == 0 ? "" : String(GoogleTVADBConfiguration.load().port)
    @Published var pairingPort = ""
    @Published var code = ""
    @Published var screens = GoogleTVADBConfiguration.load().dashboardIDs.joined(separator: "\n")
    @Published var powerToggleAllowed = GoogleTVADBConfiguration.load().powerToggleAllowed == true
    @Published var channels = GoogleTVADBConfiguration.load().channelIDs.joined(separator: "\n")
    @Published var message = "Pair this device separately. No Mac, Home Assistant, or computer connection is needed at runtime."
    @Published var busy = false
    @Published private(set) var pendingPairing = false
    private var pendingPeer: (host: String, guid: String, pin: Data?)?
    private var task: Task<Void, Never>?
    private var client: GoogleTVADBClient?
    private var generation = UUID()
    private var cancellationReason = "Connection check cancelled. Pairing was preserved."
    func stop(reason: String = "Cancelled. Pairing was preserved.") { cancellationReason = reason; generation = UUID(); task?.cancel(); client?.close(); code = "" }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        task = Task { defer { busy = false; client?.close(); client = nil; code = "" }; do { try await action() } catch is CancellationError { message = cancellationReason } catch { message = error.localizedDescription } }
    }
    func pair() {
        guard GoogleTVConfiguration.validHost(host), let pairPort = UInt16(pairingPort), pairPort > 0,
              let port = UInt16(connectionPort), port > 0 else { message = "Enter the TV address and both ports shown in Wireless debugging."; return }
        let address = host, pairingCode = code, epoch = generation
        run { [self] in
            let peer = try await ADBPairing.pair(host: address, port: pairPort, code: pairingCode)
            try Task.checkCancellation()
            pendingPeer = (address, peer.guid, nil); pendingPairing = true
            try await completePairing(address: address, port: port, epoch: epoch)
        }
    }
    private func completePairing(address: String, port: UInt16, epoch: UUID) async throws {
        guard let peer = pendingPeer, peer.host == address else { throw GoogleTVError.message("The address changed. Pair the new TV explicitly.") }
        message = "TV accepted pairing. Verifying the connection port…"
        let connection = try GoogleTVADBClient(pin: peer.pin); client = connection
        do { try await connection.connect(host: address, port: port) }
        catch {
            if let pin = connection.serverPin { pendingPeer = (peer.host, peer.guid, pin) }
            throw GoogleTVError.message("TV accepted pairing, but connection verification failed: \(error.localizedDescription) Check Connection port on the main Wireless debugging page, then Retry connection. Your existing settings are unchanged.")
        }
        try Task.checkCancellation()
        guard generation == epoch, let pin = connection.serverPin else { throw GoogleTVError.message("Connection verification cancelled. Existing settings are unchanged.") }
        var saved = GoogleTVADBConfiguration.load()
        // An IP change alone is not a new TV. Keep permissions for the same trusted identity.
        if saved.deviceGUID != peer.guid || saved.serverPin != pin {
            saved.dashboardIDs = []; saved.channelIDs = []; saved.powerToggleAllowed = false
            saved.automaticScreenAccess = nil; screens = ""; channels = ""; powerToggleAllowed = false
        }
        saved.host = address; saved.port = port; saved.serverPin = pin
        saved.pinFormat = GoogleTVADBTrust.format; saved.deviceGUID = peer.guid
        try saved.save()
        pendingPeer = nil; pendingPairing = false
        message = "Paired and connected. Connection details saved."
    }
    func retryConnection() {
        guard let peer = pendingPeer, peer.host == host, let port = UInt16(connectionPort), port > 0 else {
            message = "Keep the paired TV address and enter its current Connection port."; return
        }
        let epoch = generation
        run { [self] in try await completePairing(address: peer.host, port: port, epoch: epoch) }
    }
    func updateEndpoint() {
        let address = host
        guard GoogleTVConfiguration.validHost(address), let port = UInt16(connectionPort), port > 0 else {
            message = "Enter a valid TV address and Connection port (1–65535)."; return
        }
        let epoch = generation
        run { [self] in
            let saved = GoogleTVADBConfiguration.load()
            let connection = try GoogleTVADBClient(pin: saved.trustedKeyPin()); client = connection
            message = "Verifying the paired TV at the updated address and port…"
            try await connection.connect(host: address, port: port)
            try Task.checkCancellation()
            guard generation == epoch, GoogleTVADBConfiguration.load() == saved else { throw GoogleTVError.message("Settings changed during verification. Try again.") }
            let updated = try saved.replacingEndpoint(host: address, port: port); try updated.save()
            message = "Connection saved. Existing pairing and screen permissions preserved."
        }
    }

    func save() {
        do {
            var saved = GoogleTVADBConfiguration.load()
            guard host == saved.host, let port = UInt16(connectionPort), port > 0 else { throw GoogleTVError.message("Pair a changed TV address first; enter its connection port.") }
            saved.port = port; saved.dashboardIDs = lines(screens); saved.channelIDs = lines(channels); saved.powerToggleAllowed = powerToggleAllowed
            try saved.save(); message = "Permissions saved on this device. Tap a channel in an approved screen to test playback."
        } catch { message = error.localizedDescription }
    }
    func check() {
        run { [self] in
            let saved = GoogleTVADBConfiguration.load(); try saved.validate()
            guard host == saved.host, let port = UInt16(connectionPort), port > 0 else { throw GoogleTVError.message("Check the saved TV address and current connection port.") }
            let connection = try GoogleTVADBClient(pin: saved.trustedKeyPin()); client = connection
            message = "Checking wireless debugging at \(saved.host):\(port)…"
            try await connection.connect(host: saved.host, port: port)
            try Task.checkCancellation()
            message = "Connected to the paired TV. No playback command was sent."
        }
    }
    func refreshTrust() {
        run { [self] in
            let saved = GoogleTVADBConfiguration.load(); try saved.validate()
            guard host == saved.host, let port = UInt16(connectionPort), port > 0 else { throw GoogleTVError.message("Use the already-paired TV address and its current connection port.") }
            let epoch = generation
            let connection = try GoogleTVADBClient(pin: nil); client = connection
            message = "Checking the paired TV at \(saved.host):\(port) and refreshing its debugging key…"
            try await connection.connect(host: saved.host, port: port)
            try Task.checkCancellation()
            guard generation == epoch, GoogleTVADBConfiguration.load() == saved, let pin = connection.serverPin else { throw GoogleTVError.message("Trust refresh stopped because the saved connection changed.") }
            var updated = saved
            updated.serverPin = pin; updated.pinFormat = GoogleTVADBTrust.format; updated.port = port
            try updated.save()
            message = "TV trust refreshed. Existing pairing and screen permissions preserved. Check Debugging Connection can now be repeated without a new pairing code."
        }
    }
    func forget() { stop(); pendingPeer = nil; pendingPairing = false; GoogleTVADBConfiguration.forget(); screens = ""; channels = ""; powerToggleAllowed = false; message = "Direct channel permissions removed locally. To revoke debugging authority, forget Screenpunk in the TV's Wireless debugging settings." }
    private func lines(_ value: String) -> [String] { Array(Set(value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
}

struct GoogleTVADBSetupSheet: View {
    @StateObject private var model = GoogleTVADBSetup()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                Section("Wireless debugging") {
                    Text("On the TV, enable Developer options → Wireless debugging on your trusted home network. Note the connection port, then choose Pair device with pairing code for a separate pairing port and six-digit code. USB debugging is not required.").font(.caption)
                    TextField("TV IP address", text: $model.host)
                    TextField("Connection port", text: $model.connectionPort)
                    TextField("Pairing port", text: $model.pairingPort)
                    SecureField("Six-digit pairing code", text: $model.code)
                    Text("Pairing grants this device debugging access to the TV. Screenpunk uses it only for approved channel launches and explicitly enabled TV power toggles and remembers the TV debugging public key on the first connection.").font(.caption)
                    Button("Pair and Trust This TV", action: model.pair)
                }.disabled(model.busy)
                Section("Direct channel permissions") {
                    Text("Approved screen dashboardId values, one per line.").font(.caption)
                    TextEditor(text: $model.screens).frame(minHeight: 55)
                    Text("Approved 11-character YouTube TV watch IDs, one per line. For example, the ID after /watch/ in a channel link. CNBC example: LXfrE81qMGA. Check each channel link on your TV.").font(.caption)
                    TextEditor(text: $model.channels).frame(minHeight: 55)
                    Toggle("Allow TV power toggle for approved screens", isOn: $model.powerToggleAllowed)
                    Text("Power sends one toggle. Current TV power state is unknown; check the TV before tapping again.").font(.caption)
                    Button("Save Direct Channel Permissions", action: model.save)
                    Text("If the TV changes its connection port, update it above and save. If the TV debugging service restarts or an older app saved a certificate fingerprint, use Refresh TV Trust on your trusted network. This keeps existing pairing and approvals.").font(.caption)
                    Button("Check Debugging Connection", action: model.check)
                    Button("Refresh TV Trust", action: model.refreshTrust)
                    Text("Refresh trusts the debugging key currently presented at the saved TV address and connection port. Confirm these match your TV before using it; no pairing code or playback command is sent.").font(.caption)
                    Button("Forget Direct Channels", role: .destructive, action: model.forget)
                }.disabled(model.busy)
                Section {
                    Text(model.message).textSelection(.enabled)
                    if model.busy { ProgressView(); Button("Cancel", action: { model.stop() }) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Direct Channels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 650)
        #endif
        .onDisappear { model.stop(reason: "Setup closed. Connection check cancelled; pairing preserved.") }
        .onChange(of: scenePhase) { if $0 == .background { model.stop(reason: "Screenpunk moved to the background. Keep it open while checking; pairing preserved.") } }
    }
}
