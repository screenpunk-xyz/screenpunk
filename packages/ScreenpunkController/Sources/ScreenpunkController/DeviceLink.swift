import Foundation
import ScreenpunkCore

/// One authenticated control channel to a device. The production implementation
/// wraps `ControllerLANClient` (TLS 1.3, pinned peer). Tests inject an in-memory
/// device. The controller never proxies dashboard traffic through this link;
/// devices perform their own HTTP/WS once a package is active.
public protocol DeviceLink: AnyObject {
    /// SHA-256 pin of the device identity once `hello` has run.
    var devicePin: [UInt8]? { get }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws
    func hello() throws -> LANHello
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult
    func confirmPairing(code: String) throws
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord
    func queryActive() throws -> String?
    func cancel()
}

/// Creates links that present this controller's persistent identity.
public protocol DeviceLinkFactory: Sendable {
    /// Controller identity as the device sees it: role `.controller`,
    /// `publicKey` = SHA-256 pin of the TLS public point.
    var controllerIdentity: PairingIdentity { get }
    func makeLink() throws -> DeviceLink
}

/// Controller-side record of a paired device. `device.owner` is always this
/// controller's identity; a device with another owner is never stored.
public struct PairedDeviceRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: String { device.profile.deviceId }
    public var device: PairedDevice
    public var host: String
    public var port: Int
    public var devicePinHex: String
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(
        device: PairedDevice,
        host: String,
        port: Int,
        devicePinHex: String,
        pairedAt: Date,
        lastSeenAt: Date? = nil
    ) {
        self.device = device
        self.host = host
        self.port = port
        self.devicePinHex = devicePinHex
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }

    public var devicePin: [UInt8]? { PeerPin.bytes(devicePinHex) }
}

/// File-backed list of paired devices under the controller home. Shared by the
/// MCP process and any other controller client on the same Mac.
public final class DeviceDirectory: @unchecked Sendable {
    public let url: URL
    private var records: [PairedDeviceRecord]
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        if let loaded = try? AtomicJSONStore.read([PairedDeviceRecord].self, from: url) {
            records = loaded
        } else {
            records = []
        }
    }

    public static func defaultURL(controllerHome: URL) -> URL {
        controllerHome.appendingPathComponent("devices.json")
    }

    public func list() -> [PairedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.sorted { $0.id < $1.id }
    }

    public func get(_ deviceId: String) -> PairedDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == deviceId }
    }

    public func upsert(_ record: PairedDeviceRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == record.id }
        records.append(record)
        try persist()
    }

    @discardableResult
    public func update(_ deviceId: String, _ mutate: (inout PairedDeviceRecord) -> Void) throws -> PairedDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == deviceId }) else { return nil }
        mutate(&records[index])
        try persist()
        return records[index]
    }

    @discardableResult
    public func remove(_ deviceId: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = records.count
        records.removeAll { $0.id == deviceId }
        if records.count != before {
            try persist()
            return true
        }
        return false
    }

    public func deployment(_ deploymentId: String) -> (PairedDeviceRecord, DeploymentRecord)? {
        lock.lock()
        defer { lock.unlock() }
        for record in records {
            if let match = record.device.deployments.first(where: { $0.deploymentId == deploymentId }) {
                return (record, match)
            }
        }
        return nil
    }

    private func persist() throws {
        try AtomicJSONStore.write(records, to: url)
    }
}
