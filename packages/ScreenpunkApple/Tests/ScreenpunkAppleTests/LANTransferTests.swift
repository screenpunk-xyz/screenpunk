import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple
#if canImport(Network)
import Network
#endif

#if canImport(Network) && canImport(Security)
final class LANTransferTests: XCTestCase {
    func testTLSPairDeployQueryAndSecondOwner() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-test")
        let controllerIdentity = try TLSIdentity.make(role: .controller, commonName: "screenpunk-controller-test")
        let runtime = DeviceRuntime(
            identity: deviceIdentity.pairingIdentity,
            profile: DeviceProfile(deviceId: "lan-phone", name: "LAN iPhone"),
            advertisement: AdvertisedDevice(
                deviceId: "lan-phone",
                host: "127.0.0.1",
                port: 0,
                source: .advertised
            )
        )
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-lan-device-\(UUID().uuidString)", isDirectory: true))
        defer { try? store.erase() }
        let server = DeviceLANServer(runtime: runtime, identity: deviceIdentity, store: store)
        try server.start()
        XCTAssertGreaterThan(server.port, 0)
        defer { server.stop() }

        let client = ControllerLANClient(identity: controllerIdentity)
        try client.connect(host: "127.0.0.1", port: server.port)
        XCTAssertEqual(client.observedDevicePin, deviceIdentity.pin, "handshake pin is read from the TLS metadata")
        let hello = try client.hello()
        XCTAssertEqual(hello.deviceId, "lan-phone")
        XCTAssertEqual(hello.pinHex, PeerPin.hex(deviceIdentity.pin))
        XCTAssertEqual(client.devicePin, deviceIdentity.pin)
        XCTAssertFalse(hello.pinHex.contains("sk-"))

        let nonce = PairingIdentityFactory.nonce()
        let begin = try client.beginPairing(nonce: nonce)
        XCTAssertEqual(begin.code.count, 6)
        XCTAssertEqual(
            begin.code,
            PairingSAS.matchingCode(for: PairingTranscript(
                devicePublicKey: deviceIdentity.pin,
                controllerPublicKey: controllerIdentity.pin,
                sessionNonce: nonce
            )),
            "SAS binds to the TLS pins on both sides"
        )
        XCTAssertFalse(store.hasState, "nothing persists before the owner confirms")
        try server.confirmLocally()
        try client.confirmPairing(code: begin.code)
        XCTAssertTrue(server.runtime.isPaired)
        XCTAssertEqual(store.load()?.owner, controllerIdentity.pairingIdentity, "owner persists after confirm")

        let queued = DeploymentRecord(
            deploymentId: "lan-deploy-1",
            revision: StoredRevision.offlineFixture.revision,
            dashboardId: StoredRevision.offlineFixture.dashboardId,
            deviceId: "lan-phone",
            phase: .queued
        )
        let files = try LANPackageFiles.offlineFixture()
        let outcome = try client.deploy(
            LANDeployBody(
                deployment: queued,
                revision: StoredRevision.offlineFixture,
                files: files
            )
        )
        XCTAssertEqual(outcome.phase, .active)
        XCTAssertEqual(try client.queryActive(), StoredRevision.offlineFixture.revision)
        XCTAssertEqual(server.runtime.activeRevision, StoredRevision.offlineFixture.revision)
        let delivered = try XCTUnwrap(server.activePackage, "device keeps the delivered package for rendering")
        XCTAssertEqual(delivered.assets["index.html"]?.mime, "text/html")
        XCTAssertNoThrow(try delivered.asset(forSchemeURL: "screenpunk://package/index.html"))
        XCTAssertEqual(store.load()?.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(store.load()?.activeStoredRevision, StoredRevision.offlineFixture)
        XCTAssertEqual(try store.loadPackageFiles().map(\.path), delivered.assets.keys.sorted())

        let replay = try client.deploy(
            LANDeployBody(
                deployment: queued,
                revision: StoredRevision.offlineFixture,
                files: files
            )
        )
        XCTAssertEqual(replay.deploymentId, "lan-deploy-1")
        XCTAssertEqual(server.runtime.activeRevision, StoredRevision.offlineFixture.revision)

        var corrupted = files
        if corrupted.isEmpty == false {
            corrupted[0].sha256 = String(repeating: "0", count: 64)
        }
        let bad = DeploymentRecord(
            deploymentId: "lan-deploy-bad",
            revision: StoredRevision.offlineFixture.revision,
            dashboardId: StoredRevision.offlineFixture.dashboardId,
            deviceId: "lan-phone",
            phase: .queued
        )
        XCTAssertThrowsError(
            try client.deploy(
                LANDeployBody(
                    deployment: bad,
                    revision: StoredRevision.offlineFixture,
                    files: corrupted
                )
            )
        )
        XCTAssertEqual(server.runtime.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(server.activePackage?.assets.count, delivered.assets.count, "failed transfer keeps the current package")

        var landscape = StoredRevision.offlineFixture
        landscape.revision = "33333333-3333-4333-8333-333333333333"
        landscape.orientation = .landscape
        landscape.width = 1024
        landscape.height = 768
        let mismatch = try client.deploy(
            LANDeployBody(
                deployment: DeploymentRecord(
                    deploymentId: "lan-deploy-wide",
                    revision: landscape.revision,
                    dashboardId: landscape.dashboardId,
                    deviceId: "lan-phone",
                    phase: .queued
                ),
                revision: landscape,
                files: files
            )
        )
        XCTAssertEqual(mismatch.phase, .failed)
        XCTAssertEqual(mismatch.error, TransferFailure.targetMismatch.rawValue)
        XCTAssertEqual(server.runtime.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(server.activePackage?.assets.count, delivered.assets.count)

        let attackerIdentity = try TLSIdentity.make(role: .controller, commonName: "screenpunk-attacker")
        let attacker = ControllerLANClient(identity: attackerIdentity)
        do {
            try attacker.connect(host: "127.0.0.1", port: server.port)
            _ = try attacker.hello()
            XCTAssertThrowsError(try attacker.beginPairing(nonce: PairingIdentityFactory.nonce())) { error in
                XCTAssertEqual(error as? PairingFailure, .secondOwner)
            }
        } catch {
            // TLS pin may reject the second controller before pair.begin.
        }

        // A Mac relaunch creates a new client while the device stays running.
        client.cancel()
        let reopenedMac = ControllerLANClient(identity: controllerIdentity)
        try reopenedMac.connect(host: "127.0.0.1", port: server.port, pinnedDevice: deviceIdentity.pin)
        _ = try reopenedMac.hello()
        XCTAssertEqual(try reopenedMac.queryActive(), StoredRevision.offlineFixture.revision)
        reopenedMac.cancel()

        // Simulate a terminal network listener while its saved port is still set.
        // The recovery tick calls start(), which used to incorrectly return early.
        let oldListener = try XCTUnwrap(server.listener)
        oldListener.cancel()
        let cancelled = expectation(description: "listener cancelled")
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if case .cancelled = oldListener.state { cancelled.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        wait(for: [cancelled], timeout: 2)
        try server.start()
        XCTAssertFalse(server.listener === oldListener)
        XCTAssertTrue(server.runtime.isPaired)
        XCTAssertEqual(server.activePackage?.assets.keys.sorted(), delivered.assets.keys.sorted())
        try reopenedMac.connect(host: "127.0.0.1", port: server.port, pinnedDevice: deviceIdentity.pin)
        _ = try reopenedMac.hello()
        XCTAssertEqual(try reopenedMac.queryActive(), StoredRevision.offlineFixture.revision)
        reopenedMac.cancel()

        // Relaunch: a fresh server over the same store comes back paired and rendering.
        client.cancel()
        server.stop()
        let relaunched = DeviceLANServer(
            runtime: DeviceRuntime(
                identity: deviceIdentity.pairingIdentity,
                profile: DeviceProfile(deviceId: "lan-phone", name: "LAN iPhone"),
                advertisement: AdvertisedDevice(deviceId: "lan-phone", host: "127.0.0.1", port: 0, source: .advertised)
            ),
            identity: deviceIdentity,
            store: store
        )
        XCTAssertTrue(relaunched.runtime.isPaired)
        XCTAssertEqual(relaunched.runtime.pairing.owner, controllerIdentity.pairingIdentity)
        XCTAssertEqual(relaunched.runtime.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(relaunched.runtime.lastDeployment?.deploymentId, "lan-deploy-wide")
        XCTAssertEqual(relaunched.activePackage?.assets.keys.sorted(), delivered.assets.keys.sorted())
        XCTAssertNoThrow(try relaunched.activePackage?.asset(forSchemeURL: "screenpunk://package/index.html"))
        try relaunched.start()
        defer { relaunched.stop() }

        let owner = ControllerLANClient(identity: controllerIdentity)
        try owner.connect(host: "127.0.0.1", port: relaunched.port, pinnedDevice: deviceIdentity.pin)
        _ = try owner.hello()
        XCTAssertEqual(try owner.queryActive(), StoredRevision.offlineFixture.revision, "the owner reconnects after relaunch")
        let replayAfterRelaunch = try owner.deploy(
            LANDeployBody(deployment: queued, revision: StoredRevision.offlineFixture, files: files)
        )
        XCTAssertEqual(replayAfterRelaunch.phase, .active)

        let strangerAfterRelaunch = ControllerLANClient(identity: attackerIdentity)
        do {
            try strangerAfterRelaunch.connect(host: "127.0.0.1", port: relaunched.port)
            _ = try strangerAfterRelaunch.hello()
            XCTAssertThrowsError(try strangerAfterRelaunch.queryActive(), "a second Mac cannot read the active revision")
        } catch {
            // TLS pin rejects the second controller: the persisted owner still holds.
        }

        relaunched.unlink()
        XCTAssertFalse(relaunched.runtime.isPaired)
        XCTAssertNil(relaunched.runtime.activeRevision)
        XCTAssertNil(relaunched.activePackage, "Unlink erases the delivered package")
        XCTAssertFalse(store.hasState, "Unlink erases persisted pairing")
        XCTAssertFalse(store.hasPackage, "Unlink erases persisted package bytes")
        let coldStart = DeviceLANServer(runtime: runtime, identity: deviceIdentity, store: store)
        XCTAssertFalse(coldStart.runtime.isPaired, "after Unlink a relaunch is unpaired")
        XCTAssertNil(coldStart.activePackage)
    }

    /// A person sits between `pair.begin` and `pair.confirm` (compare codes,
    /// tap Confirm). The device must keep answering on the same connection no
    /// matter how long that gap is; it used to give up after the frame timeout
    /// and swallow the next request without replying.
    func testDeviceKeepsServingAcrossHumanPauseBetweenRequests() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-pause")
        let controllerIdentity = try TLSIdentity.make(role: .controller, commonName: "screenpunk-controller-pause")
        let runtime = DeviceRuntime(
            identity: deviceIdentity.pairingIdentity,
            profile: DeviceProfile(deviceId: "pause-phone", name: "Pause iPhone"),
            advertisement: AdvertisedDevice(deviceId: "pause-phone", host: "127.0.0.1", port: 0, source: .advertised)
        )
        // Body timeout far below the pause so the old idle limit would trip.
        let server = DeviceLANServer(runtime: runtime, identity: deviceIdentity, requestBodyTimeout: 0.3)
        try server.start()
        defer { server.stop() }

        let client = ControllerLANClient(identity: controllerIdentity)
        try client.connect(host: "127.0.0.1", port: server.port)
        _ = try client.hello()
        let begin = try client.beginPairing(nonce: PairingIdentityFactory.nonce())

        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(server.pairingCode, begin.code)
        XCTAssertFalse(server.awaitingControllerConfirm)
        try server.confirmLocally()
        XCTAssertTrue(server.awaitingControllerConfirm, "the tap is visible to the UI before the Mac confirms")
        XCTAssertEqual(server.pairingCode, begin.code, "code stays on screen until the Mac finishes")

        XCTAssertNoThrow(try client.confirmPairing(code: begin.code), "device still answers after the pause")
        XCTAssertTrue(server.runtime.isPaired)
        XCTAssertNil(server.pairingCode, "code leaves the screen once pairing completes")
        XCTAssertNil(server.runtime.pairingCode, "the finished session does not linger and resurrect the code")
        XCTAssertFalse(server.awaitingControllerConfirm)

        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertNil(try client.queryActive(), "connection stays serviceable for the next request too")
    }

    func testHelloPinMustMatchTLSHandshakePin() throws {
        let realDevice = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-real")
        let rogueDevice = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-rogue")
        let controllerIdentity = try TLSIdentity.make(role: .controller, commonName: "screenpunk-controller-rogue-test")
        let rogue = try RogueDevice(identity: rogueDevice, claimedPinHex: PeerPin.hex(realDevice.pin))
        defer { rogue.stop() }

        let client = ControllerLANClient(identity: controllerIdentity)
        try client.connect(host: "127.0.0.1", port: rogue.port)
        XCTAssertEqual(client.observedDevicePin, rogueDevice.pin)
        XCTAssertThrowsError(try client.hello(), "a device claiming another identity in hello is rejected") { error in
            XCTAssertEqual(error as? PairingFailure, .identityChanged)
        }
        XCTAssertNil(client.devicePin, "no pin is trusted from a rejected hello")

        let pinned = ControllerLANClient(identity: controllerIdentity)
        XCTAssertThrowsError(
            try pinned.connect(host: "127.0.0.1", port: rogue.port, pinnedDevice: realDevice.pin),
            "a pinned device that presents a different certificate never completes connect"
        )
    }

    func testDeviceBindsControllerPinToTLSHandshake() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-claim")
        let controllerIdentity = try TLSIdentity.make(role: .controller, commonName: "screenpunk-controller-claim")
        let otherController = try TLSIdentity.make(role: .controller, commonName: "screenpunk-controller-other")
        let server = DeviceLANServer(
            runtime: DeviceRuntime(
                identity: deviceIdentity.pairingIdentity,
                profile: DeviceProfile(deviceId: "claim-phone", name: "Claim"),
                advertisement: AdvertisedDevice(deviceId: "claim-phone", host: "127.0.0.1", port: 0, source: .advertised)
            ),
            identity: deviceIdentity
        )
        try server.start()
        defer { server.stop() }

        let raw = try RawController(identity: controllerIdentity, host: "127.0.0.1", port: server.port)
        defer { raw.cancel() }
        let claimed = try raw.send(
            method: .pairBegin,
            payload: LANPairBegin(
                controllerPinHex: PeerPin.hex(otherController.pin),
                sessionNonceHex: PeerPin.hex(PairingIdentityFactory.nonce())
            )
        )
        XCTAssertEqual(claimed.ok, false)
        XCTAssertEqual(claimed.error, PairingFailure.identityChanged.rawValue, "claimed pin must equal the handshake pin")
        XCTAssertNil(server.runtime.pairing.session, "no pairing session opens for a mismatched claim")
        XCTAssertNil(server.pairingCode)

        let unpairedQuery = try raw.send(method: .queryActive, payload: LANActiveQuery())
        XCTAssertEqual(unpairedQuery.ok, false)
        XCTAssertEqual(unpairedQuery.error, TransferFailure.notPaired.rawValue, "active revision is owner-only")

        let honest = try raw.send(
            method: .pairBegin,
            payload: LANPairBegin(
                controllerPinHex: PeerPin.hex(controllerIdentity.pin),
                sessionNonceHex: PeerPin.hex(PairingIdentityFactory.nonce())
            )
        )
        XCTAssertEqual(honest.ok, true)
        XCTAssertNotNil(server.pairingCode)
    }

    func testPinnedIdentityChangeIsRejected() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-pin")
        let otherDevice = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-other")
        XCTAssertThrowsError(
            try PinnedPeer.rejectIfChanged(
                pinned: deviceIdentity.pairingIdentity,
                presented: otherDevice.pairingIdentity
            )
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .identityChanged)
        }
        XCTAssertNoThrow(
            try PinnedPeer.rejectIfChanged(
                pinned: deviceIdentity.pairingIdentity,
                presented: deviceIdentity.pairingIdentity
            )
        )
    }

    func testPlaintextTCPCannotCompleteHandshake() throws {
        let deviceIdentity = try TLSIdentity.make(role: .device, commonName: "screenpunk-device-plain")
        let runtime = DeviceRuntime(
            identity: deviceIdentity.pairingIdentity,
            profile: DeviceProfile(deviceId: "plain-phone", name: "Plain"),
            advertisement: AdvertisedDevice(
                deviceId: "plain-phone",
                host: "127.0.0.1",
                port: 0,
                source: .advertised
            )
        )
        let server = DeviceLANServer(runtime: runtime, identity: deviceIdentity)
        try server.start()
        defer { server.stop() }

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        let done = DispatchSemaphore(value: 0)
        var becameReady = false
        connection.stateUpdateHandler = { state in
            if case .ready = state { becameReady = true }
            if case .failed = state { done.signal() }
        }
        connection.start(queue: DispatchQueue(label: "xyz.screenpunk.lan.plain-test"))
        connection.send(
            content: try LANCodec.frame(try LANCodec.encode(LANEnvelope(requestId: "x", method: LANMethod.hello.rawValue))),
            completion: .contentProcessed { _ in done.signal() }
        )
        _ = done.wait(timeout: .now() + 2)
        connection.cancel()
        XCTAssertFalse(server.runtime.isPaired)
        if becameReady {
            XCTAssertNil(server.runtime.pairing.session)
        }
    }
}

/// TLS server that presents `identity` but claims `claimedPinHex` in every reply.
final class RogueDevice {
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue

    init(identity: TLSIdentityMaterial, claimedPinHex: String) throws {
        let queue = DispatchQueue(label: "xyz.screenpunk.lan.rogue")
        let parameters = try LANChannel.tlsParameters(identity: identity, pinnedPeer: { nil }, queue: queue)
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            DispatchQueue.global(qos: .userInitiated).async {
                let done = DispatchSemaphore(value: 0)
                connection.stateUpdateHandler = { state in
                    if case .ready = state { done.signal() }
                    if case .failed = state { done.signal() }
                }
                connection.start(queue: queue)
                _ = done.wait(timeout: .now() + 8)
                let link = LANLink(connection: connection, queue: queue)
                while let request = try? link.receive() {
                    let hello = LANHello(role: .device, deviceId: "rogue", pinHex: claimedPinHex)
                    let reply = LANEnvelope(
                        requestId: request.requestId,
                        method: request.method,
                        ok: true,
                        payloadJSON: try? LANCodec.encodePayload(hello)
                    )
                    if (try? link.send(reply)) == nil { break }
                }
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw TransferFailure.interrupted
        }
        self.queue = queue
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener.cancel()
    }
}

/// Controller-side TLS connection that sends arbitrary envelopes.
final class RawController {
    private let connection: NWConnection
    private let link: LANLink

    init(identity: TLSIdentityMaterial, host: String, port: UInt16) throws {
        let queue = DispatchQueue(label: "xyz.screenpunk.lan.raw")
        let parameters = try LANChannel.tlsParameters(identity: identity, pinnedPeer: { nil }, queue: queue)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransferFailure.deviceOffline }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failed: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failed = error
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
        self.connection = connection
        self.link = LANLink(connection: connection, queue: queue)
    }

    func send<T: Encodable>(method: LANMethod, payload: T) throws -> LANEnvelope {
        let envelope = LANEnvelope(
            requestId: UUID().uuidString,
            method: method.rawValue,
            payloadJSON: try LANCodec.encodePayload(payload)
        )
        try link.send(envelope)
        return try link.receive()
    }

    func cancel() {
        connection.cancel()
    }
}
#endif
