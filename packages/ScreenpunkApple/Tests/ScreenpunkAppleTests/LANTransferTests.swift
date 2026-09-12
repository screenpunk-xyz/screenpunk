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
        let server = DeviceLANServer(runtime: runtime, identity: deviceIdentity)
        try server.start()
        XCTAssertGreaterThan(server.port, 0)
        defer { server.stop() }

        let client = ControllerLANClient(identity: controllerIdentity)
        try client.connect(host: "127.0.0.1", port: server.port)
        let hello = try client.hello()
        XCTAssertEqual(hello.deviceId, "lan-phone")
        XCTAssertEqual(hello.pinHex, PeerPin.hex(deviceIdentity.pin))
        XCTAssertFalse(hello.pinHex.contains("sk-"))

        let begin = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        XCTAssertEqual(begin.code.count, 6)
        try server.confirmLocally()
        try client.confirmPairing(code: begin.code)
        XCTAssertTrue(server.runtime.isPaired)

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
        landscape.width = 844
        landscape.height = 390
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

        server.unlink()
        XCTAssertFalse(server.runtime.isPaired)
        XCTAssertNil(server.runtime.activeRevision)
        XCTAssertNil(server.activePackage, "Unlink erases the delivered package")
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
#endif
