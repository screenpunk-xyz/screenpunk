import Foundation
import ScreenpunkCore

public enum WorkbenchDeviceDomainError: Error, Equatable {
    case invalidEndpoint, stalePairing, codeMismatch, expiredPairing, notOwned
}

public struct WorkbenchPairingView: Sendable, Equatable {
    public let pendingId: String
    public let deviceId: String
    public let deviceName: String
    public let host: String
    public let port: Int
    public let matchingCode: String
    public let devicePinHex: String
    public let controllerPinHex: String
    public let expiresAt: Date
    public let rePairing: Bool
}

/// Service-owned adapter over DeviceCoordinator. It never creates an identity,
/// transport or device by itself; the host injects the existing native owner.
public final class WorkbenchDeviceDomain {
    private struct Pending {
        let view: WorkbenchPairingView
        let nativeSessionID: UUID
        let transportGeneration: UInt64
    }
    private let devices: DeviceCoordinator
    private let now: () -> Date
    private let boundary: WorkbenchAuthorityBoundary
    #if os(macOS)
    private let authority: WorkbenchLocalAuthorityStore?
    #endif
    private var pending: [String: Pending] = [:]

    public init(devices: DeviceCoordinator, now: @escaping () -> Date = { Date() }) {
        self.devices = devices; self.now = now; boundary = WorkbenchAuthorityBoundary()
        #if os(macOS)
        authority = nil
        #endif
    }
    #if os(macOS)
    init(devices: DeviceCoordinator, authority: WorkbenchLocalAuthorityStore,
         boundary: WorkbenchAuthorityBoundary,
         now: @escaping () -> Date = { Date() }) {
        self.devices = devices; self.authority = authority; self.boundary = boundary; self.now = now
    }
    #endif

    public var transportAvailable: Bool { devices.transportAvailable }
    public func discover() -> [AdvertisedDevice] { boundary.withDevice("") { devices.discover() } }
    public func registerEndpoint(host: String, port: Int) throws -> AdvertisedDevice {
        try boundary.withDevice("") {
        guard (1...65535).contains(port), (1...253).contains(host.utf8.count),
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-:[]".unicodeScalars.contains($0) }),
              !host.hasPrefix("-"), !host.contains("..") else { throw WorkbenchDeviceDomainError.invalidEndpoint }
        return devices.addManual(host: host, port: port)
        }
    }
    public func beginPairing(deviceId: String? = nil, host: String? = nil, port: Int? = nil) throws -> WorkbenchPairingView {
        return try boundary.withDevice(deviceId ?? "") {
        let result = try devices.requestPairing(deviceId: deviceId, host: host, port: port)
        guard let controller = devices.controllerIdentity else { throw WorkbenchDeviceDomainError.stalePairing }
        pending = pending.filter { $0.value.view.deviceId != result.deviceId }
        let view = WorkbenchPairingView(pendingId: UUID().uuidString.lowercased(), deviceId: result.deviceId,
            deviceName: DeviceDisplayName.label(name: result.deviceName, deviceId: result.deviceId, fallback: "Device"),
            host: result.host, port: result.port, matchingCode: result.code,
            devicePinHex: result.devicePinHex, controllerPinHex: PeerPin.hex(controller.publicKey),
            expiresAt: result.expiresAt, rePairing: result.rePairing)
        pending[view.pendingId] = Pending(view: view, nativeSessionID: result.sessionID,
                                         transportGeneration: devices.currentTransportGeneration)
        return view
        }
    }
    public func pendingPairings() -> [WorkbenchPairingView] {
        return boundary.withDevice("") {
        let active = Set(devices.pendingPairings().map(\.sessionID))
        return pending.values.filter { active.contains($0.nativeSessionID) && now() < $0.view.expiresAt }
            .map(\.view)
            .sorted { $0.pendingId < $1.pendingId }
        }
    }
    public func confirmPairing(pendingId: String, matchingCode: String) throws -> PairedDeviceRecord {
        return try boundary.withDevice("") {
        guard let entry = pending[pendingId],
              entry.transportGeneration == devices.currentTransportGeneration,
              devices.pendingPairings().contains(where: { $0.deviceId == entry.view.deviceId &&
                  $0.sessionID == entry.nativeSessionID }) else {
            throw WorkbenchDeviceDomainError.stalePairing
        }
        guard now() < entry.view.expiresAt else {
            devices.cancelPending(entry.view.deviceId, expectedSessionID: entry.nativeSessionID)
            pending[pendingId] = nil
            throw WorkbenchDeviceDomainError.expiredPairing
        }
        guard matchingCode == entry.view.matchingCode else {
            devices.cancelPending(entry.view.deviceId, expectedSessionID: entry.nativeSessionID)
            pending[pendingId] = nil
            throw WorkbenchDeviceDomainError.codeMismatch
        }
        #if os(macOS)
        // Retire prior local consent before the device can accept a re-pair.
        // A crash between remote confirmation and local epoch recording must
        // leave grants unusable, even if the peer pin is unchanged.
        if let authority {
            try authority.update { state in
                guard let identity = devices.controllerIdentity else { throw WorkbenchAuthorityError.invalidState }
                try state.synchronizeController(identity)
                state.forgot(deviceId: entry.view.deviceId)
            }
        }
        #endif
        let record = try devices.confirmPairing(deviceId: entry.view.deviceId,
                                                expectedSessionID: entry.nativeSessionID)
        #if os(macOS)
        if let authority {
            try authority.update { state in
                guard let identity = devices.controllerIdentity else { throw WorkbenchAuthorityError.invalidState }
                try state.synchronizeController(identity)
                try state.paired(deviceId: record.id, peerPin: record.devicePinHex)
            }
        }
        #endif
        pending[pendingId] = nil
        return record
        }
    }
    public func cancelPairing(pendingId: String) throws {
        try boundary.withDevice("") {
        guard let entry = pending.removeValue(forKey: pendingId) else { throw WorkbenchDeviceDomainError.stalePairing }
        devices.cancelPending(entry.view.deviceId, expectedSessionID: entry.nativeSessionID)
        }
    }
    public func cachedDevices() -> [PairedDeviceRecord] { boundary.withDevice("") { devices.listDevices() } }
    public func status(deviceId: String, refresh: Bool = false) throws -> PairedDeviceRecord {
        try boundary.withDevice(deviceId) { try devices.device(deviceId, probe: refresh) }
    }
    public func forget(deviceId: String) throws -> Bool {
        return try boundary.withDevice(deviceId) {
        pending = pending.filter { $0.value.view.deviceId != deviceId }
        #if os(macOS)
        // Durable local retirement must precede the native directory effect.
        // A failed authority write leaves pairing intact; a failed native
        // delete leaves a safely retired grant that needs fresh consent.
        if let authority { try authority.update { $0.forgot(deviceId: deviceId) } }
        #endif
        let removed = try devices.forget(deviceId: deviceId) // Mac-only; device retains its owner until local Disconnect.
        return removed
        }
    }
    public func settingsGet(deviceId: String) throws -> DeviceSettingsSnapshot {
        try boundary.withDevice(deviceId) {
        try requireOwned(deviceId)
        return try devices.fetchDeviceSettings(deviceId: deviceId)
        }
    }
    public func settingsUpdate(deviceId: String, expectedRevision: String, value: DeviceSettings) throws -> DeviceSettingsSnapshot {
        try boundary.withDevice(deviceId) {
        try requireOwned(deviceId)
        return try devices.updateDeviceSettings(deviceId: deviceId,
            update: DeviceSettingsUpdate(expectedRevision: expectedRevision, value: value))
        }
    }
    public func connectionInventory(deviceId: String) throws -> DeviceConnectionInventory {
        try boundary.withDevice(deviceId) {
        try requireOwned(deviceId)
        return try devices.connectionInventory(deviceId: deviceId)
        }
    }
    private func requireOwned(_ deviceId: String) throws {
        guard let identity = devices.controllerIdentity,
              let record = devices.directory.get(deviceId), record.device.owner == identity else {
            throw WorkbenchDeviceDomainError.notOwned
        }
    }
}
