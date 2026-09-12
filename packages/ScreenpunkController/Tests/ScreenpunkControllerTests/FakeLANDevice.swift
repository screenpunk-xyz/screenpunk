import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

/// In-memory stand-in for `DeviceLANServer`: same envelope handling, same
/// pairing/deploy state machine, same "device owner must confirm natively"
/// rule, without sockets or TLS. `acceptTLS` mirrors the pinned verify block.
final class FakeLANDevice: @unchecked Sendable {
    var runtime: DeviceRuntime
    let identityPin: [UInt8]
    let host = "192.168.4.20"
    let port: UInt16 = 7843
    var online = true
    var lieAboutCode = false
    private(set) var pairingCode: String?
    private(set) var deviceConfirmed = false
    private(set) var pinnedController: [UInt8]?
    private(set) var receivedFiles: [String: Data] = [:]
    private(set) var deployAttempts = 0
    private let clock = FixedClock(Date())
    private let lock = NSLock()

    init(deviceId: String, name: String) {
        let identity = PairingIdentityFactory.make(role: .device)
        identityPin = identity.publicKey
        runtime = DeviceRuntime(
            identity: identity,
            profile: DeviceProfile(deviceId: deviceId, name: name),
            advertisement: AdvertisedDevice(deviceId: deviceId, host: host, port: Int(port), source: .advertised)
        )
    }

    var isPaired: Bool { runtime.isPaired }
    var ownerPin: [UInt8]? { runtime.pairing.owner?.publicKey }

    func confirmLocally() {
        lock.lock()
        deviceConfirmed = true
        lock.unlock()
    }

    func unlink() {
        lock.lock()
        runtime.unlink()
        pairingCode = nil
        deviceConfirmed = false
        pinnedController = nil
        receivedFiles = [:]
        lock.unlock()
    }

    /// Once an owner exists only that controller pin completes the handshake.
    func acceptTLS(controllerPin: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let owner = pinnedController ?? runtime.pairing.owner?.publicKey
        return owner == nil || owner == controllerPin
    }

    func handle(_ request: LANEnvelope) -> LANEnvelope {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard request.protocolVersion == LANProtocolLimits.version else {
                throw TransferFailure.validationFailed
            }
            switch LANMethod(rawValue: request.method) {
            case .hello:
                return ok(request, payload: LANHello(role: .device, deviceId: runtime.profile.deviceId, pinHex: PeerPin.hex(identityPin)))
            case .pairBegin:
                let body = try LANCodec.decodePayload(LANPairBegin.self, json: request.payloadJSON)
                guard let controllerPin = PeerPin.bytes(body.controllerPinHex),
                      let nonce = PeerPin.parseHex(body.sessionNonceHex),
                      nonce.count == PairingLimits.sessionNonceByteCount
                else {
                    throw TransferFailure.validationFailed
                }
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                let transcript = PairingTranscript(devicePublicKey: identityPin, controllerPublicKey: controllerPin, sessionNonce: nonce)
                let code = expectedCode(for: transcript)
                try runtime.beginPairing(transcript: transcript, expectedCode: code, candidateOwner: controller, clock: clock)
                pairingCode = code
                deviceConfirmed = false
                let shown = lieAboutCode ? String(format: "%06d", (Int(code)! + 1) % 1_000_000) : code
                return ok(request, payload: LANPairBeginResult(code: shown, devicePinHex: PeerPin.hex(identityPin)))
            case .pairConfirm:
                guard deviceConfirmed else { throw TransferFailure.interrupted }
                let body = try LANCodec.decodePayload(LANPairConfirm.self, json: request.payloadJSON)
                guard let controllerPin = PeerPin.bytes(body.controllerPinHex) else {
                    throw TransferFailure.validationFailed
                }
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                try runtime.confirmPairing(code: body.code, presentedOwner: controller, clock: clock)
                pinnedController = runtime.pairing.owner?.publicKey
                pairingCode = nil
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision))
            case .deploy:
                deployAttempts += 1
                let body = try LANCodec.decodePayload(LANDeployBody.self, json: request.payloadJSON)
                var staged: [String: Data] = [:]
                for file in body.files {
                    guard let data = Data(base64Encoded: file.dataBase64) else { throw TransferFailure.validationFailed }
                    if DeploymentDigest.sha256Hex(data) != file.sha256.lowercased() { throw TransferFailure.validationFailed }
                    staged[try PackagePath.normalize(file.path)] = data
                }
                let outcome = try runtime.receiveDeployment(body.deployment, revision: body.revision)
                if outcome.phase == .active {
                    receivedFiles = staged
                }
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
                error: (error as? PairingFailure)?.rawValue ?? (error as? TransferFailure)?.rawValue ?? "failed"
            )
        }
    }

    private func expectedCode(for transcript: PairingTranscript) -> String {
        #if canImport(CryptoKit)
        return PairingSAS.matchingCode(for: transcript)
        #else
        return "000000"
        #endif
    }

    private func ok<T: Encodable>(_ request: LANEnvelope, payload: T) -> LANEnvelope {
        LANEnvelope(requestId: request.requestId, method: request.method, ok: true, payloadJSON: try? LANCodec.encodePayload(payload))
    }
}

/// Mirrors `ControllerLANClient` request/reply handling over the fake device.
final class FakeLANLink: DeviceLink {
    let device: FakeLANDevice
    let controllerPin: [UInt8]
    private(set) var devicePin: [UInt8]?
    private var connected = false

    init(device: FakeLANDevice, controllerPin: [UInt8]) {
        self.device = device
        self.controllerPin = controllerPin
    }

    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        guard device.online, host == device.host, port == device.port else { throw TransferFailure.deviceOffline }
        // Either side failing pin verification aborts the TLS handshake.
        guard device.acceptTLS(controllerPin: controllerPin) else { throw TransferFailure.notPaired }
        if let pinnedDevice, pinnedDevice != device.identityPin { throw TransferFailure.notPaired }
        if let pinnedDevice { devicePin = pinnedDevice }
        connected = true
    }

    func hello() throws -> LANHello {
        let reply = try request(.hello, LANHello(role: .controller, deviceId: "controller", pinHex: PeerPin.hex(controllerPin)))
        let hello = try LANCodec.decodePayload(LANHello.self, json: reply.payloadJSON)
        if let pinned = devicePin {
            try PinnedPeer.rejectIfChanged(
                pinned: PairingIdentity(role: .device, publicKey: pinned),
                presented: PairingIdentity(role: .device, publicKey: PeerPin.bytes(hello.pinHex) ?? [])
            )
        }
        devicePin = PeerPin.bytes(hello.pinHex)
        return hello
    }

    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult {
        let reply = try request(.pairBegin, LANPairBegin(controllerPinHex: PeerPin.hex(controllerPin), sessionNonceHex: PeerPin.hex(nonce)))
        return try LANCodec.decodePayload(LANPairBeginResult.self, json: reply.payloadJSON)
    }

    func confirmPairing(code: String) throws {
        _ = try request(.pairConfirm, LANPairConfirm(code: code, controllerPinHex: PeerPin.hex(controllerPin)))
    }

    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord {
        let reply = try request(.deploy, body)
        return try LANCodec.decodePayload(DeploymentRecord.self, json: reply.payloadJSON)
    }

    func queryActive() throws -> String? {
        let reply = try request(.queryActive, LANActiveQuery())
        return try LANCodec.decodePayload(LANActiveQuery.self, json: reply.payloadJSON).revision
    }

    func cancel() {
        connected = false
    }

    private func request<T: Encodable>(_ method: LANMethod, _ payload: T) throws -> LANEnvelope {
        guard connected, device.online else { throw TransferFailure.deviceOffline }
        let envelope = LANEnvelope(requestId: UUID().uuidString, method: method.rawValue, payloadJSON: try LANCodec.encodePayload(payload))
        let framed = try LANCodec.frame(try LANCodec.encode(envelope))
        let length = try LANCodec.messageLength(fromHeader: Data(framed.prefix(4)))
        let reply = device.handle(try LANCodec.decode(Data(framed.suffix(length))))
        guard reply.requestId == envelope.requestId else { throw TransferFailure.validationFailed }
        if reply.ok != true {
            if let failure = PairingFailure(rawValue: reply.error ?? "") { throw failure }
            if let failure = TransferFailure(rawValue: reply.error ?? "") { throw failure }
            throw TransferFailure.interrupted
        }
        return reply
    }
}

struct FakeLANLinkFactory: DeviceLinkFactory {
    let device: FakeLANDevice
    let controllerIdentity: PairingIdentity

    func makeLink() throws -> DeviceLink {
        FakeLANLink(device: device, controllerPin: controllerIdentity.publicKey)
    }
}
