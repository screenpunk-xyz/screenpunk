import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum LANProtocolLimits: Sendable {
    public static let version = 1
    public static let legacyMessageBytes = 2 * 1024 * 1024
    public static let maxMessageBytes = 32 * 1024 * 1024
    public static let transferTimeoutSeconds: TimeInterval = 60

    public static func transferLimit(advertised: Int?) -> Int {
        guard let advertised, advertised > 0 else { return legacyMessageBytes }
        return min(advertised, maxMessageBytes)
    }
}

public enum LANMethod: String, Sendable, Codable, Equatable {
    case hello
    case settingsGet = "settings.get"
    case settingsUpdate = "settings.update"
    case pairBegin = "pair.begin"
    case pairConfirm = "pair.confirm"
    case pairRevoke = "pair.revoke"
    case screenSelect = "screen.select"
    case screenRemove = "screen.remove"
    case screenInstall = "screen.install"
    case cloudRelay = "cloud.relay"
    case cloudArchiveChunk = "cloud.archiveChunk"
    case deploy
    case deploySet = "deploy.set"
    case queryActive = "query.active"
    case connectionsInventory = "connections.inventory"
    case connectionsUpdateHome = "connections.updateHome"
    case connectionsProvision = "connections.provision"
    case connectionsRevoke = "connections.revoke"
    case homeAssistantProvision = "homeAssistant.provision"
    case homeAssistantRevoke = "homeAssistant.revoke"
}

public struct LANEnvelope: Sendable, Equatable, Codable {
    public var protocolVersion: Int
    public var requestId: String
    public var method: String
    public var ok: Bool?
    public var error: String?
    public var payloadJSON: String?

    public init(
        protocolVersion: Int = LANProtocolLimits.version,
        requestId: String,
        method: String,
        ok: Bool? = nil,
        error: String? = nil,
        payloadJSON: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.method = method
        self.ok = ok
        self.error = error
        self.payloadJSON = payloadJSON
    }
}

public struct LANHello: Sendable, Equatable, Codable {
    public var role: PairingRole
    public var deviceId: String
    public var pinHex: String
    public var protocolMajor: Int
    /// Owner-facing device name. Optional so peers without it still decode.
    public var name: String?
    public var capabilities: [String]?
    public var maxTransferBytes: Int?
    public var profile: DeviceProfile?

    public init(
        role: PairingRole,
        deviceId: String,
        pinHex: String,
        protocolMajor: Int = DiscoveryService.protocolMajor,
        name: String? = nil,
        capabilities: [String]? = nil,
        maxTransferBytes: Int? = nil,
        profile: DeviceProfile? = nil
    ) {
        self.capabilities = capabilities
        self.maxTransferBytes = maxTransferBytes
        self.role = role
        self.deviceId = deviceId
        self.pinHex = pinHex
        self.protocolMajor = protocolMajor
        self.name = DeviceDisplayName.sanitize(name)
        self.profile = profile
    }
}

public struct LANPairBegin: Sendable, Equatable, Codable {
    public var controllerPinHex: String
    public var sessionNonceHex: String

    public init(controllerPinHex: String, sessionNonceHex: String) {
        self.controllerPinHex = controllerPinHex
        self.sessionNonceHex = sessionNonceHex
    }
}

public struct LANPairBeginResult: Sendable, Equatable, Codable {
    public var code: String
    public var devicePinHex: String

    public init(code: String, devicePinHex: String) {
        self.code = code
        self.devicePinHex = devicePinHex
    }
}

public struct LANPairConfirm: Sendable, Equatable, Codable {
    public var code: String
    public var controllerPinHex: String

    public init(code: String, controllerPinHex: String) {
        self.code = code
        self.controllerPinHex = controllerPinHex
    }
}

public struct LANFileBlob: Sendable, Equatable, Codable {
    public var path: String
    public var sha256: String
    public var dataBase64: String

    public init(path: String, sha256: String, dataBase64: String) {
        self.path = path
        self.sha256 = sha256
        self.dataBase64 = dataBase64
    }
}

public struct LANDeployBody: Sendable, Equatable, Codable {
    public var deployment: DeploymentRecord
    public var revision: StoredRevision
    public var files: [LANFileBlob]

    public init(deployment: DeploymentRecord, revision: StoredRevision, files: [LANFileBlob]) {
        self.deployment = deployment
        self.revision = revision
        self.files = files
    }
}

/// Credential-free status of the native listener, available only to the paired owner.
public struct DeviceTemporaryActivationStatus: Sendable, Equatable, Codable {
    public var phase = "not_started"
    public var foreground = false
    public var targetDashboardId: String?
    public var lastReceivedAt: Date?
    public var lastState: String?
    public var lastError: String?
    public var receivedCount = 0
    public var selectionCount = 0
    public init() {}
}

public struct LANCommonScreenEntry: Sendable, Equatable, Codable {
    public var entryId: String
    public var dashboardId: String
    public var revision: String
    public var name: String
    public var origin: String
    public init(entryId: String, dashboardId: String, revision: String, name: String, origin: String) {
        self.entryId = entryId; self.dashboardId = dashboardId; self.revision = revision; self.name = name; self.origin = origin
    }
}
public struct LANActiveQuery: Sendable, Equatable, Codable {
    /// Authenticated approved-controller status only; no Cloud mutation capability.
    public var activeGenerationId: String?
    public var activeEntryId: String?
    public var lastSuccessfulEntryId: String?
    public var mountState: String?
    public var mountFailureCode: String?
    public var commonEntries: [LANCommonScreenEntry]?
    public var configuredEntryId: String?
    public var stateGenerationId: String?
    public var controllerApproved: Bool?
    public var localControllerPinHex: String?
    public var approvedControllerCount: Int?
    public var cloudInstallationId: String?
    public var revision: String?

    public var screens: [LANScreenSetEntry]?
    public var selectedDashboardId: String?
    public var temporaryActivation: DeviceTemporaryActivationStatus?
    public init(revision: String? = nil, screens: [LANScreenSetEntry]? = nil, selectedDashboardId: String? = nil, temporaryActivation: DeviceTemporaryActivationStatus? = nil, cloudInstallationId: String? = nil, controllerApproved: Bool? = nil, localControllerPinHex: String? = nil, approvedControllerCount: Int? = nil, stateGenerationId: String? = nil, commonEntries: [LANCommonScreenEntry]? = nil, configuredEntryId: String? = nil, activeGenerationId: String? = nil, activeEntryId: String? = nil, lastSuccessfulEntryId: String? = nil, mountState: String? = nil, mountFailureCode: String? = nil) {
        self.mountFailureCode = mountFailureCode
        self.activeGenerationId = activeGenerationId; self.activeEntryId = activeEntryId
        self.lastSuccessfulEntryId = lastSuccessfulEntryId; self.mountState = mountState
        self.commonEntries = commonEntries; self.configuredEntryId = configuredEntryId
        self.stateGenerationId = stateGenerationId
        self.controllerApproved = controllerApproved
        self.localControllerPinHex = localControllerPinHex
        self.approvedControllerCount = approvedControllerCount
        self.cloudInstallationId = cloudInstallationId
        self.revision = revision; self.screens = screens; self.selectedDashboardId = selectedDashboardId; self.temporaryActivation = temporaryActivation
    }
}

public struct LANScreenManagementChange: Codable, Equatable, Sendable {
    public var operationId: String
    public var expectedGenerationId: String
    public var dashboardId: String
    public init(operationId: String, expectedGenerationId: String, dashboardId: String) {
        self.operationId = operationId; self.expectedGenerationId = expectedGenerationId; self.dashboardId = dashboardId
    }
}

public enum LANCodec {
    public static func encode(_ envelope: LANEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> LANEnvelope {
        try JSONDecoder().decode(LANEnvelope.self, from: data)
    }

    public static func frame(_ message: Data) throws -> Data {
        if message.count > LANProtocolLimits.maxMessageBytes {
            throw TransferFailure.validationFailed
        }
        var header = [UInt8](repeating: 0, count: 4)
        let count = UInt32(message.count).bigEndian
        withUnsafeBytes(of: count) { header.replaceSubrange(0..<4, with: $0) }
        return Data(header) + message
    }

    public static func messageLength(fromHeader header: Data, maximumBytes: Int = LANProtocolLimits.maxMessageBytes) throws -> Int {
        guard header.count == 4 else { throw TransferFailure.validationFailed }
        let bytes = [UInt8](header)
        let length = Int(
            (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        )
        if length <= 0 || length > min(maximumBytes, LANProtocolLimits.maxMessageBytes) {
            throw TransferFailure.validationFailed
        }
        return length
    }

    public static func encodePayload<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TransferFailure.validationFailed
        }
        return json
    }

    public static func decodePayload<T: Decodable>(_ type: T.Type, json: String?) throws -> T {
        guard let json, let data = json.data(using: .utf8) else {
            throw TransferFailure.validationFailed
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum PeerPin: Sendable {
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func parseHex(_ hex: String) -> [UInt8]? {
        let clean = hex.lowercased()
        guard clean.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    public static func bytes(_ hex: String) -> [UInt8]? {
        guard let parsed = parseHex(hex), parsed.count == PairingLimits.identityByteCount else {
            return nil
        }
        return parsed
    }

    public static func sha256(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: data))
        #else
        return Array(data.prefix(PairingLimits.identityByteCount))
        #endif
    }

    public static func matches(expected: [UInt8], presentedHex: String) -> Bool {
        guard let presented = bytes(presentedHex) else { return false }
        return expected == presented
    }
}

public enum PinnedPeer: Sendable {
    public static func rejectIfChanged(pinned: PairingIdentity?, presented: PairingIdentity) throws {
        guard let pinned else { return }
        if pinned != presented {
            throw PairingFailure.identityChanged
        }
    }
}

/// Explicit reviewed inventory mutation; retaining entries is independent from
/// uploading packages and selection. Old full-set deployments never imply removal.
public struct LANUnifiedScreenInstall: Codable, Equatable, Sendable {
    public var operationId: String
    public var expectedGenerationId: String
    public var retainedEntryIds: [String]
    public var selectedEntryId: String?
    public var incoming: [LANUnifiedScreenInstallEntry]
    public init(operationId: String, expectedGenerationId: String, retainedEntryIds: [String], selectedEntryId: String?, incoming: [LANUnifiedScreenInstallEntry]) {
        self.operationId = operationId; self.expectedGenerationId = expectedGenerationId
        self.retainedEntryIds = retainedEntryIds; self.selectedEntryId = selectedEntryId; self.incoming = incoming
    }
}
public struct LANUnifiedScreenInstallEntry: Codable, Equatable, Sendable {
    public var entryId: String
    public var screen: LANScreenSetItem
    public init(entryId: String, screen: LANScreenSetItem) { self.entryId = entryId; self.screen = screen }
}

public struct LANCloudRelay: Codable, Equatable, Sendable {
    public var installationId: String
    public var operationId: String
    public init(installationId: String, operationId: String) { self.installationId = installationId; self.operationId = operationId }
}
public struct LANCloudRelayReceipt: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var installationId: String
    public var operationId: String
    public init(accepted: Bool, installationId: String, operationId: String) { self.accepted = accepted; self.installationId = installationId; self.operationId = operationId }
}

public struct LANCloudArchiveChunk: Codable, Equatable, Sendable {
    public var transferId: String
    public var installationId: String
    public var operationId: String
    public var packageId: String
    public var archiveSha256: String
    public var archiveBytes: Int
    public var offset: Int
    public var dataBase64: String
    public var final: Bool
    public init(transferId:String,installationId:String,operationId:String,packageId:String,archiveSha256:String,archiveBytes:Int,offset:Int,dataBase64:String,final:Bool){
        self.transferId=transferId;self.installationId=installationId;self.operationId=operationId;self.packageId=packageId
        self.archiveSha256=archiveSha256;self.archiveBytes=archiveBytes;self.offset=offset;self.dataBase64=dataBase64;self.final=final
    }
}
public struct LANCloudArchiveChunkReceipt: Codable, Equatable, Sendable {
    public var transferId: String
    public var receivedBytes: Int
    public var complete: Bool
    public init(transferId:String,receivedBytes:Int,complete:Bool){self.transferId=transferId;self.receivedBytes=receivedBytes;self.complete=complete}
}
