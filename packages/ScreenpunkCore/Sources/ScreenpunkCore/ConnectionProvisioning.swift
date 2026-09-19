import Foundation

/// Trusted native approval sent only on the paired owner channel. Never a dashboard asset or SDK payload.
public struct ConnectionProvisioning: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var grant: ConnectionGrant
        public var binding: ConnectionAuthBinding
        public var secret: Data?
        public init(grant: ConnectionGrant, binding: ConnectionAuthBinding, secret: Data? = nil) {
            self.grant = grant; self.binding = binding; self.secret = secret
        }
    }
    public var schemaVersion: Int
    public var dashboardId: String
    public var revision: String
    public var provisioningId: String
    public var entries: [Entry]
    public init(schemaVersion: Int = 1, dashboardId: String, revision: String, provisioningId: String = UUID().uuidString, entries: [Entry]) {
        self.schemaVersion = schemaVersion; self.dashboardId = dashboardId; self.revision = revision
        self.provisioningId = provisioningId; self.entries = entries
    }
    public func validate() throws {
        guard schemaVersion == 1, [dashboardId, revision, provisioningId].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              entries.count <= 32 else { throw ConnectionFailure.validationFailed }
        var aliases = Set<String>(), refs = Set<String>()
        for entry in entries {
            try ConnectionGrantValidator.validate(entry.grant)
            guard aliases.insert(entry.grant.alias).inserted, refs.insert(entry.grant.authRef).inserted,
                  entry.binding.authRef == entry.grant.authRef else { throw ConnectionFailure.validationFailed }
            if entry.binding.placement == .none {
                guard entry.secret == nil, entry.binding.fieldName == nil else { throw ConnectionFailure.validationFailed }
            } else {
                guard let secret = entry.secret, !secret.isEmpty, secret.count <= 8192,
                      let value = String(data: secret, encoding: .utf8),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ConnectionFailure.validationFailed
                }
                if entry.binding.placement == .bearer {
                    guard entry.binding.fieldName == nil,
                          !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw ConnectionFailure.validationFailed }
                } else {
                    guard let field = entry.binding.fieldName, !field.isEmpty, field.utf8.count <= 128,
                          field.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
                          !ConnectionAuthKeys.isDestination(field),
                          !["host", "cookie", "content-length", "transfer-encoding", "connection", "upgrade"].contains(field.lowercased()) else {
                        throw ConnectionFailure.validationFailed
                    }
                }
            }
        }
    }
}

public struct ConnectionProvisioningReceipt: Codable, Sendable, Equatable {
    public var deviceId: String
    public var dashboardId: String
    public var revision: String
    public var provisioningId: String
    public var installed: Bool = true
    public var reachability: String = "not_checked"
    public init(deviceId: String, dashboardId: String, revision: String, provisioningId: String) {
        self.deviceId = deviceId; self.dashboardId = dashboardId; self.revision = revision; self.provisioningId = provisioningId
    }
}
