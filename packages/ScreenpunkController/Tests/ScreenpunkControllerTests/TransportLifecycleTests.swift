import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class TransportLifecycleTests: XCTestCase {
    private let first = PairingIdentity(role: .controller, publicKey: Array(repeating: 1, count: 32))
    private let second = PairingIdentity(role: .controller, publicKey: Array(repeating: 2, count: 32))

    func testStopInvalidatesPendingPairingEvenWhenIdentityIsReused() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = FakeLANLinkFactory(device: device, controllerIdentity: first)
        coordinator.attach(factory)
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        XCTAssertEqual(coordinator.pendingPairings().count, 1)

        coordinator.attach(nil)
        XCTAssertTrue(coordinator.pendingPairings().isEmpty)
        coordinator.attach(factory)
        XCTAssertThrowsError(try coordinator.confirmPairing(deviceId: "fixture"))
        XCTAssertNil(device.ownerPin)
        XCTAssertTrue(coordinator.directory.list().isEmpty)
    }

    func testChangedIdentityCannotConfirmOldSASOrUseOldCachedChannel() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: first))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        coordinator.attach(nil)
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: second))
        XCTAssertThrowsError(try coordinator.confirmPairing(deviceId: "fixture"))
        XCTAssertNil(device.ownerPin)

        // Establish a durable A-owned registration and a cached authenticated link.
        device.unlink()
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: first))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        let paired = try coordinator.confirmPairing(deviceId: "fixture")
        XCTAssertEqual(paired.device.owner, first)
        let before = device.connectAttempts
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: second))
        XCTAssertEqual(coordinator.directory.get("fixture")?.device.owner, first,
                       "Transport replacement must not erase or relabel a durable registration")
        let probe = try coordinator.device("fixture", probe: true)
        XCTAssertFalse(probe.device.reachable)
        XCTAssertGreaterThan(device.connectAttempts, before,
                             "The new factory must attempt its own channel, never reuse A's cached channel")
        XCTAssertEqual(device.ownerPin, first.publicKey)
    }

    func testFailedReloadAndFactoryReplacementDrainOldSessions() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: first))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: second))
        XCTAssertTrue(coordinator.pendingPairings().isEmpty)
        XCTAssertThrowsError(try coordinator.confirmPairing(deviceId: "fixture"))
        coordinator.attach(nil) // An identity reload that failed before attaching a new factory.
        XCTAssertFalse(coordinator.transportAvailable)
        XCTAssertThrowsError(try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port)))
        XCTAssertTrue(coordinator.directory.list().isEmpty)
    }

    func testInFlightPairingCompletionCannotRestoreOldAuthorityAfterStop() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let slow = BlockingPairingLink(device: device, controllerPin: first.publicKey, entered: entered, release: release)
        coordinator.attach(BlockingPairingFactory(identity: first, link: slow))
        let outcome = PairingOutcome()
        DispatchQueue.global().async {
            do { outcome.finish(.success(try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port)))) }
            catch { outcome.finish(.failure(error)) }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        coordinator.attach(nil)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(slow.cancelled)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(coordinator.pendingPairings().isEmpty)
        XCTAssertTrue(coordinator.directory.list().isEmpty)
    }

    func testInFlightProbeCannotRecacheOldChannelAfterStop() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: first))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        _ = try coordinator.confirmPairing(deviceId: "fixture")

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let slow = BlockingPairingLink(device: device, controllerPin: first.publicKey,
                                       entered: entered, release: release, blockOnQuery: true)
        coordinator.attach(BlockingPairingFactory(identity: first, link: slow))
        let outcome = ProbeOutcome()
        DispatchQueue.global().async {
            outcome.finish(try? coordinator.device("fixture", probe: true))
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        coordinator.attach(nil)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(slow.cancelled)
        XCTAssertFalse(outcome.record?.device.reachable ?? true)
        let before = device.connectAttempts
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: first))
        XCTAssertTrue(try coordinator.device("fixture", probe: true).device.reachable)
        XCTAssertGreaterThan(device.connectAttempts, before)
    }

    private func makeCoordinator() -> (DeviceCoordinator, FakeLANDevice, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-lifecycle-\(UUID().uuidString)")
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: root.appendingPathComponent("devices.json")))
        return (coordinator, FakeLANDevice(deviceId: "fixture", name: "Fixture"), root)
    }
}

private final class PairingOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<PairingRequestResult, Error>?
    func finish(_ value: Result<PairingRequestResult, Error>) { lock.lock(); result = value; lock.unlock() }
    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; if case .success = result { return true }; return false }
}

private final class ProbeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PairedDeviceRecord?
    func finish(_ record: PairedDeviceRecord?) { lock.lock(); value = record; lock.unlock() }
    var record: PairedDeviceRecord? { lock.lock(); defer { lock.unlock() }; return value }
}

private struct BlockingPairingFactory: DeviceLinkFactory {
    let identity: PairingIdentity
    let link: BlockingPairingLink
    var controllerIdentity: PairingIdentity { identity }
    func makeLink() throws -> DeviceLink { link }
}

private final class BlockingPairingLink: DeviceLink, @unchecked Sendable {
    private let wrapped: FakeLANLink
    private let entered: DispatchSemaphore
    private let release: DispatchSemaphore
    private let blockOnQuery: Bool
    private let lock = NSLock()
    private var wasCancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return wasCancelled }
    var devicePin: [UInt8]? { wrapped.devicePin }
    init(device: FakeLANDevice, controllerPin: [UInt8], entered: DispatchSemaphore, release: DispatchSemaphore,
         blockOnQuery: Bool = false) {
        wrapped = FakeLANLink(device: device, controllerPin: controllerPin)
        self.entered = entered; self.release = release
        self.blockOnQuery = blockOnQuery
    }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws { try wrapped.connect(host: host, port: port, pinnedDevice: pinnedDevice) }
    func hello() throws -> LANHello { try wrapped.hello() }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult {
        let value = try wrapped.beginPairing(nonce: nonce)
        if !blockOnQuery { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return value
    }
    func confirmPairing(code: String) throws { try wrapped.confirmPairing(code: code) }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try wrapped.deploy(body) }
    func queryActive() throws -> String? {
        let value = try wrapped.queryActive()
        if blockOnQuery { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return value
    }
    func cancel() { lock.lock(); wasCancelled = true; lock.unlock(); wrapped.cancel() }
}
