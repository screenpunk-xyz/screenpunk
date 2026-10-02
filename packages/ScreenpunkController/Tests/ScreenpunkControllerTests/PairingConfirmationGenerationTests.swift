import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class PairingConfirmationGenerationTests: XCTestCase {
    private let identity = PairingIdentity(role: .controller, publicKey: Array(repeating: 1, count: 32))

    func testOldGenerationMismatchPreservesReplacementPairing() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = DelayedConfirmationLink(device: device, identity: identity, mismatch: true)
        coordinator.attach(SinglePairingLinkFactory(identity: identity, link: old))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()

        let outcome = startConfirmation(coordinator)
        defer { old.release.signal() }
        XCTAssertEqual(old.entered.wait(timeout: .now() + 5), .success)
        coordinator.attach(nil)
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: identity))
        let next = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        old.release.signal()
        XCTAssertEqual(outcome.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue((outcome.result.error as? ControllerError)?.detail.hasPrefix("code_mismatch:") == true)
        XCTAssertEqual(coordinator.pendingPairings().map(\.deviceId), [next.deviceId])
        device.confirmLocally()
        XCTAssertNoThrow(try coordinator.confirmPairing(deviceId: next.deviceId))
    }

    func testOldSuccessfulResponsePreservesReplacementPairing() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = DelayedConfirmationLink(device: device, identity: identity, mismatch: false)
        coordinator.attach(SinglePairingLinkFactory(identity: identity, link: old))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()

        let outcome = startConfirmation(coordinator)
        defer { old.release.signal() }
        XCTAssertEqual(old.entered.wait(timeout: .now() + 5), .success)
        coordinator.attach(nil)
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: identity))
        let next = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        old.release.signal()
        XCTAssertEqual(outcome.done.wait(timeout: .now() + 5), .success)
        XCTAssertNil(outcome.result.record)
        XCTAssertEqual(coordinator.pendingPairings().map(\.deviceId), [next.deviceId])
        XCTAssertTrue(coordinator.directory.list().isEmpty)
    }

    func testSameGenerationMismatchPreservesNewSession() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = DelayedConfirmationLink(device: device, identity: identity, mismatch: true)
        let nextLink = FakeLANLink(device: device, controllerPin: identity.publicKey)
        coordinator.attach(SequencePairingLinkFactory(identity: identity, links: [old, nextLink]))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()

        let outcome = startConfirmation(coordinator)
        defer { old.release.signal() }
        XCTAssertEqual(old.entered.wait(timeout: .now() + 5), .success)
        let next = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        old.release.signal()
        XCTAssertEqual(outcome.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue((outcome.result.error as? ControllerError)?.detail.hasPrefix("code_mismatch:") == true)
        XCTAssertEqual(coordinator.pendingPairings().map(\.deviceId), [next.deviceId])
        device.confirmLocally()
        XCTAssertNoThrow(try coordinator.confirmPairing(deviceId: next.deviceId))
    }

    func testSameLinkReusedForNewSessionSurvivesOldMismatch() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = DelayedConfirmationLink(device: device, identity: identity, mismatch: true)
        coordinator.attach(SinglePairingLinkFactory(identity: identity, link: link))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()

        let outcome = startConfirmation(coordinator)
        defer { link.release.signal() }
        XCTAssertEqual(link.entered.wait(timeout: .now() + 5), .success)
        let next = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        link.release.signal()
        XCTAssertEqual(outcome.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue((outcome.result.error as? ControllerError)?.detail.hasPrefix("code_mismatch:") == true)
        XCTAssertEqual(coordinator.pendingPairings().map(\.deviceId), [next.deviceId])
    }

    func testExpiredOldSessionPreservesReplacementPairing() throws {
        let clock = BlockingExpiryClock()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-expiry-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DeviceCoordinator(directory: DeviceDirectory(url: root.appendingPathComponent("devices.json")), now: { clock.read() })
        let device = FakeLANDevice(deviceId: "fixture", name: "Fixture")
        coordinator.attach(FakeLANLinkFactory(device: device, controllerIdentity: identity))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))

        clock.blockNextReadAtExpiredTime()
        let outcome = startConfirmation(coordinator)
        defer { clock.release.signal() }
        XCTAssertEqual(clock.entered.wait(timeout: .now() + 5), .success)
        let next = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        clock.release.signal()
        XCTAssertEqual(outcome.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue((outcome.result.error as? ControllerError)?.detail.hasPrefix("expired:") == true)
        XCTAssertEqual(coordinator.pendingPairings().map(\.deviceId), [next.deviceId])
    }

    func testCurrentSessionMismatchClearsPendingPairing() throws {
        let (coordinator, device, root) = makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = DelayedConfirmationLink(device: device, identity: identity, mismatch: true)
        coordinator.attach(SinglePairingLinkFactory(identity: identity, link: link))
        _ = try coordinator.requestPairing(deviceId: nil, host: device.host, port: Int(device.port))
        device.confirmLocally()
        link.release.signal()
        XCTAssertThrowsError(try coordinator.confirmPairing(deviceId: "fixture")) { error in
            XCTAssertTrue((error as? ControllerError)?.detail.hasPrefix("code_mismatch:") == true)
        }
        XCTAssertTrue(coordinator.pendingPairings().isEmpty)
        XCTAssertTrue(link.cancelled)
        XCTAssertTrue(coordinator.directory.list().isEmpty)
    }

    private func makeCoordinator() -> (DeviceCoordinator, FakeLANDevice, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-confirm-generation-\(UUID().uuidString)")
        return (DeviceCoordinator(directory: DeviceDirectory(url: root.appendingPathComponent("devices.json"))),
                FakeLANDevice(deviceId: "fixture", name: "Fixture"), root)
    }

    private func startConfirmation(_ coordinator: DeviceCoordinator) -> ConfirmationOutcome {
        let outcome = ConfirmationOutcome()
        DispatchQueue.global().async {
            do { outcome.finish(.success(try coordinator.confirmPairing(deviceId: "fixture"))) }
            catch { outcome.finish(.failure(error)) }
        }
        return outcome
    }
}

private final class ConfirmationOutcome: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: Result<PairedDeviceRecord, Error>?
    func finish(_ result: Result<PairedDeviceRecord, Error>) {
        lock.lock(); stored = result; lock.unlock(); done.signal()
    }
    var result: (record: PairedDeviceRecord?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        switch stored {
        case .success(let record): return (record, nil)
        case .failure(let error): return (nil, error)
        case nil: return (nil, nil)
        }
    }
}

private struct SinglePairingLinkFactory: DeviceLinkFactory, @unchecked Sendable {
    let identity: PairingIdentity
    let link: DeviceLink
    var controllerIdentity: PairingIdentity { identity }
    func makeLink() throws -> DeviceLink { link }
}

private final class BlockingExpiryClock: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let starting = Date()
    private var blockNext = false

    func blockNextReadAtExpiredTime() {
        lock.lock(); blockNext = true; lock.unlock()
    }
    func read() -> Date {
        lock.lock()
        let shouldBlock = blockNext
        blockNext = false
        lock.unlock()
        if shouldBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return starting.addingTimeInterval(PairingLimits.expirySeconds + 1)
        }
        return starting
    }
}

private final class SequencePairingLinkFactory: DeviceLinkFactory, @unchecked Sendable {
    let controllerIdentity: PairingIdentity
    private let lock = NSLock()
    private var links: [DeviceLink]
    init(identity: PairingIdentity, links: [DeviceLink]) { controllerIdentity = identity; self.links = links }
    func makeLink() throws -> DeviceLink {
        lock.lock(); defer { lock.unlock() }
        return links.removeFirst()
    }
}

private final class DelayedConfirmationLink: DeviceLink, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let wrapped: FakeLANLink
    private let mismatch: Bool
    private let lock = NSLock()
    private var wasCancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return wasCancelled }
    var devicePin: [UInt8]? { wrapped.devicePin }

    init(device: FakeLANDevice, identity: PairingIdentity, mismatch: Bool) {
        wrapped = FakeLANLink(device: device, controllerPin: identity.publicKey)
        self.mismatch = mismatch
    }
    func connect(host: String, port: UInt16, pinnedDevice: [UInt8]?) throws {
        try wrapped.connect(host: host, port: port, pinnedDevice: pinnedDevice)
    }
    func hello() throws -> LANHello { try wrapped.hello() }
    func beginPairing(nonce: [UInt8]) throws -> LANPairBeginResult { try wrapped.beginPairing(nonce: nonce) }
    func confirmPairing(code: String) throws {
        let response: Result<Void, Error> = Result { try wrapped.confirmPairing(code: mismatch ? code + "x" : code) }
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        try response.get()
    }
    func deploy(_ body: LANDeployBody) throws -> DeploymentRecord { try wrapped.deploy(body) }
    func queryActive() throws -> String? { try wrapped.queryActive() }
    func cancel() {
        lock.lock(); wasCancelled = true; lock.unlock()
        wrapped.cancel()
    }
}
