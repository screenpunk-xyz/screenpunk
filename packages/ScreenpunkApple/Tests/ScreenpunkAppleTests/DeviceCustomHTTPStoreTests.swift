import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple
final class DeviceCustomHTTPStoreTests: XCTestCase {
    func testApprovalReuseRevisionIsolationAndRevoke() throws {
        let store = DeviceCustomHTTPStore(store: MemoryCredentialStore()), id = UUID()
        var connection = ManifestConnection(alias: "desk", required: true)
        connection.customHTTP = .init(name: "Desk", authentication: "bearer", operations: [.init(name: "read", method: "GET", path: "/status")])
        var m = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString, name: "Fixture", revision: UUID().uuidString, entrypoint: "index.html", sdkVersion: "1", digest: String(repeating: "a", count: 64), target: .init(profileId: "iPad", width: 800, height: 600, scale: 1, orientation: "landscape"), connections: [connection], files: [.init(path: "index.html", bytes: 1, sha256: String(repeating: "b", count: 64))])
        try store.approve(installationID: id, manifest: m, alias: "desk", configuration: .init(origin: "https://desk.example", secret: "fixture", allowLocalNetwork: false, allowInsecureHTTP: false))
        XCTAssertNotNil(try store.configuration(installationID: id, manifest: m, alias: "desk"))
        XCTAssertNil(try store.configuration(installationID: UUID(), manifest: m, alias: "desk"))
        m.digest = String(repeating: "c", count: 64); m.revision = UUID().uuidString
        XCTAssertNil(try store.configuration(installationID: id, manifest: m, alias: "desk"))
        try store.approveSaved(installationID: id, manifest: m, alias: "desk")
        XCTAssertNotNil(try store.configuration(installationID: id, manifest: m, alias: "desk"))
        try store.revoke(installationID: id, dashboardID: m.dashboardId, alias: "desk")
        XCTAssertNil(try store.configuration(installationID: id, manifest: m, alias: "desk"))
    }
}
