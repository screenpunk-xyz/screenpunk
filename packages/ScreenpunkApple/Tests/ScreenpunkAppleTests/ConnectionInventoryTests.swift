import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class ConnectionInventoryTests: XCTestCase {
    private func config(_ screen: String, token: String = "fixture-secret") -> HomeAssistantProvisioning {
        var value = HomeAssistantProvisioning(dashboardId: screen, connectionId: "home", provisioningId: screen,
            revision: screen + "-revision", origin: "https://ha.example", token: token)
        value.schemaVersion = 2
        value.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.kitchen"])]
        return value
    }
    private func screen(_ id: String) -> LANScreenSetEntry { .init(dashboardId: id, revision: id + "-revision", name: id) }

    func testInventoryExcludesSecretsAndForeignOwners() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.stage([config("one")], owner: "owner", generation: "set")
        let entries = try vault.inventory(owner: "owner", screen: screen("one"), grantSet: "set")
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(entries), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(entries[0].operations.filter(\.write).count, 1)
        XCTAssertTrue(try vault.inventory(owner: "stranger", screen: screen("one"), grantSet: "set").isEmpty)
    }
    func testAtomicUpdatePreservesScopesAndRejectsStaleReplay() throws {
        let store = MemoryCredentialStore()
        let vault = HomeAssistantDeviceVault(store: store)
        try vault.stage([config("one"), config("two")], owner: "owner", generation: "set")
        let entries = try ["one", "two"].flatMap { try vault.inventory(owner: "owner", screen: screen($0), grantSet: "set") }
        let update = DeviceHomeAssistantUpdate(entries: entries, origin: "https://ha.example", token: "replacement")
        try vault.update(update, owner: "owner", grantSet: "set")
        for id in ["one", "two"] {
            let saved = try HomeAssistantDeviceVault(store: store).record(owner: "owner", revision: id + "-revision", grantSet: "set").configuration
            XCTAssertEqual(saved.token, "replacement")
            XCTAssertEqual(saved.serviceCalls, config(id).serviceCalls)
        }
        XCTAssertThrowsError(try vault.update(update, owner: "owner", grantSet: "set"))
    }
    func testOriginChangeRequiresNewTokenAndInvalidBatchDoesNotPartiallySave() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.stage([config("one"), config("two")], owner: "owner", generation: "set")
        var entries = try ["one", "two"].flatMap { try vault.inventory(owner: "owner", screen: screen($0), grantSet: "set") }
        XCTAssertThrowsError(try vault.update(.init(entries: entries, origin: "https://another.example", token: nil), owner: "owner", grantSet: "set"))
        entries[1].configurationVersion = "stale"
        XCTAssertThrowsError(try vault.update(.init(entries: entries, origin: "https://ha.example", token: "replacement"), owner: "owner", grantSet: "set"))
        XCTAssertEqual(try vault.record(owner: "owner", revision: "one-revision", grantSet: "set").configuration.token, "fixture-secret")
    }
    func testLegacyUpdateRetainsSavedToken() throws {
        let vault = HomeAssistantDeviceVault(store: MemoryCredentialStore())
        try vault.provision(config("one"), owner: "owner")
        let entries = try vault.inventory(owner: "owner", screen: screen("one"), grantSet: nil)
        try vault.update(.init(entries: entries, origin: "https://ha.example", token: nil), owner: "owner", grantSet: nil)
        XCTAssertEqual(try vault.record(owner: "owner", revision: "one-revision").configuration.token, "fixture-secret")
    }
}
