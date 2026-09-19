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
    public var serviceCalls: [HomeAssistantServiceGrant]?
    public var cameraEntities: [String]?
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
        guard [1, 2, 3].contains(schemaVersion), [dashboardId, connectionId, provisioningId, revision].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              permissionMode == "homeAssistantUser" else {
            throw ConnectionFailure.validationFailed
        }
        guard schemaVersion >= 2 || serviceCalls == nil else { throw ConnectionFailure.validationFailed }
        guard schemaVersion == 3 || cameraEntities == nil else { throw ConnectionFailure.validationFailed }
        try CameraSource.validateEntities(cameraEntities ?? [])
        try HomeAssistantServiceGrant.validate(serviceCalls ?? [])
        try ConnectionGrantValidator.validate(connectionGrant(path: "/api/states", write: false))
    }

    public static let services: [String: (domain: String, service: String)] = [
        "lightOn": ("light", "turn_on"), "lightOff": ("light", "turn_off"),
        "switchOn": ("switch", "turn_on"), "switchOff": ("switch", "turn_off"),
        "scriptOn": ("script", "turn_on"),
        "mediaOn": ("media_player", "turn_on"), "mediaOff": ("media_player", "turn_off"),
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

    /// Legacy aliases retain their validation; general calls use revision-bound declarations.
    public func authorize(operation: String, parameters: [String: String]) throws -> (path: String, body: Data?) {
        if operation == "callService" {
            guard schemaVersion >= 2 else { throw ConnectionFailure.permissionRequired }
            return try HomeAssistantServiceGrant.authorize(parameters, grants: serviceCalls ?? [])
        }
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
        if operation == "lightOn", let raw = parameters["rgb_color"] {
            guard raw.utf8.count <= 64, let data = raw.data(using: .utf8),
                  let channels = try? JSONDecoder().decode([Int].self, from: data),
                  channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else {
                throw ConnectionFailure.validationFailed
            }
            allowed.insert("rgb_color"); body["rgb_color"] = channels
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
        if schemaVersion >= 2 {
            body.removeValue(forKey: "entity_id")
            let call: [String: Any] = ["domain": service.domain, "service": service.service,
                                       "target": ["entity_id": id], "serviceData": body]
            let data = try JSONSerialization.data(withJSONObject: call)
            return try HomeAssistantServiceGrant.authorize(["call": String(decoding: data, as: UTF8.self)], grants: serviceCalls ?? [])
        }
        return ("/api/services/\(service.domain)/\(service.service)", try JSONSerialization.data(withJSONObject: body))
    }

    /// The owner binds declarations to the installed revision, outside screen JavaScript.
    public func scoped(to manifest: DashboardManifest) throws -> Self {
        var copy = self
        guard dashboardId == manifest.dashboardId, revision == manifest.revision else { throw ConnectionFailure.permissionRequired }
        copy.serviceCalls = manifest.connections.first(where: { $0.alias == "home" })?.serviceCalls
        if copy.serviceCalls != nil { copy.schemaVersion = 2 }
        copy.cameraEntities = manifest.connections.first(where: { $0.alias == "home" })?.cameraEntities
        if copy.cameraEntities != nil { copy.schemaVersion = 3 }
        try copy.validate()
        return copy
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
