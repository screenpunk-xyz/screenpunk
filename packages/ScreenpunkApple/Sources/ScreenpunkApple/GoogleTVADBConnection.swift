import Foundation

struct GoogleTVADBConfiguration: Codable, Equatable {
    var host = ""
    var port: UInt16 = 0
    var serverPin = Data()
    var deviceGUID = ""
    var automaticScreenAccess: Bool? = nil
    var dashboardIDs: [String] = []
    var channelIDs: [String] = []
    // nil decodes the original whole-certificate pins without losing pairing.
    var pinFormat: String? = nil
    var powerToggleAllowed: Bool? = nil
    private static let key = "xyz.screenpunk.google-tv.adb.configuration.v1"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    func validate() throws {
        guard GoogleTVConfiguration.validHost(host), port > 0, serverPin.count == 32, !deviceGUID.isEmpty,
              dashboardIDs.count <= 32, dashboardIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              channelIDs.count <= 32, channelIDs.allSatisfy(GoogleTVChannelLaunch.validID) else {
            throw GoogleTVError.message("Pair wireless debugging and approve up to 32 screen IDs and YouTube TV channel IDs.")
        }
    }
    func replacingEndpoint(host: String, port: UInt16) throws -> Self {
        var updated = self
        updated.host = host; updated.port = port
        try updated.validate()
        return updated
    }
    func save() throws { try validate(); UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.key) }
    func trustedKeyPin() throws -> Data {
        try validate()
        guard pinFormat == GoogleTVADBTrust.format else {
            throw GoogleTVError.message("This connection needs a one-time TV trust refresh. Open Direct Channels and choose Refresh TV Trust. Your existing pairing is preserved.")
        }
        return serverPin
    }
    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
    func permits(dashboard: String, channel: String) -> Bool {
        (try? validate()) != nil && (automaticScreenAccess == true || (dashboardIDs.contains(dashboard) && channelIDs.contains(channel))) && GoogleTVChannelLaunch.validID(channel)
    }
}

@MainActor
final class GoogleTVADBScreenConnection {
    private let load: () -> GoogleTVADBConfiguration
    private var client: (any GoogleTVADBSession)?
    private let makeClient: (Data) throws -> any GoogleTVADBSession
    private var busy = false
    private var epoch = UUID()
    init(load: @escaping () -> GoogleTVADBConfiguration = GoogleTVADBConfiguration.load, makeClient: @escaping (Data) throws -> any GoogleTVADBSession = { try GoogleTVADBClient(pin: $0) }) { self.load = load; self.makeClient = makeClient }
    func close() { epoch = UUID(); client?.close(); client = nil }
    func launch(dashboard: String, parameters: [String: String]) async throws -> [String: Any] {
        try await perform(dashboard: dashboard, parameters: parameters, power: false)
    }
    func togglePower(dashboard: String, parameters: [String: String]) async throws -> [String: Any] {
        try await perform(dashboard: dashboard, parameters: parameters, power: true)
    }
    private func perform(dashboard: String, parameters: [String: String], power: Bool) async throws -> [String: Any] {
        let saved = load()
        let channel = parameters["channelID"]
        if power {
            guard parameters.isEmpty, (saved.automaticScreenAccess == true || (saved.powerToggleAllowed == true && saved.dashboardIDs.contains(dashboard))) else {
                throw GoogleTVError.message("Approve this screen and enable TV power in native Direct Channels settings first.")
            }
        } else {
            guard parameters.count == 1, let channel, saved.permits(dashboard: dashboard, channel: channel) else {
                throw GoogleTVError.message("Approve this screen and channel in native Direct Channels settings first.")
            }
        }
        guard !busy else { throw GoogleTVError.message("A direct TV command is already in progress.") }
        busy = true
        defer { busy = false; close() }
        let currentEpoch = epoch
        let connection = try makeClient(saved.trustedKeyPin())
        client = connection
        let deadline = Task { do { try await Task.sleep(nanoseconds: 35_000_000_000); connection.close() } catch {} }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await connection.connect(host: saved.host, port: saved.port)
            try Task.checkCancellation()
            guard epoch == currentEpoch, load() == saved else { throw GoogleTVError.message("Direct TV permission changed. No command was sent.") }
            if power { try await connection.togglePower() }
            else if let channel { try await connection.launch(channelID: channel) }
            return ["sent": true, "effectVerified": false, "transport": "wireless-adb"]
        } onCancel: { connection.close() }
    }
}
