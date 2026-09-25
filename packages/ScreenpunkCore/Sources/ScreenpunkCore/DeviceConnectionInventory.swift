import Foundation

/// Owner-only inventory. Deliberately excludes credential values and authentication headers.
public struct DeviceConnectionInventory: Codable, Sendable, Equatable {
    public var deviceId: String
    public var entries: [DeviceConnectionEntry]
    public init(deviceId: String, entries: [DeviceConnectionEntry]) { self.deviceId = deviceId; self.entries = entries }
}
public struct DeviceConnectionEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var screen: LANScreenSetEntry
    public var name: String
    public var kind: String
    public var origin: String
    public var authentication: String
    public var operations: [DeviceConnectionOperation]
    public var publicConnection: ManifestConnection?
    public var configurationVersion: String?
    public init(id: String, screen: LANScreenSetEntry, name: String, kind: String, origin: String,
                authentication: String, operations: [DeviceConnectionOperation], publicConnection: ManifestConnection? = nil,
                configurationVersion: String? = nil) {
        self.id = id; self.screen = screen; self.name = name; self.kind = kind; self.origin = origin
        self.authentication = authentication; self.operations = operations; self.publicConnection = publicConnection
        self.configurationVersion = configurationVersion
    }
}
public struct DeviceConnectionOperation: Codable, Sendable, Equatable {
    public var name: String
    public var method: String
    public var path: String
    public var write: Bool
    public init(name: String, method: String, path: String, write: Bool = false) {
        self.name = name; self.method = method; self.path = path; self.write = write
    }
}
/// Optimistic, atomic update of the exact installed Home Assistant scopes selected by the owner.
public struct DeviceHomeAssistantUpdate: Codable, Sendable {
    public var entries: [DeviceConnectionEntry]
    public var origin: String
    public var token: String?
    public init(entries: [DeviceConnectionEntry], origin: String, token: String?) {
        self.entries = entries; self.origin = origin; self.token = token
    }
}

/// The operating system denied LAN access; the peer's reachability is unknown.
public enum LocalNetworkAccessFailure: Error, LocalizedError, Sendable {
    case denied
    public var errorDescription: String? {
        "Local Network access is turned off for Screenpunk. Enable it in System Settings → Privacy & Security → Local Network, then retry."
    }
}
