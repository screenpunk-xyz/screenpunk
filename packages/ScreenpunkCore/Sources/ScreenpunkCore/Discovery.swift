import Foundation

/// Advertised LAN service. TXT is untrusted until pairing.
public enum DiscoveryService: Sendable {
    public static let type = "_screenpunk._tcp"
    public static let protocolMajor = 1
}

public struct AdvertisedDevice: Sendable, Equatable, Codable, Identifiable {
    public var id: String { deviceId }
    public var deviceId: String
    public var protocolMajor: Int
    public var host: String
    public var port: Int
    public var source: Source
    /// Display name the device chose to advertise (TXT `n`). Untrusted, display only.
    public var name: String?

    public enum Source: String, Sendable, Equatable, Codable {
        case advertised
        case manual
        case loopback
    }

    public init(
        deviceId: String,
        protocolMajor: Int = DiscoveryService.protocolMajor,
        host: String,
        port: Int,
        source: Source,
        name: String? = nil
    ) {
        self.deviceId = deviceId
        self.protocolMajor = protocolMajor
        self.host = host
        self.port = port
        self.source = source
        self.name = DeviceDisplayName.sanitize(name)
    }

    public var publishesSecrets: Bool { false }
}

/// In-process discovery hub for tests and the Mac loopback device.
public final class LoopbackDiscovery: @unchecked Sendable {
    public static let shared = LoopbackDiscovery()

    private var advertised: [String: AdvertisedDevice] = [:]
    private let lock = NSLock()

    public init() {}

    public func reset() {
        lock.lock()
        advertised = [:]
        lock.unlock()
    }

    public func advertise(_ device: AdvertisedDevice) {
        lock.lock()
        advertised[device.deviceId] = device
        lock.unlock()
    }

    public func withdraw(_ deviceId: String) {
        lock.lock()
        advertised.removeValue(forKey: deviceId)
        lock.unlock()
    }

    public func browse() -> [AdvertisedDevice] {
        lock.lock()
        let values = Array(advertised.values).sorted { $0.deviceId < $1.deviceId }
        lock.unlock()
        return values
    }

    public func addManual(host: String, port: Int) -> AdvertisedDevice {
        let device = AdvertisedDevice(
            deviceId: "manual:\(host):\(port)",
            host: host,
            port: port,
            source: .manual
        )
        advertise(device)
        return device
    }
}
