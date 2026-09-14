#if os(macOS)
import Foundation
import ScreenpunkCore

/// The Mac app and its bundled MCP process share only this native credential boundary.
/// Tokens are never returned by descriptor/inspection or included in a package.
public enum MacHomeAssistantConnection {
    public struct Settings: Codable, Sendable {
        public let address: String
        public let authRef: String
        public var connectionId: String?
        public init(address: String, authRef: String, connectionId: String? = nil) {
            self.address = address; self.authRef = authRef; self.connectionId = connectionId
        }
    }
    public static func settings() -> Settings? {
        guard let data = (Bundle.main.bundleIdentifier == "xyz.screenpunk.macos" ? UserDefaults.standard : UserDefaults(suiteName: "xyz.screenpunk.macos"))?.data(forKey: "homeAssistantConnection") else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }
    public static func provisioning(dashboardId: String, revision: String, provisioningId: String) throws -> HomeAssistantProvisioning {
        guard let settings = settings(),
              let data = try KeychainCredentialStore(service: "xyz.screenpunk.home-assistant").secret(for: settings.authRef),
              let token = String(data: data, encoding: .utf8) else { throw ConnectionFailure.permissionRequired }
        guard var url = URLComponents(string: settings.address), url.path.isEmpty || url.path == "/" else {
            throw ConnectionFailure.validationFailed
        }
        url.path = ""
        guard let origin = url.string else { throw ConnectionFailure.validationFailed }
        let configuration = HomeAssistantProvisioning(dashboardId: dashboardId, connectionId: settings.connectionId ?? "home-assistant",
            provisioningId: provisioningId, revision: revision, origin: origin, allowInsecureHTTP: url.scheme == "http", token: token)
        try configuration.validate()
        return configuration
    }
    public static func descriptor() throws -> Data {
        let connections: [[String: Any]] = settings().map { _ in [[
            "alias": "home", "type": "home-assistant", "permissionMode": "homeAssistantUser",
            "operations": ["getStates"] + HomeAssistantProvisioning.services.keys.sorted(),
            "transport": "http", "phoneIndependent": true,
            "instructions": "Declare manifest connection home with HTTP operations. Use screenpunk.connections.request('home', 'getStates', {}), then read result.value. Actions require an explicit entity_id. Poll states before enabling actions, and disable actions when stale or unavailable. Entity and action permissions are enforced by Home Assistant. Never put a token or server URL in screen code. Apply installs this connection on the paired phone."
        ]]} ?? []
        return try JSONSerialization.data(withJSONObject: ["connections": connections])
    }
    public static func previewRuntime(dashboardId: String, revision: String) throws -> HomeAssistantDeviceRuntime {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        let configuration = try provisioning(dashboardId: dashboardId, revision: revision, provisioningId: UUID().uuidString)
        try vault.provision(configuration, owner: "mac-preview")
        return HomeAssistantDeviceRuntime(vault: vault, scope: { .init(owner: "mac-preview", revision: revision, dashboardId: dashboardId) })
    }
    /// A bounded read-only snapshot; parameters and attributes cannot change the destination.
    public static func inspect(query: String?) async throws -> Data {
        let configuration = try provisioning(dashboardId: "inspection", revision: "inspection", provisioningId: "inspection")
        let transport = HomeAssistantHTTPTransport()
        let response = try await transport.send(.init(url: URL(string: configuration.origin + "/api/states")!, method: "GET",
            headers: ["Authorization": "Bearer " + configuration.token], body: nil, timeout: 10, maxBytes: 1024 * 1024))
        guard response.status != 401 && response.status != 403 else { throw ConnectionFailure.permissionRequired }
        guard response.status == 200, let states = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            throw ConnectionFailure.deviceOffline
        }
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entities = states.compactMap { state -> [String: Any]? in
            guard let id = state["entity_id"] as? String else { return nil }
            let attributes = state["attributes"] as? [String: Any] ?? [:]
            let name = attributes["friendly_name"] as? String ?? id
            guard needle.isEmpty || id.localizedCaseInsensitiveContains(needle) || name.localizedCaseInsensitiveContains(needle) else { return nil }
            let allowedAttributes = ["brightness", "unit_of_measurement", "device_class", "supported_features", "source_list", "source", "volume_level"]
            return ["entity_id": id, "name": name, "state": state["state"] ?? NSNull(),
                    "attributes": attributes.filter { allowedAttributes.contains($0.key) }]
        }
        return try JSONSerialization.data(withJSONObject: ["alias": "home", "permissionMode": "homeAssistantUser", "entities": Array(entities.prefix(200)), "totalMatches": entities.count, "truncated": entities.count > 200])
    }
    /// The existing MCP router is synchronous. Run network I/O on a separate task with a bound.
    public static func inspectBlocking(query: String?) throws -> Data {
        let result = InspectionResult()
        let task = Task.detached { do { result.finish(.success(try await inspect(query: query))) } catch { result.finish(.failure(error)) } }
        guard result.ready.wait(timeout: .now() + 16) == .success else { task.cancel(); throw ConnectionFailure.timeout }
        return try result.value!.get()
    }
    private final class InspectionResult: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var value: Result<Data, Error>?
        func finish(_ value: Result<Data, Error>) { self.value = value; ready.signal() }
    }
}
#endif
