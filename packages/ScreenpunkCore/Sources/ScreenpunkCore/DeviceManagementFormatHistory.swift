import Foundation

/// Explicit local key formats; neither format confers remote authority.
public struct DeviceManagementFormatHistory: Codable, Equatable, Sendable {
    public struct Binding: Codable, Equatable, Sendable {
        public let credentialGenerationID: UUID
        public let transitionID: UUID
        public let credentialReference: String
        public let format: CloudInstallationCredentialFormat
        public init(credentialGenerationID: UUID, transitionID: UUID, credentialReference: String, format: CloudInstallationCredentialFormat) throws {
            _ = try DeviceManagementCredentialBinding(credentialGenerationID: credentialGenerationID, transitionID: transitionID, credentialReference: credentialReference)
            self.credentialGenerationID = credentialGenerationID; self.transitionID = transitionID
            self.credentialReference = credentialReference; self.format = format
        }
        private enum CodingKeys: String, CodingKey { case credentialGenerationID, transitionID, credentialReference, format }
        public init(from decoder: Decoder) throws {
            try exactFormatKeys(decoder, ["credentialGenerationID", "transitionID", "credentialReference", "format"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let format = CloudInstallationCredentialFormat(rawValue: try c.decode(String.self, forKey: .format)) else { throw DeviceManagementTransitionStoreError.invalidRecord }
            try self.init(credentialGenerationID: c.decode(UUID.self, forKey: .credentialGenerationID), transitionID: c.decode(UUID.self, forKey: .transitionID), credentialReference: c.decode(String.self, forKey: .credentialReference), format: format)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(credentialGenerationID, forKey: .credentialGenerationID); try c.encode(transitionID, forKey: .transitionID)
            try c.encode(credentialReference, forKey: .credentialReference); try c.encode(format.rawValue, forKey: .format)
        }
    }
    public let schemaVersion: Int
    public let transitions: [DeviceManagementTransitionEntry]
    public let credentials: [Binding]
    public init(transitions: [DeviceManagementTransitionEntry], credentials: [Binding]) throws {
        _ = try DeviceManagementTransitionHistory(transitions: transitions, credentials: credentials.map {
            try DeviceManagementCredentialBinding(credentialGenerationID: $0.credentialGenerationID, transitionID: $0.transitionID, credentialReference: $0.credentialReference)
        })
        schemaVersion = 3; self.transitions = transitions; self.credentials = credentials
    }
    public init(legacy: DeviceManagementTransitionHistory) throws {
        try self.init(transitions: legacy.transitions, credentials: legacy.credentials.map {
            try Binding(credentialGenerationID: $0.credentialGenerationID, transitionID: $0.transitionID, credentialReference: $0.credentialReference, format: .legacyLocal32)
        })
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, transitions, credentials }
    public init(from decoder: Decoder) throws {
        try exactFormatKeys(decoder, ["schemaVersion", "transitions", "credentials"])
        let c = try decoder.container(keyedBy: CodingKeys.self), version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 3 else { throw DeviceManagementTransitionStoreError.unsupportedVersion(version) }
        try self.init(transitions: c.decode([DeviceManagementTransitionEntry].self, forKey: .transitions), credentials: c.decode([Binding].self, forKey: .credentials))
    }
}

public enum DeviceManagementEvidence: Equatable, Sendable {
    case legacy(DeviceManagementTransitionHistory)
    case formatted(DeviceManagementFormatHistory)
    public var formattedHistory: DeviceManagementFormatHistory {
        get throws {
            switch self { case .legacy(let h): return try .init(legacy: h); case .formatted(let h): return h }
        }
    }
}
private struct FormatKey: CodingKey {
    let stringValue: String; let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
}
private func exactFormatKeys(_ decoder: Decoder, _ keys: Set<String>) throws {
    let c = try decoder.container(keyedBy: FormatKey.self)
    guard Set(c.allKeys.map(\.stringValue)) == keys else { throw DeviceManagementTransitionStoreError.invalidRecord }
}
