import Foundation
import CryptoKit
import Security

/// Native installed-app authorization. No client secret or Screenpunk server.
struct GoogleCalendarOAuth {
    static let calendarScopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly"
    ]
    static let scopes = ["openid", "email", "profile"] + calendarScopes
    let clientID: String
    let state: String
    let verifier: String
    var callbackScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    init(clientID: String) throws {
        guard clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.range(of: "^[A-Za-z0-9-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil else {
            throw GoogleCalendarError.notConfigured
        }
        self.clientID = clientID
        state = try Self.random(); verifier = try Self.random()
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleCalendarError.authorization }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var authorizationURL: URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientID, "redirect_uri": redirectURI, "response_type": "code",
                          "scope": Self.scopes.joined(separator: " "), "state": state,
                          "code_challenge": Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
                          "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    func code(from callback: URL) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == callbackScheme, parts.host == nil, parts.path == "/oauth2redirect", parts.fragment == nil else {
            throw GoogleCalendarError.authorization
        }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }), items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw GoogleCalendarError.authorization }
        return code
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

enum GoogleCalendarError: String, Error, LocalizedError {
    case notConfigured, authorization, reconnect, permission, invalidRequest, tooLarge, unavailable, rateLimited
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google Calendar sign-in is not configured in this build."
        case .authorization: return "Google authorization was cancelled or could not be verified. Try connecting again."
        case .reconnect: return "Reconnect this Google account in Settings → Google Calendar."
        case .permission: return "Choose calendars for this screen in Settings → Google Calendar."
        case .invalidRequest: return "The calendar request is invalid."
        case .tooLarge: return "Too many calendar results. Request a shorter date range."
        case .unavailable: return "Google Calendar is temporarily unavailable. Try again."
        case .rateLimited: return "Google Calendar is busy. Wait before trying again."
        }
    }
}
