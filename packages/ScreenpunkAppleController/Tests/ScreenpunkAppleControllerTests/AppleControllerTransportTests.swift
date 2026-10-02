import XCTest
import ScreenpunkController
import ScreenpunkCore
@testable import ScreenpunkAppleController

final class AppleControllerTransportTests: XCTestCase {
    func testConstructionAndDomainBootstrapDoNotStartNativeEffects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)
        let effects = TransportEffects()
        let transport = makeTransport(effects)
        XCTAssertEqual(effects.identities, 0)
        XCTAssertEqual(effects.discoveries, 0)
        XCTAssertFalse(service.devices.transportAvailable)
        XCTAssertNil(service.connectionDescription)
        withExtendedLifetime(transport) {}
    }

    func testExplicitAttachmentOwnsSingleNativeInstanceAndStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)
        let effects = TransportEffects()
        let transport = makeTransport(effects)
        let first = try transport.attach(to: service)
        XCTAssertEqual(first.publicKey, Array(repeating: 7, count: 32))
        XCTAssertEqual(try transport.attach(to: service), first)
        XCTAssertEqual(effects.identities, 1)
        XCTAssertEqual(effects.discoveries, 1)
        XCTAssertEqual(effects.browser.starts, 1)
        XCTAssertTrue(service.devices.transportAvailable)
        XCTAssertNotNil(service.connectionDescription)
        XCTAssertThrowsError(try transport.attach(to: try makeService(root.appendingPathComponent("other"))))
        transport.stop()
        XCTAssertEqual(effects.browser.stops, 1)
        XCTAssertFalse(service.devices.transportAvailable)
        XCTAssertNil(service.connectionDescription)
        _ = try transport.attach(to: service)
        XCTAssertEqual(effects.identities, 2)
        XCTAssertEqual(effects.discoveries, 2)
        XCTAssertEqual(effects.browser.starts, 2)
    }

    func testIdentityFailureLeavesDomainWithoutLANOrProviders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)
        let effects = TransportEffects()
        effects.failIdentity = true
        let transport = makeTransport(effects)
        XCTAssertThrowsError(try transport.attach(to: service))
        XCTAssertEqual(effects.identities, 1)
        XCTAssertEqual(effects.discoveries, 0)
        XCTAssertFalse(service.devices.transportAvailable)
        XCTAssertNil(service.homeAssistantConfiguration)
        XCTAssertNil(service.connectionDescription)
        XCTAssertNil(service.connectionInspection)
    }

    func testFailedIdentityReloadAndSecondInstanceReplacementCannotRetainOldAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)
        let firstEffects = TransportEffects()
        let first = makeTransport(firstEffects)
        _ = try first.attach(to: service)
        first.stop()
        firstEffects.failIdentity = true
        XCTAssertThrowsError(try first.attach(to: service))
        XCTAssertFalse(service.devices.transportAvailable)
        firstEffects.failIdentity = false
        _ = try first.attach(to: service)

        let replacementEffects = TransportEffects()
        replacementEffects.pin = 8
        let replacement = makeTransport(replacementEffects)
        XCTAssertThrowsError(try replacement.attach(to: service), "A second instance cannot silently replace the first")
        XCTAssertEqual(service.devices.controllerIdentity?.publicKey, Array(repeating: 7, count: 32))

        // An explicit coordinator-level replacement invalidates the old lease;
        // teardown by that old instance must not detach its successor.
        let external = FakeLinkFactory(pin: 8)
        service.devices.attach(external)
        first.stop()
        XCTAssertEqual(service.devices.controllerIdentity, external.controllerIdentity)
        service.devices.attach(nil)
        let owner = try replacement.attach(to: service)
        XCTAssertEqual(owner.publicKey, Array(repeating: 8, count: 32))
        XCTAssertEqual(service.devices.controllerIdentity, owner)
        XCTAssertNotNil(service.connectionDescription)
        replacement.stop()
        XCTAssertFalse(service.devices.transportAvailable)
    }

    private func makeService(_ root: URL) throws -> ControllerService {
        try ControllerService.bootstrap(root: root.appendingPathComponent("portable"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"))
    }

    private func makeTransport(_ effects: TransportEffects) -> AppleControllerTransport {
        AppleControllerTransport(
            linkFactory: {
                effects.identities += 1
                if effects.failIdentity { throw ControllerError.validationFailed(detail: "fake identity denied") }
                return FakeLinkFactory(pin: effects.pin)
            },
            discoveryFactory: { _ in effects.discoveries += 1; return effects.browser },
            connections: .init(description: { Data("fixture".utf8) })
        )
    }
}

private final class TransportEffects {
    var identities = 0
    var discoveries = 0
    var failIdentity = false
    var pin: UInt8 = 7
    let browser = FakeDiscovery()
}

private final class FakeDiscovery: ControllerLANDiscovery {
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

private struct FakeLinkFactory: DeviceLinkFactory {
    let pin: UInt8
    var controllerIdentity: PairingIdentity { PairingIdentity(role: .controller, publicKey: Array(repeating: pin, count: 32)) }
    func makeLink() throws -> DeviceLink { throw ControllerError.notPaired() }
}
