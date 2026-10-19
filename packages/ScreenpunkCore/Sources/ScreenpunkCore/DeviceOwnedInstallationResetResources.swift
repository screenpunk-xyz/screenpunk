import Foundation

/// Original resource qualification only; this evidence does not authorize deletion.
/// A reset owner must durably bind these exact associations before suspending writers.
@_spi(NativeInstallation) public final class DeviceOwnedInstallationResetResources: Encodable, CustomReflectable {
    public struct Root: Codable, Equatable, Sendable {
        public let rootID: UUID
        public let path: String
        public let device: UInt64
        public let inode: UInt64
    }
    public struct Credential: Codable, Equatable, Sendable {
        public let service: String
        public let account: String
        public let persistentReference: Data
        public let byteCount: Int
        public let valueSHA256: String
    }
    public let installationID: UUID
    public let roots: [Root]
    public let credentials: [Credential]
    private let resourceOperation: (((() throws -> Void) throws -> Void))?
    private enum CodingKeys: String, CodingKey { case installationID, roots, credentials }
    public func withCurrentResourcesExact(_ operation: () throws -> Void) throws {
        guard let resourceOperation else { throw DeviceLocalResourceGateFailure.invalidScope }
        try resourceOperation(operation)
    }
    internal init(installationID: UUID, roots: [Root], credentials: [Credential],
        resourceOperation: (((() throws -> Void) throws -> Void))? = nil) throws {
        guard roots.count <= 1024, Set(roots.map(\.rootID)).count == roots.count,
              Set(roots.map(\.path)).count == roots.count, credentials.count <= 32768 else {
            throw DeviceLocalResourceGateFailure.invalidRoots
        }
        var keyed: [String: Credential] = [:]
        for item in credentials {
            let key = item.service + "\0" + item.account
            if let old = keyed[key], old != item { throw DeviceLocalResourceGateFailure.invalidRoots }
            keyed[key] = item
        }
        self.resourceOperation = resourceOperation
        self.installationID = installationID
        self.roots = roots.sorted { $0.path < $1.path }
        self.credentials = keyed.values.sorted { ($0.service, $0.account) < ($1.service, $1.account) }
    }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
