import Foundation

#if os(macOS)
public enum WorkbenchNetworkAuthorizationObservation: String, Codable, Sendable {
    case notAssessed = "not_assessed"
    case authorized
    case denied
}

/// An embedding owner may supply an already-known, read-only authorization
/// observation. The broker never starts a LAN operation to produce doctor data.
public struct WorkbenchNativeDiagnosticProvider {
    public let networkAuthorization: () -> WorkbenchNetworkAuthorizationObservation
    public init(networkAuthorization: @escaping () -> WorkbenchNetworkAuthorizationObservation) {
        self.networkAuthorization = networkAuthorization
    }
}

public struct WorkbenchNativeDoctorRead: Codable, Sendable, Equatable {
    public static let method = "system.doctorNative"
    public let schemaVersion: Int
    public let kind: String
    public let scope: String
    public let identityState: String
    public let identityPersistence: String
    public let networkTransport: String
    public let networkAuthorization: WorkbenchNetworkAuthorizationObservation
    public let complete: Bool

    init(identityLoaded: Bool, transportAttached: Bool,
         authorization: WorkbenchNetworkAuthorizationObservation) {
        schemaVersion = 1; kind = "nativeDoctor"; scope = "broker-owner-memory"
        identityState = identityLoaded ? "loaded" : "not_loaded"
        identityPersistence = "not_assessed"
        networkTransport = transportAttached ? "attached" : "not_attached"
        networkAuthorization = authorization; complete = false
    }

    public func validate() throws {
        guard schemaVersion == 1, kind == "nativeDoctor", scope == "broker-owner-memory",
              ["loaded", "not_loaded"].contains(identityState),
              identityPersistence == "not_assessed",
              ["attached", "not_attached"].contains(networkTransport),
              identityState != "loaded" || networkTransport == "attached",
              !complete else { throw WorkbenchIPCError(.invalidRequest) }
    }
}
#endif
