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
public final class ControllerLANClient: @unchecked Sendable {
    public let identity: TLSIdentityMaterial
    public private(set) var devicePin: [UInt8]?
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
        try waitReady(connection)
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
        if let pinned = devicePin {
            let presented = PairingIdentity(role: .device, publicKey: PeerPin.bytes(hello.pinHex) ?? [])
            try PinnedPeer.rejectIfChanged(
                pinned: PairingIdentity(role: .device, publicKey: pinned),
                presented: presented
            )
        }
        devicePin = PeerPin.bytes(hello.pinHex)
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
        let reply = try request(method: .deploy, payload: body, timeout: 30)
        return try LANCodec.decodePayload(DeploymentRecord.self, json: reply.payloadJSON)
    }

    public func queryActive() throws -> String? {
        let reply = try request(method: .queryActive, payload: LANActiveQuery())
        return try LANCodec.decodePayload(LANActiveQuery.self, json: reply.payloadJSON).revision
    }

    public func cancel() {
        connection?.cancel()
        connection = nil
        link = nil
    }

    private func waitReady(_ connection: NWConnection) throws {
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
        if ready.wait(timeout: .now() + 8) == .timedOut {
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
        try link.send(envelope, timeout: timeout)
        let reply = try link.receive(timeout: timeout)
        if reply.requestId != envelope.requestId {
            throw TransferFailure.validationFailed
        }
        if reply.ok != true {
            if reply.error == PairingFailure.secondOwner.rawValue { throw PairingFailure.secondOwner }
            if reply.error == PairingFailure.identityChanged.rawValue { throw PairingFailure.identityChanged }
            if reply.error == PairingFailure.codeMismatch.rawValue { throw PairingFailure.codeMismatch }
            if reply.error == TransferFailure.validationFailed.rawValue { throw TransferFailure.validationFailed }
            if reply.error == TransferFailure.notPaired.rawValue { throw TransferFailure.notPaired }
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
