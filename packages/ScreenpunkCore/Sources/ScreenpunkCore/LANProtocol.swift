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
    case deploy
    case deploySet = "deploy.set"
    case queryActive = "query.active"
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

public struct LANActiveQuery: Sendable, Equatable, Codable {
    public var revision: String?

    public var screens: [LANScreenSetEntry]?
    public var selectedDashboardId: String?
    public init(revision: String? = nil, screens: [LANScreenSetEntry]? = nil, selectedDashboardId: String? = nil) {
        self.revision = revision; self.screens = screens; self.selectedDashboardId = selectedDashboardId
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
