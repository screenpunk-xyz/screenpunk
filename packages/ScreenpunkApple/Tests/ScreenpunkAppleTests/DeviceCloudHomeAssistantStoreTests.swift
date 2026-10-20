import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

final class DeviceCloudHomeAssistantStoreTests: XCTestCase {
    private func manifest() -> DashboardManifest {
        var home = ManifestConnection(alias: "home", required: true)
        home.operations = [.init(name: "getStates", kind: "http", maxAgeSeconds: 10)]
        home.serviceCalls = [.init(domain: "light", service: "turn_on", entityIds: ["light.fixture"])]
        home.cameraEntities = ["camera.fixture"]
        return DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Fixture",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            digest: String(repeating: "a", count: 64),
            target: .init(profileId: "Fixture", width: 390, height: 844, scale: 1, orientation: "portrait"),
            connections: [home], files: [.init(path: "index.html", bytes: 1, sha256: String(repeating: "b", count: 64))])
    }
    func testApprovalBindsInstallationRevisionAndDigestAndCopiesOnlyDeclarations() throws {
        let memory = MemoryCredentialStore(), installation = UUID(), otherInstallation = UUID()
        let store = DeviceCloudHomeAssistantStore(store: memory), screen = manifest()
        XCTAssertNil(try store.configuration(installationID: installation, manifest: screen))
        try store.approve(installationID: installation, manifest: screen, origin: "http://192.168.1.40",
            token: "synthetic-token", allowInsecureHTTP: true)
        let approved = try XCTUnwrap(store.configuration(installationID: installation, manifest: screen))
        XCTAssertEqual(approved.serviceCalls, screen.connections[0].serviceCalls)
        XCTAssertEqual(approved.cameraEntities, screen.connections[0].cameraEntities)
        XCTAssertNil(try store.configuration(installationID: otherInstallation, manifest: screen))
        var changed = screen; changed.revision = UUID().uuidString.lowercased()
        XCTAssertNil(try store.configuration(installationID: installation, manifest: changed))
        changed = screen; changed.digest = String(repeating: "b", count: 64)
        XCTAssertNil(try store.configuration(installationID: installation, manifest: changed))
        changed = screen; changed.dashboardId = UUID().uuidString.lowercased()
        XCTAssertNil(try store.configuration(installationID: installation, manifest: changed))
        XCTAssertEqual(try DeviceCloudHomeAssistantStore(store: memory).configuration(installationID: installation, manifest: screen), approved)
    }
    func testSavedConnectionRequiresNewExplicitApproval() throws {
        let store = DeviceCloudHomeAssistantStore(store: MemoryCredentialStore()), installation = UUID()
        let first = manifest(), second = manifest()
        try store.approve(installationID: installation, manifest: first, origin: "https://home.example", token: "synthetic-token", allowInsecureHTTP: false)
        XCTAssertTrue(try store.hasSavedConnection(installationID: installation))
        XCTAssertNil(try store.configuration(installationID: installation, manifest: second))
        try store.approveSaved(installationID: installation, manifest: second)
        XCTAssertEqual(try store.configuration(installationID: installation, manifest: second)?.origin, "https://home.example")
        XCTAssertThrowsError(try store.approveSaved(installationID: UUID(), manifest: second))
    }
    func testRevocationPreservesOtherInstallationsAndDeletesLastCredentialRecord() throws {
        let memory = MemoryCredentialStore(), store = DeviceCloudHomeAssistantStore(store: memory)
        let first = UUID(), second = UUID(), screen = manifest()
        for installation in [first, second] {
            try store.approve(installationID: installation, manifest: screen, origin: "https://home.example",
                token: "synthetic-token", allowInsecureHTTP: false)
        }
        try store.revoke(installationID: first, dashboardID: screen.dashboardId)
        XCTAssertNil(try store.configuration(installationID: first, manifest: screen))
        XCTAssertNotNil(try store.configuration(installationID: second, manifest: screen))
        try store.revoke(installationID: second)
        XCTAssertNotNil(try store.savedConnection(installationID: first))
        try store.revoke(installationID: first)
        XCTAssertNil(try memory.secret(for: DeviceCloudHomeAssistantStore.storageKey))
    }
    func testSavingConnectionDoesNotGrantAccessAndToggleOffKeepsCredentials() throws {
        let memory = MemoryCredentialStore(), store = DeviceCloudHomeAssistantStore(store: memory), installation = UUID(), screen = manifest()
        try store.saveConnection(installationID: installation, origin: "https://home.example", token: "first-token", allowInsecureHTTP: false)
        XCTAssertNil(try store.configuration(installationID: installation, manifest: screen))
        try store.approveSaved(installationID: installation, manifest: screen)
        XCTAssertNotNil(try store.configuration(installationID: installation, manifest: screen))
        try store.revoke(installationID: installation, dashboardID: screen.dashboardId)
        XCTAssertNil(try store.configuration(installationID: installation, manifest: screen))
        XCTAssertEqual(try store.savedConnection(installationID: installation)?.token, "first-token")
        try store.approveSaved(installationID: installation, manifest: screen)
        try store.saveConnection(installationID: installation, origin: "https://home.example", token: "rotated-token", allowInsecureHTTP: false)
        XCTAssertEqual(try store.configuration(installationID: installation, manifest: screen)?.token, "rotated-token")
        var changed = screen; changed.digest = String(repeating: "c", count: 64)
        XCTAssertNil(try store.configuration(installationID: installation, manifest: changed))
        try store.revoke(installationID: installation)
        XCTAssertNil(try store.savedConnection(installationID: installation))
        XCTAssertNil(try memory.secret(for: DeviceCloudHomeAssistantStore.storageKey))
    }
    func testLegacyApprovalRecordsRemainReadable() throws {
        let memory = MemoryCredentialStore(), store = DeviceCloudHomeAssistantStore(store: memory), installation = UUID(), screen = manifest()
        try store.approve(installationID: installation, manifest: screen, origin: "https://home.example", token: "legacy-token", allowInsecureHTTP: false)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(memory.secret(for: DeviceCloudHomeAssistantStore.storageKey))) as? [String: Any])
        try memory.put(JSONSerialization.data(withJSONObject: XCTUnwrap(envelope["records"])), for: DeviceCloudHomeAssistantStore.storageKey)
        XCTAssertEqual(try store.savedConnection(installationID: installation)?.token, "legacy-token")
        XCTAssertNotNil(try store.configuration(installationID: installation, manifest: screen))
        try store.saveConnection(installationID: installation, origin: "https://home.example", token: "new-token", allowInsecureHTTP: false)
        XCTAssertEqual(try store.configuration(installationID: installation, manifest: screen)?.token, "new-token")
    }
    func testApprovalRejectsUndeclaredHomeAndUnapprovedHTTP() throws {
        let store = DeviceCloudHomeAssistantStore(store: MemoryCredentialStore())
        var screen = manifest()
        XCTAssertThrowsError(try store.approve(installationID: UUID(), manifest: screen, origin: "http://192.168.1.40",
            token: "synthetic-token", allowInsecureHTTP: false))
        screen.connections = []
        XCTAssertThrowsError(try store.approve(installationID: UUID(), manifest: screen, origin: "https://home.example",
            token: "synthetic-token", allowInsecureHTTP: false))
    }
}
