import Foundation

/// Dedicated native Cloud configuration. Calendar OAuth configuration is never consulted.
struct CloudNativeConfiguration: Sendable {
    let projectID: String
    let apiKey: String
    let appID: String
    let senderID: String
    let googleClientID: String
    let callbackScheme: String
    let apiOrigin: URL
    let bundleID: String

    static func load(bundle: Bundle = .main) throws -> Self {
        try load(info: bundle.infoDictionary ?? [:], bundleID: bundle.bundleIdentifier)
    }

    static func load(info: [String: Any], bundleID: String?) throws -> Self {
        func value(_ key: String) throws -> String {
            guard let text = info[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.contains("$("), !text.contains("${") else { throw CloudNativeIdentityError.notConfigured }
            return text
        }
        let project = try value("ScreenpunkCloudFirebaseProjectID")
        let apiKey = try value("ScreenpunkCloudFirebaseAPIKey")
        let appID = try value("ScreenpunkCloudFirebaseAppID")
        let sender = try value("ScreenpunkCloudFirebaseSenderID")
        let client = try value("ScreenpunkCloudGoogleClientID")
        let callback = try value("ScreenpunkCloudGoogleCallbackScheme")
        let expectedBundle = try value("ScreenpunkCloudBundleID")
        let originText = try value("ScreenpunkCloudAPIOrigin")
        guard bundleID == expectedBundle,
              appID.hasPrefix("1:\(sender):ios:"),
              client.hasSuffix(".apps.googleusercontent.com"),
              callback == "com.googleusercontent.apps." + client.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""),
              let origin = URL(string: originText), origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              let types = info["CFBundleURLTypes"] as? [[String: Any]],
              let cloudType = types.first(where: { $0["CFBundleURLName"] as? String == "Screenpunk Cloud OAuth" }),
              (cloudType["CFBundleURLSchemes"] as? [String]) == [callback],
              !types.filter({ $0["CFBundleURLName"] as? String != "Screenpunk Cloud OAuth" }).contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(callback) == true })
        else { throw CloudNativeIdentityError.notConfigured }
        return .init(projectID: project, apiKey: apiKey, appID: appID, senderID: sender,
                     googleClientID: client, callbackScheme: callback, apiOrigin: origin, bundleID: expectedBundle)
    }

    func acceptsGoogleCallback(_ url: URL) -> Bool {
        url.scheme == callbackScheme && url.host == nil && url.path == "/oauth2callback"
    }
}

enum CloudNativeIdentityError: Error, Equatable {
    case notConfigured, cancelled, flowInProgress, signedOut, invalidCredential, providerFailed
}
