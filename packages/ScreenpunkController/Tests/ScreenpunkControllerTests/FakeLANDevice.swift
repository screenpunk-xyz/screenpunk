import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

/// In-memory stand-in for `DeviceLANServer`: same envelope handling, same
/// pairing/deploy state machine, same "device owner must confirm natively"
/// rule, without sockets or TLS. `acceptTLS` mirrors the pinned verify block.
final class FakeLANDevice: @unchecked Sendable {
    var runtime: DeviceRuntime
    let identityPin: [UInt8]
    var host = "192.168.4.20"
    var port: UInt16 = 7843
    var online = true
    var supportsHomeAssistant = false
    var supportsScreenSets = true
    var installedSet: [LANScreenSetEntry]?
    var selectedDashboardId: String?
    var failSetAtIndex: Int?
    private var completedSets: [String: (LANScreenSetDeployBody, LANScreenSetReceipt)] = [:]
    var failProvisioning = false
    var installedHomeAssistant: HomeAssistantProvisioning?

    var lieAboutCode = false
    /// Claim this pin in `hello` instead of the handshake identity.
    var claimedHelloPin: [UInt8]?
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

    /// `peerPin` is the controller pin observed in the (simulated) TLS handshake.
    func handle(_ request: LANEnvelope, peerPin: [UInt8]) -> LANEnvelope {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard request.protocolVersion == LANProtocolLimits.version else {
                throw TransferFailure.validationFailed
            }
            switch LANMethod(rawValue: request.method) {
            case .hello:
                let shown = claimedHelloPin ?? identityPin
                return ok(request, payload: LANHello(role: .device, deviceId: runtime.profile.deviceId, pinHex: PeerPin.hex(shown), name: runtime.profile.name, capabilities: (supportsHomeAssistant ? ["home-assistant-http-v1"] : []) + (supportsScreenSets ? ["screen-set-v1"] : []), profile: runtime.profile))
            case .pairBegin:
                let body = try LANCodec.decodePayload(LANPairBegin.self, json: request.payloadJSON)
                guard PeerPin.matches(expected: peerPin, presentedHex: body.controllerPinHex) else {
                    throw PairingFailure.identityChanged
                }
                guard let nonce = PeerPin.parseHex(body.sessionNonceHex),
                      nonce.count == PairingLimits.sessionNonceByteCount
                else {
                    throw TransferFailure.validationFailed
                }
                let controller = PairingIdentity(role: .controller, publicKey: peerPin)
                let transcript = PairingTranscript(devicePublicKey: identityPin, controllerPublicKey: peerPin, sessionNonce: nonce)
                let code = expectedCode(for: transcript)
                try runtime.beginPairing(transcript: transcript, expectedCode: code, candidateOwner: controller, clock: clock)
                pairingCode = code
                deviceConfirmed = false
                let shown = lieAboutCode ? String(format: "%06d", (Int(code)! + 1) % 1_000_000) : code
                return ok(request, payload: LANPairBeginResult(code: shown, devicePinHex: PeerPin.hex(identityPin)))
            case .pairConfirm:
                guard deviceConfirmed else { throw TransferFailure.interrupted }
                let body = try LANCodec.decodePayload(LANPairConfirm.self, json: request.payloadJSON)
                guard PeerPin.matches(expected: peerPin, presentedHex: body.controllerPinHex) else {
                    throw PairingFailure.identityChanged
                }
                let controller = PairingIdentity(role: .controller, publicKey: peerPin)
                try runtime.confirmPairing(code: body.code, presentedOwner: controller, clock: clock)
                pinnedController = runtime.pairing.owner?.publicKey
                pairingCode = nil
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision))
            case .deploy:
                guard let owner = runtime.pairing.owner?.publicKey, owner == peerPin else {
                    throw TransferFailure.notPaired
                }
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
                guard let owner = runtime.pairing.owner?.publicKey, owner == peerPin else {
                    throw TransferFailure.notPaired
                }
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision))
            case .deploySet, .homeAssistantProvision, .homeAssistantRevoke, .none:
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

    func installSet(_ body: LANScreenSetDeployBody, controllerPin: [UInt8]) throws -> LANScreenSetReceipt {
        guard online, supportsScreenSets, ownerPin == controllerPin else { throw TransferFailure.notPaired }
        try body.validate()
        if let (original, receipt) = completedSets[body.deploymentId] {
            guard original == body else { throw TransferFailure.validationFailed }
            return receipt
        }
        var staged = runtime
        var selectedRuntime = runtime
        var selectedFiles: [String: Data] = [:]
        for (index, item) in body.screens.enumerated() {
            if failSetAtIndex == index { throw TransferFailure.interrupted }
            if item.homeAssistant != nil && (!supportsHomeAssistant || failProvisioning) { throw TransferFailure.validationFailed }
            var files: [String: Data] = [:]
            for file in item.deployment.files {
                guard let data = Data(base64Encoded: file.dataBase64), DeploymentDigest.sha256Hex(data) == file.sha256 else { throw TransferFailure.validationFailed }
                files[try PackagePath.normalize(file.path)] = data
            }
            let outcome = try staged.receiveDeployment(item.deployment.deployment, revision: item.deployment.revision)
            guard outcome.phase == .active else { throw TransferFailure.targetMismatch }
            if item.deployment.revision.dashboardId == body.selectedDashboardId { selectedRuntime = staged; selectedFiles = files }
        }
        runtime = selectedRuntime
        receivedFiles = selectedFiles
        installedHomeAssistant = body.screens.first { $0.deployment.revision.dashboardId == body.selectedDashboardId }?.homeAssistant
        installedSet = body.screens.map { .init(dashboardId: $0.deployment.revision.dashboardId, revision: $0.deployment.revision.revision, name: $0.name) }
        selectedDashboardId = body.selectedDashboardId
        deployAttempts += body.screens.count
        let receipt = LANScreenSetReceipt(deploymentId: body.deploymentId, deviceId: runtime.profile.deviceId,
            screens: installedSet!, selectedDashboardId: body.selectedDashboardId)
        completedSets[body.deploymentId] = (body, receipt)
        return receipt
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
    /// Pin of the certificate the device presented in the simulated handshake.
    private(set) var observedDevicePin: [UInt8]?
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
        observedDevicePin = device.identityPin
        connected = true
    }

    func hello() throws -> LANHello {
        let reply = try request(.hello, LANHello(role: .controller, deviceId: "controller", pinHex: PeerPin.hex(controllerPin)))
        let hello = try LANCodec.decodePayload(LANHello.self, json: reply.payloadJSON)
        guard let observed = observedDevicePin else { throw TransferFailure.validationFailed }
        let presented = PairingIdentity(role: .device, publicKey: PeerPin.bytes(hello.pinHex) ?? [])
        try PinnedPeer.rejectIfChanged(pinned: PairingIdentity(role: .device, publicKey: observed), presented: presented)
        if let pinned = devicePin {
            try PinnedPeer.rejectIfChanged(pinned: PairingIdentity(role: .device, publicKey: pinned), presented: presented)
        }
        devicePin = observed
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

    func deployScreenSet(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt {
        try device.installSet(body, controllerPin: controllerPin)
    }
    func queryActiveState() throws -> LANActiveQuery {
        LANActiveQuery(revision: try queryActive(), screens: device.installedSet, selectedDashboardId: device.selectedDashboardId)
    }

    func provisionHomeAssistant(_ configuration: HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt {
        guard device.supportsHomeAssistant, !device.failProvisioning else { throw TransferFailure.validationFailed }
        guard device.runtime.activeRevision == configuration.revision else { throw TransferFailure.validationFailed }
        device.installedHomeAssistant = configuration
        return HomeAssistantProvisioningReceipt(deviceId: device.runtime.profile.deviceId, dashboardId: configuration.dashboardId,
            revision: configuration.revision, connectionId: configuration.connectionId, provisioningId: configuration.provisioningId)
    }

    func queryActive() throws -> String? {
        let reply = try request(.queryActive, LANActiveQuery())
        return try LANCodec.decodePayload(LANActiveQuery.self, json: reply.payloadJSON).revision
    }

    func cancel() {
        connected = false
        observedDevicePin = nil
    }

    private func request<T: Encodable>(_ method: LANMethod, _ payload: T) throws -> LANEnvelope {
        guard connected, device.online else { throw TransferFailure.deviceOffline }
        let envelope = LANEnvelope(requestId: UUID().uuidString, method: method.rawValue, payloadJSON: try LANCodec.encodePayload(payload))
        let framed = try LANCodec.frame(try LANCodec.encode(envelope))
        let length = try LANCodec.messageLength(fromHeader: Data(framed.prefix(4)))
        let reply = device.handle(try LANCodec.decode(Data(framed.suffix(length))), peerPin: controllerPin)
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
