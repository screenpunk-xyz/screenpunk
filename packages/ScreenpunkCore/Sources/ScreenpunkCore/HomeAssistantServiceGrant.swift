import Foundation

/// Owner-installed declarations authorize service semantics, including scripts' downstream effects.
/// Entity lists constrain explicit REST targets; they cannot constrain what a service does internally.
public struct HomeAssistantServiceGrant: Codable, Sendable, Equatable {
    public var domain: String
    public var service: String
    public var entityIds: [String]
    public var allowUntargeted: Bool?

    public init(domain: String, service: String, entityIds: [String] = [], allowUntargeted: Bool = false) {
        self.domain = domain; self.service = service; self.entityIds = entityIds
        self.allowUntargeted = allowUntargeted
    }

    private static func identifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.range(of: "^[a-z0-9_]+$", options: .regularExpression) == value.startIndex..<value.endIndex
    }
    private static func entity(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.split(separator: ".", omittingEmptySubsequences: false).count == 2 &&
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier(String($0)) }
    }
    public static func validate(_ grants: [Self]) throws {
        guard grants.count <= 128 else { throw ConnectionFailure.sizeLimit }
        var seen = Set<String>()
        for grant in grants {
            guard identifier(grant.domain), identifier(grant.service), grant.entityIds.count <= 128,
                  grant.entityIds.allSatisfy(entity), Set(grant.entityIds).count == grant.entityIds.count,
                  !grant.entityIds.isEmpty || grant.allowUntargeted == true,
                  seen.insert(grant.domain + "." + grant.service).inserted else { throw ConnectionFailure.validationFailed }
        }
    }

    /// A JSON envelope preserves the existing string-parameter wire protocol on every native host.
    static func authorize(_ parameters: [String: String], grants: [Self]) throws -> (path: String, body: Data?) {
        try validate(grants)
        guard Set(parameters.keys) == ["call"], let raw = parameters["call"] else { throw ConnectionFailure.validationFailed }
        guard raw.utf8.count <= 32 * 1024 else { throw ConnectionFailure.sizeLimit }
        guard let data = raw.data(using: .utf8),
              let call = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(call.keys).isSubset(of: ["domain", "service", "target", "serviceData"]),
              let domain = call["domain"] as? String, let service = call["service"] as? String,
              identifier(domain), identifier(service),
              let payload = call["serviceData"] as? [String: Any] else { throw ConnectionFailure.validationFailed }
        guard let grant = grants.first(where: { $0.domain == domain && $0.service == service }) else {
            throw ConnectionFailure.permissionRequired
        }
        var nodes = 0
        try validateJSON(payload, depth: 0, nodes: &nodes)
        // REST flattens targets into the service body. Never let serviceData replace a target.
        guard Set(payload.keys).isDisjoint(with: ["entity_id", "device_id", "area_id", "floor_id", "label_id", "target"]) else {
            throw ConnectionFailure.permissionRequired
        }
        var body = payload
        if let target = call["target"] {
            guard let target = target as? [String: Any], Set(target.keys) == ["entity_id"] else {
                throw ConnectionFailure.permissionRequired
            }
            let ids: [String]
            if let id = target["entity_id"] as? String { ids = [id] }
            else if let values = target["entity_id"] as? [String] { ids = values }
            else { throw ConnectionFailure.validationFailed }
            guard !ids.isEmpty, ids.count <= 128, ids.allSatisfy(entity),
                  Set(ids).count == ids.count, Set(ids).isSubset(of: Set(grant.entityIds)) else {
                throw ConnectionFailure.permissionRequired
            }
            body["entity_id"] = ids
        } else {
            guard grant.allowUntargeted == true else { throw ConnectionFailure.permissionRequired }
        }
        let encoded = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        guard encoded.count <= 32 * 1024 else { throw ConnectionFailure.sizeLimit }
        return ("/api/services/\(domain)/\(service)", encoded)
    }

    private static func validateJSON(_ value: Any, depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 12, nodes <= 2048 else { throw ConnectionFailure.sizeLimit }
        if let object = value as? [String: Any] {
            for (key, item) in object {
                guard key.utf8.count <= 128 else { throw ConnectionFailure.sizeLimit }
                try validateJSON(item, depth: depth + 1, nodes: &nodes)
            }
        } else if let array = value as? [Any] {
            for item in array { try validateJSON(item, depth: depth + 1, nodes: &nodes) }
        } else if let string = value as? String {
            guard string.utf8.count <= 8192 else { throw ConnectionFailure.sizeLimit }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw ConnectionFailure.validationFailed }
        } else if !(value is NSNull) { throw ConnectionFailure.validationFailed }
    }
}
