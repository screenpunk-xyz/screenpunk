import Foundation
import SwiftUI
import ScreenpunkApple

typealias HomeAssistantSettings = MacHomeAssistantConnection.Settings

@MainActor
final class ConnectionsStore: ObservableObject {
    @Published private(set) var installedAgents: [String]
    @Published private(set) var homeAssistant: HomeAssistantSettings?
    @Published private(set) var homeAssistantStatus = "Configured · not checked"
    var homeAssistantIsVerified: Bool { homeAssistant != nil && homeAssistantStatus == "Verified on this Mac" }
    private let defaults: UserDefaults
    private let credentials = KeychainCredentialStore(service: "xyz.screenpunk.home-assistant")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installedAgents = defaults.stringArray(forKey: "installedAgentTypes") ?? []
        if let data = defaults.data(forKey: "homeAssistantConnection") {
            homeAssistant = try? JSONDecoder().decode(HomeAssistantSettings.self, from: data)
        }
    }
    func rememberAgents(_ names: [String]) {
        let combined = Array(Set(installedAgents + names)).sorted()
        if combined != installedAgents {
            installedAgents = combined
            defaults.set(combined, forKey: "installedAgentTypes")
        }
    }
    func verify(address: String, token: String, save: Bool) async throws {
        let url = try HomeAssistantClient.baseURL(address)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret: String
        if !trimmed.isEmpty { secret = trimmed }
        else if let saved = homeAssistant, saved.address == url.absoluteString {
            let credentials = credentials
            guard let data = try await Task.detached(operation: { try credentials.secret(for: saved.authRef) }).value,
                  let value = String(data: data, encoding: .utf8) else {
                throw HomeAssistantSetupError.message("Enter a long-lived access token for this Home Assistant address.")
            }
            secret = value
        } else { throw HomeAssistantSetupError.message("Enter a long-lived access token for this Home Assistant address.") }
        do {
            try await HomeAssistantClient.verify(baseURL: url, token: secret)
            if save {
                // Write a new entry first so a failed save cannot remove the existing credential.
                let ref = UUID().uuidString
                let credentials = credentials
                try await Task.detached { try credentials.put(Data(secret.utf8), for: ref) }.value
                let settings = HomeAssistantSettings(address: url.absoluteString, authRef: ref, connectionId: homeAssistant?.connectionId ?? "home-assistant")
                let previous = homeAssistant
                defaults.set(try JSONEncoder().encode(settings), forKey: "homeAssistantConnection")
                homeAssistant = settings
                if let previous { _ = try? await Task.detached { try credentials.delete(previous.authRef) }.value }
            }
            if save || (trimmed.isEmpty && homeAssistant?.address == url.absoluteString) { homeAssistantStatus = "Verified on this Mac" }
        } catch {
            if trimmed.isEmpty && homeAssistant?.address == url.absoluteString { homeAssistantStatus = "Needs attention" }
            throw error
        }
    }
}
