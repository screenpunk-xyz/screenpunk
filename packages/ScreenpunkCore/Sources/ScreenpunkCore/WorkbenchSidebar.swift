import Foundation

/// Owner-facing device names. Identifiers and addresses never stand in for a name.
public enum DeviceDisplayName: Sendable {
    public static let maxLength = 40

    /// Trims, drops control characters, caps length. Empty becomes nil.
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var view = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars
        where CharacterSet.controlCharacters.contains(scalar) == false
            && CharacterSet.newlines.contains(scalar) == false
        {
            view.append(scalar)
        }
        let text = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return String(text.prefix(maxLength))
    }

    /// True when `text` is machine-made: the device id, a `manual:` key, a
    /// host, a `host:port`, or an IPv6 literal with a scope id.
    public static func looksLikeIdentifier(_ text: String, deviceId: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == deviceId { return true }
        if trimmed.hasPrefix("manual:") { return true }
        if trimmed.contains(":") || trimmed.contains("%") { return true }
        let ipv4 = CharacterSet(charactersIn: "0123456789.")
        return trimmed.unicodeScalars.allSatisfy { ipv4.contains($0) }
    }

    /// Name to show for a device; `fallback` is context copy when none is usable.
    public static func label(name: String?, deviceId: String, fallback: String) -> String {
        guard let name = sanitize(name), looksLikeIdentifier(name, deviceId: deviceId) == false else {
            return fallback
        }
        return name
    }
}

public extension WorkbenchCopy {
    static let devicesSection = "Devices"
    static let addDeviceSection = "Add Device"
    static let refresh = "Refresh"
    static let pair = "Pair"
    static let pairAgain = "Pair Again"
    static let addByAddress = "Add by address"
    static let developerSection = "Developer"
    static let developerToggle = "Show simulator and raw addresses"
    static let nearbyDevice = "Nearby device"
    static let pairedDevice = "Paired device"
    static let simulatorDevice = "Simulator on this Mac"
    static let onYourNetwork = "On your network"
    static let addedByAddress = "Added by address"
    static let noDevices = "No devices yet. Add one below."
    static let noNearby =
        "Open Screenpunk on your iPhone or iPad and keep it on screen. It appears here."
    static let hostPlaceholder = "Host or IP"
    static let portPlaceholder = "Port"
    static let invalidAddress = "Enter the host and port shown on the device's Ready to pair screen."
    static let pairingInProgress = "Pairing · match the code"
    static let ready = "Ready"
    static let unreachable = "Unreachable"
    static let noDashboard = "No dashboard"
    static let dashboardDeployed = "Dashboard deployed"
}

/// What the Mac sidebar shows an owner. The in-process loopback fixture,
/// entries that duplicate its address, and raw addresses stay hidden until the
/// developer view is on. Nothing here changes what the hub knows.
public enum WorkbenchSidebar: Sendable {
    public struct NearbyEntry: Sendable, Equatable, Identifiable {
        public var id: String { advertisement.deviceId }
        public var advertisement: AdvertisedDevice
        public var title: String
        public var subtitle: String

        public init(advertisement: AdvertisedDevice, title: String, subtitle: String) {
            self.advertisement = advertisement
            self.title = title
            self.subtitle = subtitle
        }
    }

    public static func isSimulator(_ advertisement: AdvertisedDevice) -> Bool {
        advertisement.source == .loopback
    }

    /// Ids of paired devices that came from the loopback fixture. Derived from
    /// the hub because `PairedDevice` does not record its source.
    public static func simulatorDeviceIds(advertisements: [AdvertisedDevice]) -> Set<String> {
        Set(advertisements.filter(isSimulator).map(\.deviceId))
    }

    public static func isSimulator(_ device: PairedDevice, advertisements: [AdvertisedDevice]) -> Bool {
        simulatorDeviceIds(advertisements: advertisements).contains(device.profile.deviceId)
    }

    public static func visibleDevices(
        _ devices: [PairedDevice],
        advertisements: [AdvertisedDevice],
        developer: Bool
    ) -> [PairedDevice] {
        if developer { return devices }
        let simulators = simulatorDeviceIds(advertisements: advertisements)
        return devices.filter { simulators.contains($0.profile.deviceId) == false }
    }

    /// Devices worth offering to pair. Owner view: no loopback fixture and
    /// nothing at its address, one row per address (advertised beats manual),
    /// nothing already in `devices`, sorted advertised first.
    public static func nearby(
        advertisements: [AdvertisedDevice],
        devices: [PairedDevice],
        developer: Bool
    ) -> [NearbyEntry] {
        var candidates = advertisements
        if developer == false {
            let simulatorAddresses = Set(candidates.filter(isSimulator).map(addressKey))
            candidates.removeAll { isSimulator($0) || simulatorAddresses.contains(addressKey($0)) }
            candidates = dedupeByAddress(candidates)
            let known = Set(devices.map(\.profile.deviceId))
            candidates.removeAll { known.contains($0.deviceId) }
        }
        return candidates
            .map { NearbyEntry(advertisement: $0, title: title(for: $0), subtitle: subtitle(for: $0, developer: developer)) }
            .sorted { lhs, rhs in
                let l = rank(lhs.advertisement.source), r = rank(rhs.advertisement.source)
                if l != r { return l < r }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.advertisement.deviceId < rhs.advertisement.deviceId
            }
    }

    /// The advertisement to reuse when re-pairing a known device.
    public static func advertisement(
        for device: PairedDevice,
        in advertisements: [AdvertisedDevice]
    ) -> AdvertisedDevice? {
        advertisements.first { $0.deviceId == device.profile.deviceId }
    }

    public static func title(for advertisement: AdvertisedDevice) -> String {
        switch advertisement.source {
        case .loopback:
            return WorkbenchCopy.simulatorDevice
        case .manual:
            return address(of: advertisement)
        case .advertised:
            return DeviceDisplayName.label(
                name: advertisement.name,
                deviceId: advertisement.deviceId,
                fallback: WorkbenchCopy.nearbyDevice
            )
        }
    }

    public static func subtitle(for advertisement: AdvertisedDevice, developer: Bool) -> String {
        if developer {
            return "\(advertisement.source.rawValue) · \(address(of: advertisement))"
        }
        switch advertisement.source {
        case .loopback: return WorkbenchCopy.simulatorDevice
        case .manual: return WorkbenchCopy.addedByAddress
        case .advertised: return WorkbenchCopy.onYourNetwork
        }
    }

    public static func title(for device: PairedDevice, advertisements: [AdvertisedDevice]) -> String {
        if isSimulator(device, advertisements: advertisements) {
            return DeviceDisplayName.label(
                name: device.profile.name,
                deviceId: device.profile.deviceId,
                fallback: WorkbenchCopy.simulatorDevice
            )
        }
        return DeviceDisplayName.label(
            name: device.profile.name,
            deviceId: device.profile.deviceId,
            fallback: WorkbenchCopy.pairedDevice
        )
    }

    public static func subtitle(for device: PairedDevice) -> String {
        if device.pairingCode != nil { return WorkbenchCopy.pairingInProgress }
        let reach = device.reachable ? WorkbenchCopy.ready : WorkbenchCopy.unreachable
        let orientation = device.profile.orientation.rawValue.capitalized
        let dashboard: String
        if let active = device.activeRevision {
            dashboard = device.history.first { $0.revision == active }?.name
                ?? (active == StoredRevision.offlineFixture.revision
                    ? StoredRevision.offlineFixture.name
                    : WorkbenchCopy.dashboardDeployed)
        } else {
            dashboard = WorkbenchCopy.noDashboard
        }
        return "\(reach) · \(orientation) · \(dashboard)"
    }

    public static func address(of advertisement: AdvertisedDevice) -> String {
        let host = advertisement.host.contains(":") ? "[\(advertisement.host)]" : advertisement.host
        return "\(host):\(advertisement.port)"
    }

    /// Host as typed, without surrounding brackets or whitespace. Nil when empty.
    public static func normalizeHost(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        return host.isEmpty ? nil : host
    }

    public static func parsePort(_ text: String) -> Int? {
        guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port)
        else { return nil }
        return port
    }

    // MARK: Private

    private static func rank(_ source: AdvertisedDevice.Source) -> Int {
        switch source {
        case .advertised: return 0
        case .manual: return 1
        case .loopback: return 2
        }
    }

    private static func addressKey(_ advertisement: AdvertisedDevice) -> String {
        "\(advertisement.host.lowercased()):\(advertisement.port)"
    }

    /// One entry per `host:port`; advertised wins over manual, manual over loopback.
    private static func dedupeByAddress(_ advertisements: [AdvertisedDevice]) -> [AdvertisedDevice] {
        var best: [String: AdvertisedDevice] = [:]
        var order: [String] = []
        for ad in advertisements {
            let key = addressKey(ad)
            if let existing = best[key] {
                if rank(ad.source) < rank(existing.source) { best[key] = ad }
            } else {
                best[key] = ad
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }
}
