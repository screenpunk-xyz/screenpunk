import Foundation
import ScreenpunkCore

struct GoogleCalendarEntry: Codable, Identifiable, Equatable {
    var id: String
    var summary: String
    var timeZone: String?
    var backgroundColor: String?
}
struct GoogleCalendarAccount: Codable, Identifiable {
    var id: String // Google subject, obtained directly from Google's userinfo endpoint.
    var email: String
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var calendars: [GoogleCalendarEntry] = []
    var displayName: String?
    var pictureURL: String?
}
struct GoogleCalendarSelection: Codable, Hashable {
    var accountID: String
    var calendarID: String
}
struct GoogleCalendarState: Codable {
    var accounts: [GoogleCalendarAccount] = []
    var selections: [String: [GoogleCalendarSelection]] = [:]
}

/// All persistent Calendar data, including account metadata and selections, is
/// stored in a device-only Keychain item. Screen packages never receive tokens.
@MainActor
final class GoogleCalendarDeviceService {
    static let shared = GoogleCalendarDeviceService()
    static let storageKey = "google-calendar-v1"
    private let store: any CredentialStore
    private let transport: any HTTPTransport
    private let clock: any PairingClock
    private(set) var generation = UUID()
    private var refreshing: [String: Task<GoogleCalendarAccount, Error>] = [:]
    private struct Cache { var value: [[String: Any]]; var fetchedAt: Date }
    private var cache: [String: Cache] = [:]
    private var retryAt = Date.distantPast

    init(store: any CredentialStore = KeychainCredentialStore(service: "xyz.screenpunk.google-calendar"),
         transport: any HTTPTransport = HomeAssistantHTTPTransport(), clock: any PairingClock = SystemClock()) {
        self.store = store; self.transport = transport; self.clock = clock
    }
    func snapshot() throws -> GoogleCalendarState {
        guard let data = try store.secret(for: Self.storageKey) else { return .init() }
        return try JSONDecoder().decode(GoogleCalendarState.self, from: data)
    }
    private func save(_ value: GoogleCalendarState) throws {
        try store.put(JSONEncoder().encode(value), for: Self.storageKey)
    }
    func isReady(dashboard: String) -> Bool {
        guard let state = try? snapshot() else { return false }
        return !(state.selections[dashboard] ?? []).isEmpty
    }
    func select(dashboard: String, selection: GoogleCalendarSelection, enabled: Bool) throws {
        var state = try snapshot()
        guard state.accounts.contains(where: { $0.id == selection.accountID && $0.calendars.contains(where: { $0.id == selection.calendarID }) }) else { throw GoogleCalendarError.permission }
        var chosen = state.selections[dashboard] ?? []
        chosen.removeAll { $0 == selection }
        if enabled { guard chosen.count < 20 else { throw GoogleCalendarError.tooLarge }; chosen.append(selection) }
        state.selections[dashboard] = chosen
        try save(state); invalidate()
    }
    private func invalidate() {
        generation = UUID(); cache.removeAll()
        refreshing.values.forEach { $0.cancel() }; refreshing.removeAll()
    }
    func disconnect(accountID: String) throws {
        var state = try snapshot()
        state.accounts.removeAll { $0.id == accountID }
        for key in Array(state.selections.keys) { state.selections[key]?.removeAll { $0.accountID == accountID } }
        try save(state); invalidate()
        // Local removal intentionally does not revoke the project-wide Google grant,
        // which could disconnect other independently authorized devices.
    }
    func erase() throws {
        try store.delete(Self.storageKey); invalidate()
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw GoogleCalendarError.permission }
    }
    private func json(url: URL, method: String = "GET", fields: [String: String]? = nil, token: String? = nil) async throws -> [String: Any] {
        guard Date() >= retryAt else { throw GoogleCalendarError.rateLimited }
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer " + token }
        if fields != nil { headers["Content-Type"] = "application/x-www-form-urlencoded" }
        let response = try await transport.send(.init(url: url, method: method, headers: headers,
            body: fields.map(GoogleCalendarOAuth.form), timeout: 15, maxBytes: 2 * 1024 * 1024))
        try Task.checkCancellation()
        if response.status == 429 || response.status >= 500 {
            let delay = Double(response.headers["retry-after"] ?? "") ?? 60
            retryAt = Date().addingTimeInterval(min(3600, max(30, delay)))
            throw GoogleCalendarError.rateLimited
        }
        guard !(300...399).contains(response.status) else { throw GoogleCalendarError.authorization }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { throw GoogleCalendarError.unavailable }
        if response.status == 401 || object["error"] as? String == "invalid_grant" { throw GoogleCalendarError.reconnect }
        if response.status == 403 { throw GoogleCalendarError.permission }
        guard (200...299).contains(response.status) else { throw GoogleCalendarError.unavailable }
        return object
    }
    private func credentials(_ json: [String: Any], previous: GoogleCalendarAccount? = nil) throws -> (String, String, Date) {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let seconds = json["expires_in"] as? Double, seconds > 0,
              (json["token_type"] as? String)?.lowercased() == "bearer",
              let refresh = json["refresh_token"] as? String ?? previous?.refreshToken, !refresh.isEmpty else { throw GoogleCalendarError.reconnect }
        if let scopes = json["scope"] as? String {
            guard Set(GoogleCalendarOAuth.calendarScopes).isSubset(of: Set(scopes.split(separator: " ").map(String.init))) else { throw GoogleCalendarError.permission }
        } else if previous == nil { throw GoogleCalendarError.permission }
        return (access, refresh, Date().addingTimeInterval(seconds))
    }
    func connect(oauth: GoogleCalendarOAuth, code: String, expected: UUID) async throws {
        try check(expected)
        let tokens = try await json(url: URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", fields: [
            "client_id": oauth.clientID, "code": code, "code_verifier": oauth.verifier,
            "redirect_uri": oauth.redirectURI, "grant_type": "authorization_code"])
        try check(expected)
        let (access, refresh, expiry) = try credentials(tokens)
        let identity = try await json(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, token: access)
        try check(expected)
        guard let subject = identity["sub"] as? String, !subject.isEmpty,
              let email = identity["email"] as? String, identity["email_verified"] as? Bool == true else { throw GoogleCalendarError.authorization }
        var state = try snapshot()
        let existing = state.accounts.first { $0.id == subject }
        state.accounts.removeAll { $0.id == subject }
        state.accounts.append(.init(id: subject, email: email, clientID: oauth.clientID, accessToken: access,
                                    refreshToken: refresh, expiresAt: expiry, calendars: existing?.calendars ?? [],
                                    displayName: identity["name"] as? String, pictureURL: Self.profilePicture(identity["picture"] as? String)))
        try save(state); invalidate()
        try await reloadCalendars(accountID: subject)
    }
    private func account(_ id: String) async throws -> GoogleCalendarAccount {
        guard let saved = try snapshot().accounts.first(where: { $0.id == id }) else { throw GoogleCalendarError.permission }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved }
        let expected = generation
        if let task = refreshing[id] { let result = try await task.value; try check(expected); return result }
        let task = Task { @MainActor in
            let tokens = try await self.json(url: URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", fields: [
                "client_id": saved.clientID, "refresh_token": saved.refreshToken, "grant_type": "refresh_token"])
            try self.check(expected)
            let (access, refresh, expiry) = try self.credentials(tokens, previous: saved)
            var state = try self.snapshot()
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else { throw GoogleCalendarError.permission }
            state.accounts[index].accessToken = access; state.accounts[index].refreshToken = refresh; state.accounts[index].expiresAt = expiry
            try self.save(state)
            return state.accounts[index]
        }
        refreshing[id] = task
        defer { if generation == expected { refreshing.removeValue(forKey: id) } }
        return try await task.value
    }
    private func pages(path: String, query: [String: String], accountID: String) async throws -> [[String: Any]] {
        let expected = generation
        var account = try await account(accountID)
        var values: [[String: Any]] = []
        var pageToken: String?
        for _ in 0..<20 {
            var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
            var fields = query; fields["pageToken"] = pageToken
            parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            let result: [String: Any]
            do { result = try await json(url: parts.url!, token: account.accessToken) }
            catch GoogleCalendarError.reconnect {
                try check(expected)
                var state = try snapshot()
                guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { throw GoogleCalendarError.permission }
                state.accounts[index].expiresAt = .distantPast; try save(state)
                account = try await self.account(accountID)
                result = try await json(url: parts.url!, token: account.accessToken)
            }
            try check(expected)
            values.append(contentsOf: result["items"] as? [[String: Any]] ?? [])
            guard values.count <= 10_000 else { throw GoogleCalendarError.tooLarge }
            pageToken = result["nextPageToken"] as? String
            if pageToken == nil { return values }
        }
        throw GoogleCalendarError.tooLarge
    }
    func reloadCalendars(accountID: String) async throws {
        let expected = generation
        let items = try await pages(path: "users/me/calendarList", query: ["maxResults": "250", "minAccessRole": "reader"], accountID: accountID)
        try check(expected)
        let entries = items.compactMap { item -> GoogleCalendarEntry? in
            guard let id = item["id"] as? String, let title = item["summary"] as? String else { return nil }
            return .init(id: id, summary: item["summaryOverride"] as? String ?? title, timeZone: item["timeZone"] as? String, backgroundColor: item["backgroundColor"] as? String)
        }
        var state = try snapshot()
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { throw GoogleCalendarError.permission }
        state.accounts[index].calendars = entries
        for key in Array(state.selections.keys) {
            state.selections[key]?.removeAll { selection in selection.accountID == accountID && !entries.contains(where: { $0.id == selection.calendarID }) }
        }
        try save(state); invalidate()
    }
    // A profile image is optional metadata, never an authenticated API URL.
    static func profilePicture(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 4096, let url = URL(string: value),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return value
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    func events(dashboard: String, parameters: [String: String]) async throws -> (value: [String: Any], stale: Bool) {
        guard Set(parameters.keys) == Set(["timeMin", "timeMax"]),
              let startText = parameters["timeMin"], let endText = parameters["timeMax"],
              let start = Self.date(startText), let end = Self.date(endText), end > start,
              end.timeIntervalSince(start) <= 31 * 86400 else { throw GoogleCalendarError.invalidRequest }
        let state = try snapshot()
        let selected = state.selections[dashboard] ?? []
        guard !selected.isEmpty else { throw GoogleCalendarError.permission }
        // Use owner-selected calendar metadata, never infer the inventory from events.
        // Fail closed if stored selections no longer resolve to authorized metadata.
        let calendars: [[String: String]] = try selected.map { selection in
            guard let account = state.accounts.first(where: { $0.id == selection.accountID }),
                  let calendar = account.calendars.first(where: { $0.id == selection.calendarID }) else { throw GoogleCalendarError.permission }
            return ["accountID": selection.accountID, "calendarID": selection.calendarID, "displayName": calendar.summary]
        }
        let key = dashboard + "|" + startText + "|" + endText
        let expected = generation
        let selectedAccountIDs = Set(selected.map(\.accountID))
        let profiles: [[String: Any]] = state.accounts.filter { selectedAccountIDs.contains($0.id) }.map { account in
            var profile: [String: Any] = ["accountID": account.id, "displayName": account.displayName ?? account.email]
            profile["pictureURL"] = Self.profilePicture(account.pictureURL)
            return profile
        }
        func response(_ entry: Cache, stale: Bool) -> (value: [String: Any], stale: Bool) {
            (["events": entry.value, "accounts": profiles, "calendars": calendars, "fetchedAt": ISO8601DateFormatter().string(from: entry.fetchedAt)], stale)
        }
        if let cached = cache[key], clock.now.timeIntervalSince(cached.fetchedAt) < 60 { return response(cached, stale: false) }
        do {
            var events: [[String: Any]] = []
            for selection in selected {
                try check(expected)
                let escaped = selection.calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                let items = try await pages(path: "calendars/" + escaped + "/events", query: [
                    "timeMin": startText, "timeMax": endText, "singleEvents": "true", "orderBy": "startTime", "maxResults": "250", "showDeleted": "false"], accountID: selection.accountID)
                try check(expected)
                for item in items where item["status"] as? String != "cancelled" {
                    // Return display fields only. Preserve Google's all-day date strings,
                    // exclusive end dates, offsets and timeZone rather than coercing them.
                    var event: [String: Any] = ["accountID": selection.accountID, "calendarID": selection.calendarID]
                    for field in ["id", "summary", "start", "end", "location", "status"] { event[field] = item[field] }
                    event["summary"] = item["summary"] as? String ?? "Busy"
                    events.append(event)
                }
                guard events.count <= 10_000 else { throw GoogleCalendarError.tooLarge }
            }
            try check(expected)
            guard try JSONSerialization.data(withJSONObject: events).count <= 2 * 1024 * 1024 else { throw GoogleCalendarError.tooLarge }
            let entry = Cache(value: events, fetchedAt: clock.now)
            if cache.count >= 16 { cache.removeAll() }
            cache[key] = entry
            return response(entry, stale: false)
        } catch {
            try check(expected)
            let transient = error is URLError || (error as? GoogleCalendarError) == .rateLimited || (error as? GoogleCalendarError) == .unavailable
            if transient, let cached = cache[key], clock.now.timeIntervalSince(cached.fetchedAt) < 900 { return response(cached, stale: true) }
            cache.removeValue(forKey: key)
            throw error
        }
    }
}
