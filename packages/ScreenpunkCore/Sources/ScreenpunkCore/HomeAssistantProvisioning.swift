import Foundation

/// Sent only over the paired owner TLS channel, never in a screen package.
public struct HomeAssistantProvisioning: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var dashboardId: String
    public var connectionId: String
    public var provisioningId: String
    public var revision: String
    public var origin: String
    public var allowInsecureHTTP: Bool
    public var permissionMode: String
    public var token: String

    public init(schemaVersion: Int = 1, dashboardId: String, connectionId: String, provisioningId: String, revision: String, origin: String, allowInsecureHTTP: Bool = false,
                permissionMode: String = "homeAssistantUser", token: String) {
        self.schemaVersion = schemaVersion
        self.dashboardId = dashboardId
        self.connectionId = connectionId
        self.provisioningId = provisioningId
        self.revision = revision
        self.origin = origin
        self.allowInsecureHTTP = allowInsecureHTTP
        self.permissionMode = permissionMode
        self.token = token
    }

    public func validate() throws {
        guard schemaVersion == 1, [dashboardId, connectionId, provisioningId, revision].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              permissionMode == "homeAssistantUser" else {
            throw ConnectionFailure.validationFailed
        }
        try ConnectionGrantValidator.validate(connectionGrant(path: "/api/states", write: false))
    }

    public static let services: [String: (domain: String, service: String)] = [
        "lightOn": ("light", "turn_on"), "lightOff": ("light", "turn_off"),
        "switchOn": ("switch", "turn_on"), "switchOff": ("switch", "turn_off"),
        "scriptOn": ("script", "turn_on"),
        "sceneOn": ("scene", "turn_on"), "mediaPlayPause": ("media_player", "media_play_pause"),
        "volumeSet": ("media_player", "volume_set"), "selectSource": ("media_player", "select_source")
    ]

    public func connectionGrant(path: String, write: Bool) -> ConnectionGrant {
        ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "home", origin: origin,
                        transport: .http, authRef: "home-device", lan: true,
                        allowInsecureHTTP: allowInsecureHTTP,
                        operations: [.init(name: "request", kind: .http, method: write ? .POST : .GET,
                                           path: path, idempotent: !write, write: write)])
    }

    /// Fixed service routes and a single explicit entity prevent broad target calls.
    public func authorize(operation: String, parameters: [String: String]) throws -> (path: String, body: Data?) {
        if operation == "getStates" {
            guard parameters.isEmpty else { throw ConnectionFailure.permissionRequired }
            return ("/api/states", nil)
        }
        guard let service = Self.services[operation], let id = parameters["entity_id"],
              id.utf8.count <= 255,
              id.range(of: "^[a-z0-9_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil,
              id.hasPrefix(service.domain + ".") else {
            throw ConnectionFailure.permissionRequired
        }
        var allowed: Set<String> = ["entity_id"]
        var body: [String: Any] = ["entity_id": id]
        if operation == "lightOn", let raw = parameters["brightness"] {
            guard let value = Int(raw), (0...255).contains(value) else { throw ConnectionFailure.validationFailed }
            allowed.insert("brightness"); body["brightness"] = value
        }
        if operation == "volumeSet" {
            guard let raw = parameters["volume_level"], let value = Double(raw), value.isFinite, (0...1).contains(value) else {
                throw ConnectionFailure.validationFailed
            }
            allowed.insert("volume_level"); body["volume_level"] = value
        }
        if operation == "selectSource" {
            guard let source = parameters["source"], !source.isEmpty, source.utf8.count <= 256 else {
                throw ConnectionFailure.validationFailed
            }
            allowed.insert("source"); body["source"] = source
        }
        guard Set(parameters.keys).isSubset(of: allowed) else { throw ConnectionFailure.permissionRequired }
        return ("/api/services/\(service.domain)/\(service.service)", try JSONSerialization.data(withJSONObject: body))
    }

    public func filterStates(_ data: Data) throws -> Data {
        guard let states = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConnectionFailure.validationFailed
        }
        // HA's authenticated response is authoritative; never freeze a discovery snapshot as a grant.
        return try JSONSerialization.data(withJSONObject: states)
    }
}

/// Installation is distinct from reachability: provisioning performs no HA request.
public struct HomeAssistantProvisioningReceipt: Codable, Sendable, Equatable {
    public var deviceId: String
    public var dashboardId: String
    public var revision: String
    public var connectionId: String
    public var provisioningId: String
    public var installed = true
    public var reachability = "not_checked"
    public init(deviceId: String, dashboardId: String, revision: String, connectionId: String, provisioningId: String) {
        self.deviceId = deviceId; self.dashboardId = dashboardId; self.revision = revision
        self.connectionId = connectionId; self.provisioningId = provisioningId
    }
}
