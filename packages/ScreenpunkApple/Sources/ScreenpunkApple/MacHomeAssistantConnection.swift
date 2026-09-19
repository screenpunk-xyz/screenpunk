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
            "cameraPlaybackContract": ["version": 1, "manifestField": "connections[].cameraEntities", "sdkMethod": "cameras.mount", "sources": ["homeAssistant"], "maxVisiblePlayers": 3] as [String: Any],
            "operations": ["getStates", "callService", "cameraPresent", "cameraClose"] + HomeAssistantProvisioning.services.keys.sorted(),
            "transport": "http", "phoneIndependent": true,
            "serviceCallContract": ["version": 1, "manifestField": "connections[].serviceCalls", "maxCallBytes": 32768,
                                    "maxDepth": 12, "maxNodes": 2048, "maxStringBytes": 8192,
                                    "targets": ["entity_id"], "requiresFreshStates": true, "replaysWrites": false] as [String: Any],
            "instructions": "Declare home serviceCalls with domain, service, entityIds; optionally allowUntargeted for explicitly authorized targetless services. Call screenpunk.homeAssistant.callService({domain, service, target:{entity_id:'light.example'}, serviceData:{rgb_color:[255,0,0]}}). Service data accepts bounded nested JSON. Poll connections.request('home','getStates',{}) first; disable actions when stale or unavailable. Home Assistant enforces its authenticated user's permissions. Declarations authorize the whole service including downstream script effects. No wildcards, areas or devices; target keys belong in target, not serviceData. Legacy screens retain named operations; screens with serviceCalls also constrain legacy actions to those declarations. Never put tokens or server URLs in screen code. New declarations require updated native hosts; apply binds grants to the screen revision. Inspect query services: lists the live service catalog; services:light filters a domain. See docs/home-assistant-services.md."
        ]]} ?? []
        return try JSONSerialization.data(withJSONObject: ["connections": connections])
    }
    public static func previewRuntime(dashboardId: String, revision: String, manifest: DashboardManifest? = nil) throws -> HomeAssistantDeviceRuntime {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        var configuration = try provisioning(dashboardId: dashboardId, revision: revision, provisioningId: UUID().uuidString)
        if let manifest { configuration = try configuration.scoped(to: manifest) }
        try vault.provision(configuration, owner: "mac-preview")
        return HomeAssistantDeviceRuntime(vault: vault, scope: { .init(owner: "mac-preview", revision: revision, dashboardId: dashboardId) })
    }
    /// A bounded read-only snapshot; parameters and attributes cannot change the destination.
    public static func inspect(query: String?) async throws -> Data {
        let configuration = try provisioning(dashboardId: "inspection", revision: "inspection", provisioningId: "inspection")
        let services = query?.hasPrefix("services:") == true
        let path = services ? "/api/services" : "/api/states"
        let destination = try ConnectionPolicy.authorize(grant: configuration.connectionGrant(path: path, write: false),
            operationName: "request", parameters: [:],
            resolvedAddresses: LiteralOrResolvedDestinationResolver().addresses(for: ConnectionPolicy.originHost(configuration.origin)),
            binding: .init(authRef: "home-device", placement: .bearer))
        let transport = HomeAssistantHTTPTransport()
        let response = try await transport.send(.init(url: destination.url, method: "GET",
            headers: ["Authorization": "Bearer " + configuration.token], body: nil, timeout: 10, maxBytes: 1024 * 1024))
        guard response.status != 401 && response.status != 403 else { throw ConnectionFailure.permissionRequired }
        guard response.status == 200, let states = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            throw ConnectionFailure.deviceOffline
        }
        if services {
            let domain = String((query ?? "").dropFirst("services:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = states.filter { domain.isEmpty || ($0["domain"] as? String) == domain }
            return try JSONSerialization.data(withJSONObject: ["alias": "home", "services": matches,
                "permissionMode": "homeAssistantUser", "instructions": "Discovery is descriptive, not an authorization grant. Declare the needed service and explicit targets in the screen manifest."])
        }
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entities = states.compactMap { state -> [String: Any]? in
            guard let id = state["entity_id"] as? String else { return nil }
            let attributes = state["attributes"] as? [String: Any] ?? [:]
            let name = attributes["friendly_name"] as? String ?? id
            guard needle.isEmpty || id.localizedCaseInsensitiveContains(needle) || name.localizedCaseInsensitiveContains(needle) else { return nil }
            let allowedAttributes = ["brightness", "unit_of_measurement", "device_class", "supported_features", "source_list", "source", "volume_level", "supported_color_modes", "color_mode", "rgb_color", "rgbw_color", "rgbww_color", "hs_color", "color_temp_kelvin", "min_color_temp_kelvin", "max_color_temp_kelvin", "media_title", "media_artist", "media_album_name", "app_id", "app_name", "media_content_id", "media_content_type", "media_duration", "media_position", "media_position_updated_at", "shuffle", "repeat", "is_volume_muted"]
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
