import Foundation
import ScreenpunkCore
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

#if canImport(Network) && canImport(Security)
/// Device-side TLS 1.3 listener. Pairing and deploy run over the authenticated channel.
public final class DeviceLANServer: @unchecked Sendable {
    public private(set) var runtime: DeviceRuntime
    public private(set) var port: UInt16 = 0
    public private(set) var pairingCode: String?
    public var onChange: (() -> Void)?
    private var deviceConfirmed = false
    public let identity: TLSIdentityMaterial
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "xyz.screenpunk.lan.device")
    private let clock: PairingClock
    private let lock = NSLock()

    public init(runtime: DeviceRuntime, identity: TLSIdentityMaterial, clock: PairingClock = FixedClock(Date())) {
        self.runtime = runtime
        self.identity = identity
        self.clock = clock
        self.runtime.identity = identity.pairingIdentity
    }

    public func start() throws {
        if listener != nil, port != 0 { return }
        let parameters = try LANChannel.tlsParameters(
            identity: identity,
            pinnedPeer: { [weak self] in self?.ownerPin() },
            queue: queue
        )
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.accept(connection)
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        if let startError {
            listener.cancel()
            throw startError
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        self.listener = listener
        self.port = port
        advertiseBonjour(on: listener)
        lock.lock()
        runtime.advertisement = AdvertisedDevice(
            deviceId: runtime.profile.deviceId,
            host: "127.0.0.1",
            port: Int(port),
            source: .advertised
        )
        lock.unlock()
    }

    public func confirmLocally() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let code = pairingCode ?? runtime.pairingCode else {
            throw PairingFailure.expired
        }
        deviceConfirmed = true
        if let owner = runtime.pairing.session?.candidateOwner {
            try runtime.confirmPairing(code: code, presentedOwner: owner, clock: clock)
        }
        onChange?()
    }

    public func unlink() {
        lock.lock()
        runtime.unlink()
        pairingCode = nil
        deviceConfirmed = false
        lock.unlock()
        onChange?()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    public var advertisedDevice: AdvertisedDevice {
        lock.lock()
        let value = runtime.advertisement
        lock.unlock()
        return value
    }

    private func ownerPin() -> [UInt8]? {
        lock.lock()
        let pin = runtime.pairing.owner?.publicKey
        lock.unlock()
        return pin
    }

    private func advertiseBonjour(on listener: NWListener) {
        listener.service = NWListener.Service(
            name: runtime.profile.deviceId,
            type: DiscoveryService.type,
            txtRecord: NWTXTRecord([
                "v": "\(DiscoveryService.protocolMajor)",
                "id": runtime.profile.deviceId
            ])
        )
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        waitReady(connection)
        let link = LANLink(connection: connection, queue: queue)
        serve(link)
    }

    private func waitReady(_ connection: NWConnection) {
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state { done.signal() }
            if case .failed = state { done.signal() }
        }
        _ = done.wait(timeout: .now() + 8)
    }

    private func serve(_ link: LANLink) {
        while true {
            do {
                let request = try link.receive()
                let reply = handle(request)
                try link.send(reply)
            } catch {
                break
            }
        }
    }

    private func handle(_ request: LANEnvelope) -> LANEnvelope {
        if request.method == LANMethod.pairConfirm.rawValue {
            _ = waitUntilDeviceConfirmed(timeout: 60)
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            guard request.protocolVersion == LANProtocolLimits.version else {
                throw TransferFailure.validationFailed
            }
            switch LANMethod(rawValue: request.method) {
            case .hello:
                let hello = LANHello(
                    role: .device,
                    deviceId: runtime.profile.deviceId,
                    pinHex: PeerPin.hex(identity.pin)
                )
                return ok(request, payload: hello)
            case .pairBegin:
                let body = try LANCodec.decodePayload(LANPairBegin.self, json: request.payloadJSON)
                guard let controllerPin = PeerPin.bytes(body.controllerPinHex),
                      let nonce = PeerPin.parseHex(body.sessionNonceHex),
                      nonce.count == PairingLimits.sessionNonceByteCount
                else {
                    throw TransferFailure.validationFailed
                }
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                let transcript = PairingTranscript(
                    devicePublicKey: identity.pin,
                    controllerPublicKey: controllerPin,
                    sessionNonce: nonce
                )
                let code = expectedCode(for: transcript)
                try runtime.beginPairing(
                    transcript: transcript,
                    expectedCode: code,
                    candidateOwner: controller,
                    clock: clock
                )
                pairingCode = code
                deviceConfirmed = false
                onChange?()
                return ok(
                    request,
                    payload: LANPairBeginResult(code: code, devicePinHex: PeerPin.hex(identity.pin))
                )
            case .pairConfirm:
                guard deviceConfirmed else { throw TransferFailure.interrupted }
                let body = try LANCodec.decodePayload(LANPairConfirm.self, json: request.payloadJSON)
                guard let controllerPin = PeerPin.bytes(body.controllerPinHex) else {
                    throw TransferFailure.validationFailed
                }
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                try runtime.confirmPairing(code: body.code, presentedOwner: controller, clock: clock)
                pairingCode = nil
                onChange?()
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision))
            case .deploy:
                let body = try LANCodec.decodePayload(LANDeployBody.self, json: request.payloadJSON)
                try validateFiles(body.files)
                let outcome = try runtime.receiveDeployment(body.deployment, revision: body.revision)
                return ok(request, payload: outcome)
            case .queryActive:
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision))
            case .none:
                throw TransferFailure.validationFailed
            }
        } catch {
            return LANEnvelope(
                requestId: request.requestId,
                method: request.method,
                ok: false,
                error: (error as? PairingFailure)?.rawValue
                    ?? (error as? TransferFailure)?.rawValue
                    ?? "failed"
            )
        }
    }

    private func waitUntilDeviceConfirmed(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = deviceConfirmed
            lock.unlock()
            if done { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        let done = deviceConfirmed
        lock.unlock()
        return done
    }

    private func expectedCode(for transcript: PairingTranscript) -> String {
        #if canImport(CryptoKit)
        return PairingSAS.matchingCode(for: transcript)
        #else
        return "000000"
        #endif
    }

    private func validateFiles(_ files: [LANFileBlob]) throws {
        for file in files {
            guard let data = Data(base64Encoded: file.dataBase64) else {
                throw TransferFailure.validationFailed
            }
            let digest = PeerPin.hex(PeerPin.sha256(data))
            if digest != file.sha256.lowercased() {
                throw TransferFailure.validationFailed
            }
            _ = try PackagePath.normalize(file.path)
        }
    }

    private func ok<T: Encodable>(_ request: LANEnvelope, payload: T) -> LANEnvelope {
        LANEnvelope(
            requestId: request.requestId,
            method: request.method,
            ok: true,
            payloadJSON: try? LANCodec.encodePayload(payload)
        )
    }
}
#endif
