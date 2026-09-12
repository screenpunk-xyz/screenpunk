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
///
/// The SAS transcript and the owner check bind to the controller pin observed in
/// each connection's TLS handshake, never to the pin a message claims. Owner,
/// active revision, and package bytes persist through `DeviceStateStore` so a
/// relaunch returns paired and rendering; Unlink erases all of it.
public final class DeviceLANServer: @unchecked Sendable {
    public private(set) var runtime: DeviceRuntime
    public private(set) var port: UInt16 = 0
    public private(set) var pairingCode: String?
    /// Package bytes of `runtime.activeRevision`. Replaced only after a
    /// transfer activates; a failed transfer leaves the current package in place.
    public private(set) var activePackage: PackageAssetStore?
    public var onChange: (() -> Void)?
    public let identity: TLSIdentityMaterial
    public let store: DeviceStateStore?
    private var deviceConfirmed = false
    private var pinnedController: [UInt8]?
    private var activeStoredRevision: StoredRevision?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "xyz.screenpunk.lan.device")
    private let clock: PairingClock
    private let lock = NSLock()

    public init(
        runtime: DeviceRuntime,
        identity: TLSIdentityMaterial,
        clock: PairingClock = FixedClock(Date()),
        store: DeviceStateStore? = nil
    ) {
        self.runtime = runtime
        self.identity = identity
        self.clock = clock
        self.store = store
        self.runtime.identity = identity.pairingIdentity
        restoreFromStore()
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
        pinnedController = runtime.pairing.owner?.publicKey
        persist()
        onChange?()
    }

    /// Erases owner, active revision, package bytes, and everything on disk.
    public func unlink() {
        lock.lock()
        runtime.unlink()
        activePackage = nil
        activeStoredRevision = nil
        pairingCode = nil
        deviceConfirmed = false
        pinnedController = nil
        try? store?.erase()
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

    // MARK: Persistence

    private func restoreFromStore() {
        guard let store, let state = store.load() else { return }
        runtime.restore(state)
        pinnedController = state.owner?.publicKey
        activeStoredRevision = state.activeStoredRevision
        if runtime.activeRevision != nil,
           let files = try? store.loadPackageFiles(), files.isEmpty == false
        {
            var assets: [String: PackageAsset] = [:]
            for file in files {
                guard let path = try? PackageAssetStore.hostRelativePath(file.path) else { continue }
                assets[path] = PackageAsset(path: path, data: file.data, mime: PackageAssetStore.mime(for: path))
            }
            activePackage = PackageAssetStore(assets: assets)
        }
    }

    /// Caller holds `lock`.
    private func persist() {
        guard let store else { return }
        try? store.save(DevicePersistedState(runtime: runtime, activeStoredRevision: activeStoredRevision))
    }

    // MARK: Connections

    private func ownerPin() -> [UInt8]? {
        lock.lock()
        let pin = pinnedController ?? runtime.pairing.owner?.publicKey
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
        startAndWaitReady(connection)
        let peerPin = LANChannel.observedPeerPin(connection)
        let link = LANLink(connection: connection, queue: queue)
        serve(link, peerPin: peerPin)
    }

    /// Installs the state handler before `start` so a fast handshake cannot be missed.
    private func startAndWaitReady(_ connection: NWConnection) {
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state { done.signal() }
            if case .failed = state { done.signal() }
        }
        connection.start(queue: queue)
        _ = done.wait(timeout: .now() + 8)
    }

    private func serve(_ link: LANLink, peerPin: [UInt8]?) {
        while true {
            do {
                let request = try link.receive()
                let reply = handle(request, peerPin: peerPin)
                try link.send(reply)
            } catch {
                break
            }
        }
    }

    private func handle(_ request: LANEnvelope, peerPin: [UInt8]?) -> LANEnvelope {
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
                let controllerPin = try authenticatedPeer(peerPin, claimedHex: body.controllerPinHex)
                guard let nonce = PeerPin.parseHex(body.sessionNonceHex),
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
                let controllerPin = try authenticatedPeer(peerPin, claimedHex: body.controllerPinHex)
                let controller = PairingIdentity(role: .controller, publicKey: controllerPin)
                try runtime.confirmPairing(code: body.code, presentedOwner: controller, clock: clock)
                pinnedController = runtime.pairing.owner?.publicKey
                pairingCode = nil
                persist()
                onChange?()
                return ok(request, payload: LANActiveQuery(revision: runtime.activeRevision))
            case .deploy:
                try requireOwner(peerPin)
                let body = try LANCodec.decodePayload(LANDeployBody.self, json: request.payloadJSON)
                let staged = try stageFiles(body.files)
                let stagedDirectory = try store?.stagePackage(
                    staged.values.sorted { $0.path < $1.path }.map { (path: $0.path, data: $0.data) }
                )
                let before = runtime
                var outcome = try runtime.receiveDeployment(body.deployment, revision: body.revision)
                if outcome.phase == .active {
                    if let store, let stagedDirectory {
                        do {
                            try store.activatePackage(staged: stagedDirectory)
                        } catch {
                            store.discardStaged(stagedDirectory)
                            runtime = before
                            outcome.phase = .failed
                            outcome.error = TransferFailure.interrupted.rawValue
                            runtime.lastDeployment = outcome
                            persist()
                            return ok(request, payload: outcome)
                        }
                    }
                    activePackage = PackageAssetStore(assets: staged)
                    activeStoredRevision = body.revision
                    persist()
                    onChange?()
                } else {
                    if let store, let stagedDirectory {
                        store.discardStaged(stagedDirectory)
                    }
                    // The failed record persists so a same-id retry answers the
                    // same way after a relaunch; the active package is untouched.
                    persist()
                }
                return ok(request, payload: outcome)
            case .queryActive:
                try requireOwner(peerPin)
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
                    ?? (error is DeviceStateStoreError ? TransferFailure.interrupted.rawValue : nil)
                    ?? "failed"
            )
        }
    }

    /// The pin a message claims must be the pin that completed this
    /// connection's handshake. Returns the authenticated pin.
    private func authenticatedPeer(_ peerPin: [UInt8]?, claimedHex: String) throws -> [UInt8] {
        guard let peerPin, peerPin.count == PairingLimits.identityByteCount else {
            throw TransferFailure.validationFailed
        }
        guard PeerPin.matches(expected: peerPin, presentedHex: claimedHex) else {
            throw PairingFailure.identityChanged
        }
        return peerPin
    }

    /// Deploy and active-revision queries are owner-only, checked against the
    /// handshake pin even though TLS already rejects other peers.
    private func requireOwner(_ peerPin: [UInt8]?) throws {
        guard let owner = runtime.pairing.owner?.publicKey, let peerPin, peerPin == owner else {
            throw TransferFailure.notPaired
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

    /// Hash-checks every blob before anything can activate. Nothing here
    /// touches `activePackage`; a rejected transfer keeps the current dashboard.
    private func stageFiles(_ files: [LANFileBlob]) throws -> [String: PackageAsset] {
        var staged: [String: PackageAsset] = [:]
        for file in files {
            guard let data = Data(base64Encoded: file.dataBase64) else {
                throw TransferFailure.validationFailed
            }
            let digest = PeerPin.hex(PeerPin.sha256(data))
            if digest != file.sha256.lowercased() {
                throw TransferFailure.validationFailed
            }
            let normalized = try PackagePath.normalize(file.path)
            guard let path = try? PackageAssetStore.hostRelativePath(normalized) else {
                throw TransferFailure.validationFailed
            }
            if staged[path] != nil {
                throw TransferFailure.validationFailed
            }
            staged[path] = PackageAsset(path: path, data: data, mime: PackageAssetStore.mime(for: path))
        }
        return staged
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
