import Foundation
#if os(macOS)
import Darwin

public protocol WorkbenchClock: Sendable { func now() -> TimeInterval }
public struct WorkbenchSystemClock: WorkbenchClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
public protocol WorkbenchPeerCredentials: Sendable { func effectiveUID(socket: Int32) throws -> UInt32 }
public struct WorkbenchSystemPeerCredentials: WorkbenchPeerCredentials {
    public init() {}
    public func effectiveUID(socket: Int32) throws -> UInt32 {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0 else { throw WorkbenchIPCError(.unauthorizedPeer) }
        return uid
    }
}
public struct WorkbenchIPCLimits: Sendable {
    public let maxFrameBytes: Int
    public let maxConnections: Int
    public let maxStagingBytes: Int
    public let timeout: TimeInterval
    public init(maxFrameBytes: Int = 8 * 1024 * 1024, maxConnections: Int = 32,
                maxStagingBytes: Int = 64 * 1024 * 1024, timeout: TimeInterval = 10) {
        self.maxFrameBytes = maxFrameBytes; self.maxConnections = maxConnections
        self.maxStagingBytes = maxStagingBytes; self.timeout = timeout
    }
}
public struct WorkbenchBrokerEnvironment: Sendable {
    public static var currentUID: UInt32 { geteuid() }
    public let runtimeDirectory: URL
    public let ownerUID: UInt32
    public let limits: WorkbenchIPCLimits
    public let peerCredentials: any WorkbenchPeerCredentials
    public let clock: any WorkbenchClock
    public init(runtimeDirectory: URL, ownerUID: UInt32 = WorkbenchBrokerEnvironment.currentUID,
                limits: WorkbenchIPCLimits = .init(),
                peerCredentials: any WorkbenchPeerCredentials = WorkbenchSystemPeerCredentials(),
                clock: any WorkbenchClock = WorkbenchSystemClock()) throws {
        let path = runtimeDirectory.path
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard runtimeDirectory.isFileURL, path.hasPrefix("/"), !path.contains("\0"), path != "/",
              !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              (path + "/broker.sock").utf8.count < 104,
              limits.maxFrameBytes >= 512, limits.maxFrameBytes <= 8 * 1024 * 1024,
              limits.maxConnections >= 1, limits.maxConnections <= 32,
              limits.maxStagingBytes >= limits.maxFrameBytes, limits.maxStagingBytes <= 64 * 1024 * 1024,
              limits.timeout.isFinite, limits.timeout > 0, limits.timeout <= 120
        else { throw WorkbenchIPCError(.invalidConfiguration) }
        self.runtimeDirectory = runtimeDirectory; self.ownerUID = ownerUID; self.limits = limits
        self.peerCredentials = peerCredentials; self.clock = clock
    }
}
#endif
