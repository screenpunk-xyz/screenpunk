import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

final class ControllerStoreTests: XCTestCase {
    func testAtomicSaveAndReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenpunk-controller-\(UUID().uuidString)")
        let store = ControllerStore(directory: dir)
        var session = WorkbenchSession(
            controllerIdentity: PairingIdentityFactory.make(
                role: .controller,
                bytes: [UInt8](repeating: 0x02, count: 32)
            )
        )
        session.importDraft(StoredRevision.offlineFixture)
        session.devices.append(
            PairedDevice(
                profile: DeviceProfile(deviceId: "phone-1", name: "iPhone"),
                owner: session.controllerIdentity,
                activeRevision: StoredRevision.offlineFixture.revision,
                history: [StoredRevision.offlineFixture]
            )
        )
        session.selectedDeviceId = "phone-1"
        try store.save(session)
        let loaded = try store.load()
        XCTAssertEqual(loaded.selectedDeviceId, "phone-1")
        XCTAssertEqual(loaded.drafts.first?.digest, StoredRevision.offlineFixture.digest)
        XCTAssertEqual(loaded.devices.first?.activeRevision, StoredRevision.offlineFixture.revision)
        XCTAssertEqual(ControllerPlaceholder.socketName, "screenpunk-controller.sock")
    }
}

final class DashboardPackageStoreTests: XCTestCase {
    func testCreatesTwoImmutableRevisionsAndDetectsStaleBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)

        let first = try store.putDashboard(
            dashboardId: nil,
            name: "Alpha",
            baseRevision: nil,
            target: fixtureTarget(),
            connections: [],
            files: [htmlFile("ONE")]
        )
        XCTAssertEqual(first.manifest.name, "Alpha")
        XCTAssertFalse(first.manifest.revision.isEmpty)
        XCTAssertNotNil(first.manifest.digest)

        let second = try store.putDashboard(
            dashboardId: first.manifest.dashboardId,
            name: "Alpha",
            baseRevision: first.manifest.revision,
            target: fixtureTarget(),
            connections: [],
            files: [htmlFile("TWO")]
        )
        XCTAssertNotEqual(second.manifest.revision, first.manifest.revision)
        XCTAssertEqual(try store.listRevisions(dashboardId: first.manifest.dashboardId).count, 2)

        XCTAssertThrowsError(
            try store.putDashboard(
                dashboardId: first.manifest.dashboardId,
                name: "Alpha",
                baseRevision: first.manifest.revision,
                target: fixtureTarget(),
                connections: [],
                files: [htmlFile("STALE")]
            )
        ) { error in
            XCTAssertEqual((error as? ControllerError)?.code, .revisionConflict)
        }
    }

    func testRejectsTraversalAndMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        XCTAssertThrowsError(
            try store.putDashboard(
                dashboardId: nil,
                name: "Bad",
                baseRevision: nil,
                target: fixtureTarget(),
                connections: [],
                files: [DashboardFileInput(path: "../secret", text: "x", base64: nil)]
            )
        )
        XCTAssertThrowsError(
            try store.putDashboard(
                dashboardId: nil,
                name: "Empty",
                baseRevision: nil,
                target: fixtureTarget(),
                connections: [],
                files: []
            )
        )
    }

    /// MCP callers hand dashboardId/revision straight through. A `..` segment
    /// must never become a path component under the controller home.
    func testRejectsIdentifierPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sp-ctrl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        let escape = "../../../../tmp/sp-escape-\(UUID().uuidString)"

        // Writing to an escaped dashboardId must fail and create nothing outside root.
        XCTAssertThrowsError(
            try store.putDashboard(dashboardId: escape, name: "Evil", baseRevision: nil,
                                   target: fixtureTarget(), connections: [], files: [htmlFile("x")])
        ) { XCTAssertEqual(($0 as? ControllerError)?.code, .validationFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/sp-escape-head.json"))

        for bad in [escape, "..", ".", "a/b", "../secret", "with space"] {
            XCTAssertThrowsError(try store.getRevision(dashboardId: bad, revision: nil), bad)
            XCTAssertThrowsError(try store.listRevisions(dashboardId: bad), bad)
        }

        // A real dashboard still reads back with a traversal revision rejected.
        let good = try store.putDashboard(dashboardId: nil, name: "Good", baseRevision: nil,
                                          target: fixtureTarget(), connections: [], files: [htmlFile("ok")])
        XCTAssertThrowsError(try store.getRevision(dashboardId: good.manifest.dashboardId, revision: "../../etc/passwd"))
        XCTAssertNoThrow(try store.getRevision(dashboardId: good.manifest.dashboardId, revision: good.manifest.revision))
    }
}

func fixtureTarget() -> ManifestTarget {
    ManifestTarget(
        profileId: "fixture-phone",
        width: 390,
        height: 844,
        scale: 3,
        orientation: "portrait"
    )
}

func htmlFile(_ marker: String) -> DashboardFileInput {
    DashboardFileInput(
        path: "index.html",
        text: "<!doctype html><html><body><p>\(marker)</p></body></html>",
        base64: nil
    )
}

func testPNG() -> Data {
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54,
        0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
        0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])
}
