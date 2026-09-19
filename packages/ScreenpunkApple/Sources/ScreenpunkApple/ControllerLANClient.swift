import Foundation
import ScreenpunkCore
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

#if canImport(Network) && canImport(Security)
/// Controller-side TLS 1.3 client. Deploy and pairing use the pinned channel.
/// `devicePin` is the pin observed in the TLS handshake; `hello` must agree with it.
public final class ControllerLANClient: @unchecked Sendable {
    public let identity: TLSIdentityMaterial
    public private(set) var devicePin: [UInt8]?
    /// Leaf-certificate pin of the peer on the current connection.
    public private(set) var observedDevicePin: [UInt8]?
    public private(set) var lastHello: LANHello?
    private var link: LANLink?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "xyz.screenpunk.lan.controller")
    private var lastHost: String?
    private var lastPort: UInt16?

    public init(identity: TLSIdentityMaterial) {
        self.identity = identity
    }

    public func connect(host: String, port: UInt16, pinnedDevice: [UInt8]? = nil) throws {
        cancel()
        lastHost = host
        lastPort = port
        if let pinnedDevice {
            devicePin = pinnedDevice
        }
        let parameters = try LANChannel.tlsParameters(
            identity: identity,
            pinnedPeer: { [weak self] in pinnedDevice ?? self?.devicePin },
            queue: queue
        )
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransferFailure.deviceOffline
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        try waitReady(connection, timeout: pinnedDevice == nil ? 60 : 8)
        let observed = LANChannel.observedPeerPin(connection)
        if let expected = pinnedDevice ?? devicePin, observed != expected {
            connection.cancel()
            throw PairingFailure.identityChanged
        }
        observedDevicePin = observed
        self.connection = connection
        self.link = LANLink(connection: connection, queue: queue)
    }

    public func hello() throws -> LANHello {
        let reply = try request(method: .hello, payload: LANHello(
            role: .controller,
            deviceId: "controller",
            pinHex: PeerPin.hex(identity.pin)
        ))
        let hello = try LANCodec.decodePayload(LANHello.self, json: reply.payloadJSON)
        guard let observed = observedDevicePin else {
            throw TransferFailure.validationFailed
        }
        // The identity the device claims must be the one that completed the handshake.
        let presented = PairingIdentity(role: .device, publicKey: PeerPin.bytes(hello.pinHex) ?? [])
        try PinnedPeer.rejectIfChanged(
            pinned: PairingIdentity(role: .device, publicKey: observed),
            presented: presented
        )
        if let pinned = devicePin {
            try PinnedPeer.rejectIfChanged(
                pinned: PairingIdentity(role: .device, publicKey: pinned),
                presented: presented
            )
        }
        devicePin = observed
        lastHello = hello
        return hello
    }

    public func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult {
        let reply = try request(
            method: .pairBegin,
            payload: LANPairBegin(
                controllerPinHex: PeerPin.hex(identity.pin),
                sessionNonceHex: PeerPin.hex(nonce)
            )
        )
        return try LANCodec.decodePayload(LANPairBeginResult.self, json: reply.payloadJSON)
    }

    public func confirmPairing(code: String) throws {
        _ = try request(
            method: .pairConfirm,
            payload: LANPairConfirm(
                code: code,
                controllerPinHex: PeerPin.hex(identity.pin)
            ),
            timeout: 70
        )
    }

    public func deploy(_ body: LANDeployBody) throws -> DeploymentRecord {
        let reply = try request(method: .deploy, payload: body, timeout: LANProtocolLimits.transferTimeoutSeconds)
        return try LANCodec.decodePayload(DeploymentRecord.self, json: reply.payloadJSON)
    }

    public func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        try body.validate()
        guard lastHello?.capabilities?.contains("screen-set-v1") == true else { throw TransferFailure.validationFailed }
        let reply = try request(method: .deploySet, payload: body, timeout: LANProtocolLimits.transferTimeoutSeconds)
        return try LANCodec.decodePayload(LANScreenSetReceipt.self, json: reply.payloadJSON)
    }

    public func getSettings() throws -> DeviceSettingsSnapshot {
        guard lastHello?.capabilities?.contains("device-settings-v1") == true else { throw TransferFailure.validationFailed }
        let reply = try request(method: .settingsGet, payload: [String: String]())
        return try LANCodec.decodePayload(DeviceSettingsSnapshot.self, json: reply.payloadJSON)
    }

    public func updateSettings(_ update: DeviceSettingsUpdate) throws -> DeviceSettingsSnapshot {
        try update.value.validate()
        guard lastHello?.capabilities?.contains("device-settings-v1") == true else { throw TransferFailure.validationFailed }
        let reply = try request(method: .settingsUpdate, payload: update)
        return try LANCodec.decodePayload(DeviceSettingsSnapshot.self, json: reply.payloadJSON)
    }

    public func queryActiveState() throws -> LANActiveQuery {
        let reply = try request(method: .queryActive, payload: LANActiveQuery())
        return try LANCodec.decodePayload(LANActiveQuery.self, json: reply.payloadJSON)
    }

    /// Called after explicit native review/approval, never from dashboard JavaScript.
    public func provisionConnections(_ configuration: ConnectionProvisioning) throws -> ConnectionProvisioningReceipt {
        try configuration.validate()
        guard lastHello?.capabilities?.contains("generic-connections-v1") == true else { throw ConnectionFailure.validationFailed }
        let reply = try request(method: .connectionsProvision, payload: configuration)
        return try LANCodec.decodePayload(ConnectionProvisioningReceipt.self, json: reply.payloadJSON)
    }

    public func revokeConnections() throws {
        _ = try request(method: .connectionsRevoke, payload: [String: String]())
    }

    public func provisionHomeAssistant(_ configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        try configuration.validate()
        guard lastHello?.capabilities?.contains("home-assistant-http-v1") == true else {
            throw ConnectionFailure.validationFailed
        }
        let reply = try request(method: .homeAssistantProvision, payload: configuration)
        return try LANCodec.decodePayload(HomeAssistantProvisioningReceipt.self, json: reply.payloadJSON)
    }

    public func revokeHomeAssistant() throws {
        _ = try request(method: .homeAssistantRevoke, payload: [String: String]())
    }

    public func queryActive() throws -> String? {
        let reply = try request(method: .queryActive, payload: LANActiveQuery())
        return try LANCodec.decodePayload(LANActiveQuery.self, json: reply.payloadJSON).revision
    }

    public func cancel() {
        connection?.cancel()
        connection = nil
        link = nil
        observedDevicePin = nil
    }

    private func waitReady(_ connection: NWConnection, timeout: TimeInterval) throws {
        let ready = DispatchSemaphore(value: 0)
        var failed: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failed = error
                ready.signal()
            case .cancelled:
                failed = TransferFailure.interrupted
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw TransferFailure.interrupted
        }
        if let failed { throw failed }
    }

    private func request<T: Encodable>(
        method: LANMethod,
        payload: T,
        timeout: TimeInterval = 15
    ) throws -> LANEnvelope {
        guard let link else { throw TransferFailure.deviceOffline }
        let envelope = LANEnvelope(
            requestId: UUID().uuidString,
            method: method.rawValue,
            payloadJSON: try LANCodec.encodePayload(payload)
        )
        if method == .deploy || method == .deploySet {
            guard try LANCodec.encode(envelope).count <= LANProtocolLimits.transferLimit(advertised: lastHello?.maxTransferBytes) else {
                throw TransferFailure.validationFailed
            }
        }
        try link.send(envelope, timeout: timeout)
        let reply = try link.receive(timeout: timeout)
        if reply.requestId != envelope.requestId {
            throw TransferFailure.validationFailed
        }
        if reply.ok != true {
            if reply.error == PairingFailure.secondOwner.rawValue { throw PairingFailure.secondOwner }
            if reply.error == PairingFailure.identityChanged.rawValue { throw PairingFailure.identityChanged }
            if reply.error == PairingFailure.codeMismatch.rawValue { throw PairingFailure.codeMismatch }
            if let raw = reply.error, let failure = DeviceSettingsFailure(rawValue: raw) { throw failure }
            if let raw = reply.error, let failure = TransferFailure(rawValue: raw) { throw failure }
            throw TransferFailure.interrupted
        }
        return reply
    }
}

public enum LANPackageFiles {
    public static func offlineFixture() throws -> [LANFileBlob] {
        let store = try PackageAssetStore.bundledOfflineFixture()
        return store.assets.values.map { asset in
            LANFileBlob(
                path: asset.path,
                sha256: PeerPin.hex(PeerPin.sha256(asset.data)),
                dataBase64: asset.data.base64EncodedString()
            )
        }.sorted { $0.path < $1.path }
    }
}
#endif
