import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple
#if canImport(Network) && canImport(Security)
final class DeviceSettingsServerTests: XCTestCase {
    private func makeServer(identity: TLSIdentityMaterial, store: DeviceStateStore) -> DeviceLANServer {
        DeviceLANServer(runtime: DeviceRuntime(identity: identity.pairingIdentity,
            profile: DeviceProfile(deviceId: "settings-phone", name: "Settings Phone"),
            advertisement: AdvertisedDevice(deviceId: "settings-phone", host: "127.0.0.1", port: 0, source: .advertised)),
            identity: identity, store: store,
            homeAssistantVault: HomeAssistantDeviceVault(store: MemoryCredentialStore()),
            genericConnectionVault: GenericConnectionDeviceVault(store: MemoryCredentialStore()))
    }

    func testLocalCASPersistenceRuntimeAcknowledgementAndUnlink() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "settings-local-test")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let server = makeServer(identity: identity, store: store)
        let original = server.settingsSnapshot
        let saved = try server.updateSettingsLocally(.init(expectedRevision: original.revision,
            value: .init(brightness: .init(mode: .fixed, fixedLevel: 0.7))))
        XCTAssertEqual(store.load()?.settings, saved)
        XCTAssertFalse(saved.isApplied)
        server.markSettingsApplied(revision: original.revision)
        XCTAssertFalse(server.settingsSnapshot.isApplied, "late apply cannot acknowledge a newer edit")
        server.markSettingsApplied(revision: saved.revision)
        XCTAssertTrue(server.settingsSnapshot.isApplied)
        server.markSettingsUnapplied(revision: original.revision)
        XCTAssertTrue(server.settingsSnapshot.isApplied, "a stale background callback cannot clear newer runtime state")
        server.markSettingsUnapplied(revision: saved.revision)
        XCTAssertFalse(server.settingsSnapshot.isApplied)
        server.markSettingsApplied(revision: saved.revision)
        XCTAssertThrowsError(try server.updateSettingsLocally(.init(expectedRevision: original.revision, value: .init()))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .conflict)
        }
        let relaunched = makeServer(identity: identity, store: store)
        XCTAssertEqual(relaunched.settingsSnapshot.revision, saved.revision)
        XCTAssertEqual(relaunched.settingsSnapshot.value, saved.value)
        XCTAssertFalse(relaunched.settingsSnapshot.isApplied, "app relaunch needs fresh runtime acknowledgement")
        relaunched.unlink()
        XCTAssertEqual(relaunched.settingsSnapshot.value, DeviceSettings())
        XCTAssertFalse(store.hasState)
    }

    func testPersistenceFailureDoesNotChangeLiveSettings() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "settings-failure-test")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = makeServer(identity: identity, store: DeviceStateStore(root: root))
        let original = server.settingsSnapshot
        XCTAssertThrowsError(try server.updateSettingsLocally(.init(expectedRevision: original.revision,
            value: .init(brightness: .init(mode: .fixed, fixedLevel: 0.1))))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .persistenceFailed)
        }
        XCTAssertEqual(server.settingsSnapshot, original)
    }

    func testUnknownStartingPageIsRejectedRatherThanPersisted() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "settings-page-test")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let server = makeServer(identity: identity, store: store)
        let original = server.settingsSnapshot
        XCTAssertThrowsError(try server.updateSettingsLocally(.init(expectedRevision: original.revision,
            value: .init(startingPageByDashboard: ["not-installed": "page"])))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .invalidSettings)
        }
        XCTAssertEqual(server.settingsSnapshot, original)
    }

    func testDormantDashboardPreferenceDoesNotBlockUnrelatedBrightnessEdit() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "settings-dormant-test")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        var state = DevicePersistedState(owner: nil, activeRevision: nil, activeStoredRevision: nil, lastDeployment: nil)
        state.settings = .init(value: .init(startingPageByDashboard: ["removed-dashboard": "removed-page"]))
        try store.save(state)
        let server = makeServer(identity: identity, store: store)
        var desired = server.settingsSnapshot.value
        desired.brightness = .init(mode: .fixed, fixedLevel: 0.6)
        let saved = try server.updateSettingsLocally(.init(expectedRevision: server.settingsSnapshot.revision, value: desired))
        XCTAssertEqual(saved.value.startingPageByDashboard["removed-dashboard"], "removed-page")
        desired.startingPageByDashboard["removed-dashboard"] = "unapproved-new-page"
        XCTAssertThrowsError(try server.updateSettingsLocally(.init(expectedRevision: saved.revision, value: desired))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .invalidSettings)
        }
        desired.startingPageByDashboard = [:]
        XCTAssertNoThrow(try server.updateSettingsLocally(.init(expectedRevision: saved.revision, value: desired)))
    }

    func testLANSettingsRequiresOwnerAndCompetingLocalEditRejectsMacCAS() throws {
        let identity = try TLSIdentity.make(role: .device, commonName: "settings-lan-device")
        let owner = try TLSIdentity.make(role: .controller, commonName: "settings-lan-owner")
        let store = DeviceStateStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.erase() }
        let server = makeServer(identity: identity, store: store)
        try server.start()
        defer { server.stop() }
        let client = ControllerLANClient(identity: owner)
        defer { client.cancel() }
        try client.connect(host: "127.0.0.1", port: server.port)
        _ = try client.hello()
        XCTAssertThrowsError(try client.getSettings()) { XCTAssertEqual($0 as? TransferFailure, .notPaired) }
        let begin = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
        try server.confirmLocally()
        try client.confirmPairing(code: begin.code)
        let mac = try client.getSettings()
        let local = try server.updateSettingsLocally(.init(expectedRevision: mac.revision,
            value: .init(brightness: .init(mode: .fixed, fixedLevel: 0.3))))
        XCTAssertThrowsError(try client.updateSettings(.init(expectedRevision: mac.revision, value: .init()))) {
            XCTAssertEqual($0 as? DeviceSettingsFailure, .conflict)
        }
        XCTAssertEqual(try client.getSettings().revision, local.revision)
        let saved = try client.updateSettings(.init(expectedRevision: local.revision, value: .init()))
        XCTAssertEqual(store.load()?.settings?.revision, saved.revision)
    }
}
#endif
