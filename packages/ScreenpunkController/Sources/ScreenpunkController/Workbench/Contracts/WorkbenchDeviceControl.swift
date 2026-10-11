import Foundation
import CoreFoundation
import ScreenpunkCore

public struct WorkbenchPairingRead: Codable, Sendable, Equatable {
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
    init(_ value: WorkbenchPairingView) {
        pendingId = value.pendingId; deviceId = value.deviceId; deviceName = value.deviceName
        host = value.host; port = value.port; matchingCode = value.matchingCode
        devicePinHex = value.devicePinHex; controllerPinHex = value.controllerPinHex
        expiresAt = value.expiresAt; rePairing = value.rePairing
    }
}

/// Fresh pinned-link observation for layout and exact installed-set review.
/// Construction is restricted to DeviceCoordinator.observeScreenSet, which
/// rejects stale, unowned, ambiguous, or screen-set-incompatible peers.
public struct WorkbenchDeviceScreenSetRead: Codable, Sendable, Equatable {
    public let deviceId: String
    public let name: String
    public let profile: DeviceProfile
    public let screens: [LANScreenSetEntry]
    public let selectedDashboardId: String?
    public let observedAt: Date
    public let authority: String
    public let deviceProfileHash: String
    public let installedSetHash: String
    public var stateGenerationId: String? = nil
    init(deviceId: String, name: String, profile: DeviceProfile,
         screens: [LANScreenSetEntry], selectedDashboardId: String?, observedAt: Date, stateGenerationId: String? = nil) throws {
        self.stateGenerationId = stateGenerationId
        self.deviceId = deviceId; self.name = name; self.profile = profile
        self.screens = screens; self.selectedDashboardId = selectedDashboardId
        self.observedAt = observedAt; authority = "fresh-pinned-owned-screen-set-v1"
        deviceProfileHash = try WorkbenchDeploymentHash.profile(profile)
        installedSetHash = try WorkbenchDeploymentHash.installedSet(screens,
            selected: selectedDashboardId)
    }
}

public struct WorkbenchDeviceActionResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let discovered: [AdvertisedDevice]?
    public let endpoint: AdvertisedDevice?
    public let pairing: WorkbenchPairingRead?
    public let pending: [WorkbenchPairingRead]?
    public let device: WorkbenchDeviceRead?
    public let removed: Bool?
    public let settings: DeviceSettingsSnapshot?
    public let connections: DeviceConnectionInventory?
    public let screenSet: WorkbenchDeviceScreenSetRead?
    init(kind: String, discovered: [AdvertisedDevice]? = nil, endpoint: AdvertisedDevice? = nil,
         pairing: WorkbenchPairingRead? = nil, pending: [WorkbenchPairingRead]? = nil,
         device: WorkbenchDeviceRead? = nil, removed: Bool? = nil,
         settings: DeviceSettingsSnapshot? = nil, connections: DeviceConnectionInventory? = nil,
         screenSet: WorkbenchDeviceScreenSetRead? = nil) {
        schemaVersion = 1; self.kind = kind; self.discovered = discovered; self.endpoint = endpoint
        self.pairing = pairing; self.pending = pending; self.device = device; self.removed = removed
        self.settings = settings; self.connections = connections; self.screenSet = screenSet
    }
    func validate(for method: WorkbenchDeviceControlMethod) throws {
        guard schemaVersion == 1,
              [discovered != nil, endpoint != nil, pairing != nil, pending != nil, device != nil,
               removed != nil, settings != nil, connections != nil, screenSet != nil].filter({ $0 }).count == 1,
              kind == method.resultKind else { throw WorkbenchIPCError(.invalidRequest) }
        if method == .screenSet {
            guard let screenSet, screenSet.authority == "fresh-pinned-owned-screen-set-v1",
                  let profileHash = try? WorkbenchDeploymentHash.profile(screenSet.profile),
                  let setHash = try? WorkbenchDeploymentHash.installedSet(screenSet.screens,
                      selected: screenSet.selectedDashboardId),
                  screenSet.deviceProfileHash == profileHash,
                  screenSet.installedSetHash == setHash,
                  screenSet.profile.deviceId == screenSet.deviceId,
                  screenSet.screens.count <= 12,
                  Set(screenSet.screens.map(\.dashboardId)).count == screenSet.screens.count,
                  (screenSet.screens.isEmpty && screenSet.selectedDashboardId == nil) ||
                    screenSet.screens.contains(where: { $0.dashboardId == screenSet.selectedDashboardId }) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
    }
}

public enum WorkbenchDeviceControlMethod: String, CaseIterable, Sendable {
    case discover = "device.discover"
    case add = "device.add"
    case pairBegin = "device.pairBegin"
    case pairPending = "device.pairPending"
    case pairConfirm = "device.pairConfirm"
    case pairCancel = "device.pairCancel"
    case forget = "device.forget"
    case status = "device.status"
    case settingsGet = "device.settingsGet"
    case settingsSet = "device.settingsSet"
    case connections = "device.connections"
    case screenSet = "device.screenSet"
    case cloudRelayArchive = "device.cloudRelayArchive"
    case cloudRelay = "device.cloudRelay"
    public static var advertisedCases: [Self] { allCases.filter { $0 != .cloudRelay && $0 != .cloudRelayArchive } }
    var resultKind: String {
        switch self {
        case .discover: return "discovered"
        case .add: return "endpoint"
        case .pairBegin: return "pairing"
        case .pairPending: return "pending"
        case .pairConfirm, .status, .cloudRelay, .cloudRelayArchive: return "device"
        case .pairCancel, .forget: return "removed"
        case .settingsGet, .settingsSet: return "settings"
        case .connections: return "connections"
        case .screenSet: return "screenSet"
        }
    }
}

enum WorkbenchDeviceControlRequest {
    case discover, add(String, Int), pairBegin(String?, String?, Int?), pairPending
    case pairConfirm(String, String), pairCancel(String), forget(String), status(String, Bool)
    case settingsGet(String), settingsSet(String, String, DeviceSettings), connections(String), screenSet(String)
    case cloudRelay(deviceId: String, installationId: String, operationId: String)
    case cloudRelayArchive(deviceId: String, installationId: String, operationId: String, packageId: String, archiveSha256: String, stagedPath: String)

    var method: WorkbenchDeviceControlMethod {
        switch self {
        case .discover: return .discover
        case .add: return .add
        case .pairBegin: return .pairBegin
        case .pairPending: return .pairPending
        case .pairConfirm: return .pairConfirm
        case .pairCancel: return .pairCancel
        case .forget: return .forget
        case .status: return .status
        case .settingsGet: return .settingsGet
        case .settingsSet: return .settingsSet
        case .connections: return .connections
        case .screenSet: return .screenSet
        case .cloudRelay: return .cloudRelay
        case .cloudRelayArchive: return .cloudRelayArchive
        }
    }

    static func parse(method: WorkbenchDeviceControlMethod, params: [String: Any]) throws -> Self {
        guard let n = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == 1 else { throw WorkbenchIPCError(.unsupportedVersion) }
        let keys = Set(params.keys)
        func exact(_ names: String...) throws {
            guard keys == Set(names).union(["schemaVersion"]) else { throw WorkbenchIPCError(.invalidRequest) }
        }
        func id(_ name: String) throws -> String {
            guard let value = params[name] as? String, WorkspaceValidation.id(value) else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        }
        func port() throws -> Int {
            guard let value = params["port"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue == Double(value.intValue), (1...65535).contains(value.intValue) else { throw WorkbenchIPCError(.invalidRequest) }
            return value.intValue
        }
        switch method {
        case .discover: try exact(); return .discover
        case .add:
            try exact("host", "port")
            guard let host = params["host"] as? String else { throw WorkbenchIPCError(.invalidRequest) }
            return .add(host, try port())
        case .pairBegin:
            if keys == ["schemaVersion", "deviceId"] { return .pairBegin(try id("deviceId"), nil, nil) }
            try exact("host", "port")
            guard let host = params["host"] as? String else { throw WorkbenchIPCError(.invalidRequest) }
            return .pairBegin(nil, host, try port())
        case .pairPending: try exact(); return .pairPending
        case .pairConfirm:
            try exact("pendingId", "matchingCode")
            guard let code = params["matchingCode"] as? String, code.utf8.count <= 32 else { throw WorkbenchIPCError(.invalidRequest) }
            return .pairConfirm(try id("pendingId"), code)
        case .pairCancel: try exact("pendingId"); return .pairCancel(try id("pendingId"))
        case .forget: try exact("deviceId"); return .forget(try id("deviceId"))
        case .status:
            try exact("deviceId", "refresh")
            guard let refresh = params["refresh"] as? NSNumber,
                  CFGetTypeID(refresh) == CFBooleanGetTypeID() else { throw WorkbenchIPCError(.invalidRequest) }
            return .status(try id("deviceId"), refresh.boolValue)
        case .settingsGet: try exact("deviceId"); return .settingsGet(try id("deviceId"))
        case .settingsSet:
            try exact("deviceId", "expectedRevision", "value")
            guard let revision = params["expectedRevision"] as? String, WorkspaceValidation.id(revision),
                  let value = params["value"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let settings = try? JSONDecoder().decode(DeviceSettings.self, from: data) else { throw WorkbenchIPCError(.invalidRequest) }
            return .settingsSet(try id("deviceId"), revision, settings)
        case .connections: try exact("deviceId"); return .connections(try id("deviceId"))
        case .screenSet: try exact("deviceId"); return .screenSet(try id("deviceId"))
        case .cloudRelayArchive:
            try exact("deviceId", "installationId", "operationId", "packageId", "archiveSha256", "stagedPath")
            let installation = try id("installationId"), operation = try id("operationId"), package = try id("packageId")
            guard UUID(uuidString: installation) != nil, UUID(uuidString: operation) != nil, UUID(uuidString: package) != nil,
                  let hash = params["archiveSha256"] as? String, WorkspaceValidation.sha256(hash),
                  let path = params["stagedPath"] as? String, WorkspaceValidation.absolute(path) else { throw WorkbenchIPCError(.invalidRequest) }
            return .cloudRelayArchive(deviceId: try id("deviceId"), installationId: installation, operationId: operation, packageId: package, archiveSha256: hash, stagedPath: path)
        case .cloudRelay:
            try exact("deviceId", "installationId", "operationId")
            let installation = try id("installationId"), operation = try id("operationId")
            guard UUID(uuidString: installation) != nil, UUID(uuidString: operation) != nil else { throw WorkbenchIPCError(.invalidRequest) }
            return .cloudRelay(deviceId: try id("deviceId"), installationId: installation, operationId: operation)
        }
    }
}
