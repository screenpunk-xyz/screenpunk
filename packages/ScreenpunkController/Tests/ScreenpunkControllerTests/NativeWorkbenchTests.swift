import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class NativeWorkbenchTests: XCTestCase {
    func testReusableScreenPreparationDoesNotChangeSourceAndDeleteKeepsDeployment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        let source = try store.putDashboard(dashboardId: nil, name: "Clock", baseRevision: nil, target: fixtureTarget(), connections: [], files: [htmlFile("clock")])
        let prepared = try ScreenPackagePreparation.prepare(source, for: DeviceProfile(deviceId: "ipad", name: "Kitchen iPad", width: 768,height: 1024), orientation: .landscape, root: root)
        XCTAssertEqual(prepared.manifest.target.width, 1024)
        XCTAssertEqual(prepared.manifest.target.height, 768)
        XCTAssertEqual(prepared.manifest.dashboardId, source.manifest.dashboardId)
        XCTAssertEqual(prepared.files, source.files)
        XCTAssertNotEqual(prepared.manifest.digest, source.manifest.digest)
        XCTAssertEqual(try store.listDashboards().count, 1)
        XCTAssertEqual(try store.getRevision(dashboardId: source.manifest.dashboardId, revision: nil).manifest, source.manifest)
        try store.deleteDashboard(dashboardId: source.manifest.dashboardId)
        XCTAssertTrue(try store.listDashboards().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.packageDirectory.appendingPathComponent("index.html").path))
        XCTAssertThrowsError(try store.deleteDashboard(dashboardId: "../device-packages"))
    }

    func testScreenOrientationLockPersistsThroughUpdatesAndBlocksIncompatibleApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        let locked = try store.putDashboard(dashboardId: nil, name: "Portrait Screen", baseRevision: nil, target: fixtureTarget(), connections: [], files: [htmlFile("portrait"), DashboardFileInput(path: ScreenDesignSettings.path, base64: try ScreenDesignSettings(orientations: .portrait).data().base64EncodedString())])
        let updated = try store.putDashboard(dashboardId: locked.manifest.dashboardId, name: locked.manifest.name, baseRevision: locked.manifest.revision, target: fixtureTarget(), connections: [], files: [htmlFile("updated")])
        XCTAssertEqual(try ScreenDesignSettings.read(files: updated.files).orientations, .portrait)
        XCTAssertThrowsError(try ScreenPackagePreparation.prepare(updated, for: DeviceProfile(deviceId: "phone", name: "Phone"), orientation: .landscape, root: root))
        XCTAssertNoThrow(try ScreenPackagePreparation.prepare(updated, for: DeviceProfile(deviceId: "phone", name: "Phone"), orientation: .portrait, root: root))
        var landscape = fixtureTarget(); landscape.orientation = "landscape"; landscape.width = 844; landscape.height = 390
        XCTAssertThrowsError(try store.putDashboard(dashboardId: updated.manifest.dashboardId, name: updated.manifest.name, baseRevision: updated.manifest.revision, target: landscape, connections: [], files: [htmlFile("wrong orientation")]))
    }

    func testDuplicateCanBeEditedWithoutChangingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        let original = try store.putDashboard(dashboardId: nil, name: "Clock", baseRevision: nil, target: fixtureTarget(), connections: [], files: [htmlFile("original")])
        let copy = try store.putDashboard(dashboardId: nil, name: "Clock Copy", baseRevision: nil, target: original.manifest.target, connections: original.manifest.connections, files: original.files.map { DashboardFileInput(path: $0.key, base64: $0.value.base64EncodedString()) })
        XCTAssertNotEqual(copy.manifest.dashboardId, original.manifest.dashboardId)
        _ = try store.putDashboard(dashboardId: copy.manifest.dashboardId, name: "New Clock", baseRevision: copy.manifest.revision, target: copy.manifest.target, connections: [], files: [htmlFile("edited copy")])
        let unchanged = try store.getRevision(dashboardId: original.manifest.dashboardId, revision: nil)
        XCTAssertEqual(unchanged.manifest, original.manifest)
        XCTAssertEqual(unchanged.files, original.files)
        XCTAssertEqual(try store.listDashboards().count, 2)
    }

    func testTwoControllerClientsMergeDeviceWritesAndObserveRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = DeviceDirectory(url: root.appendingPathComponent("devices.json"))
        let b = DeviceDirectory(url: root.appendingPathComponent("devices.json"))
        let owner = PairingIdentityFactory.make(role: .controller)
        func record(_ id: String) -> PairedDeviceRecord {
            PairedDeviceRecord(device: PairedDevice(profile: DeviceProfile(deviceId: id, name: id), owner: owner), host: "localhost", port: 7843, devicePinHex: String(repeating: "ab", count: 32), pairedAt: Date())
        }
        try a.upsert(record("one")); try b.upsert(record("two"))
        XCTAssertEqual(a.list().map(\.id), ["one","two"])
        try a.remove("one")
        XCTAssertNil(b.get("one"))
        XCTAssertEqual(b.list().map(\.id), ["two"])
    }
}
