import Foundation

struct GoogleTVConfiguration: Codable {
    var host: String = ""
    var pin: Data = Data()
    var automaticScreenAccess: Bool? = nil
    var dashboardIDs: [String] = []
    var appLinks: [String] = []
    // Optional preserves decoding of v1 approvals; absent means no voice permission.
    var voicePhrases: [String]? = nil
    private static let storageKey = "xyz.screenpunk.google-tv.connection.v1"
    static func load() -> Self { guard let data = UserDefaults.standard.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }; return value }
    func save() throws { try validate(); UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.storageKey) }
    static func forget() { UserDefaults.standard.removeObject(forKey: storageKey) }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }
    }
    static func validLink(_ value: String) -> Bool {
        guard value.utf8.count <= 2048, let url = URLComponents(string: value) else { return false }
        return url.scheme == "https" && url.host == "tv.youtube.com" && url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
    }
    static func validPhrase(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 160 &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func validate() throws {
        guard Self.validHost(host), pin.count == 32, dashboardIDs.count <= 32,
              dashboardIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }), appLinks.count <= 32, appLinks.allSatisfy(Self.validLink), (voicePhrases ?? []).count <= 32, (voicePhrases ?? []).allSatisfy(Self.validPhrase) else {
            throw GoogleTVError.message("Pair a TV, enter up to 32 screen IDs, and use only https://tv.youtube.com links (one per line).")
        }
    }
}

/// One bridge has one session. Every operation rechecks native permission so
/// revocation takes effect without a screen reload. No host/PIN/credential API.
@MainActor
final class GoogleTVScreenConnection {
    private let session = GoogleTVSession()
    private let loadConfiguration: () -> GoogleTVConfiguration
    init(loadConfiguration: @escaping () -> GoogleTVConfiguration = GoogleTVConfiguration.load) { self.loadConfiguration = loadConfiguration }
    private var configuration: GoogleTVConfiguration?
    private var busy = false
    private let speech = GoogleTVSpeech()
    private var generation = UUID()
    private var lastCommand = Date.distantPast
    func close() { generation = UUID(); speech.cancel(); session.close(); configuration = nil }
    func request(dashboardID: String, operation: String, parameters: [String: String]) async throws -> [String: Any] {
        let saved = loadConfiguration()
        guard (saved.automaticScreenAccess == true || saved.dashboardIDs.contains(dashboardID)), saved.pin.count == 32 else { close(); throw GoogleTVError.message("Google TV permission required. Pair and approve this screen in native Google TV settings.") }
        guard !busy else { throw GoogleTVError.message("Google TV is busy. Try again.") }
        guard (operation == "status" && parameters.isEmpty) || (operation == "key" && parameters.count == 1 && GoogleTVSession.keys[parameters["key"] ?? ""] != nil) || (operation == "launchLink" && parameters.count == 1 && saved.appLinks.contains(parameters["url"] ?? "") && GoogleTVConfiguration.validLink(parameters["url"] ?? "")) || (operation == "voice" && parameters.count == 1 && saved.voicePhrases?.contains(parameters["text"] ?? "") == true && GoogleTVConfiguration.validPhrase(parameters["text"] ?? "")) else { throw GoogleTVError.message("Google TV operation, phrase, or app link is not approved.") }
        busy = true
        let limit = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { return }
            self?.close()
        }
        defer { limit.cancel(); busy = false }
        let epoch = generation
        let audio = operation == "voice" ? try await speech.render(parameters["text"]!) : nil
        guard generation == epoch else { throw CancellationError() }
        if configuration?.host != saved.host || configuration?.pin != saved.pin { session.close(); configuration = saved }
        try await session.connect(host: saved.host, pin: saved.pin)
        try Task.checkCancellation()
        // Permission may have been revoked while connecting.
        let current = loadConfiguration()
        guard (current.automaticScreenAccess == true || current.dashboardIDs.contains(dashboardID)), current.host == saved.host, current.pin == saved.pin,
              (operation != "launchLink" || current.appLinks.contains(parameters["url"] ?? "")),
              (operation != "voice" || current.voicePhrases?.contains(parameters["text"] ?? "") == true), generation == epoch else { close(); throw GoogleTVError.message("Google TV permission was revoked.") }
        if operation == "status" { return session.status }
        guard Date().timeIntervalSince(lastCommand) >= 0.15 else { throw GoogleTVError.message("Please wait before sending another TV command.") }
        lastCommand = Date()
        if let audio {
            return try await session.voice(audio: audio) { [self] in
                let permission = loadConfiguration()
                guard generation == epoch, permission.host == saved.host, permission.pin == saved.pin,
                      (permission.automaticScreenAccess == true || permission.dashboardIDs.contains(dashboardID)), permission.voicePhrases?.contains(parameters["text"]!) == true else {
                    throw GoogleTVError.message("Google TV voice permission was revoked.")
                }
            }
        }
        else { try await session.command(key: operation == "key" ? parameters["key"] : nil, link: operation == "launchLink" ? parameters["url"] : nil) }
        return ["sent": true, "effectVerified": false]
    }
}
