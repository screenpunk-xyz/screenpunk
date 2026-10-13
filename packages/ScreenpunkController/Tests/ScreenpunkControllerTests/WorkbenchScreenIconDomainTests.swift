import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct ScreenIconDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchScreenIconDomainTests: XCTestCase {
    func testIconIsPortableCASMetadataAndSurvivesCopyAndHistoryPublication() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-icon-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: ScreenIconDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        let visible = root.appendingPathComponent("visible")
        _ = try store.create(at: visible.path)
        let asset = Data("<html>icon</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Icon",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: asset.count,
                sha256: DeploymentDigest.sha256Hex(asset))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: store)
        _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": asset]))
        let before = try XCTUnwrap(store.current())
        let fields: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": manifest.dashboardId, "symbol": "square.grid.2x2"]
        let request = try WorkbenchScreenIconRequest.parse(fields)
        let result = try WorkbenchScreenIconDomain(workspace: store).set(request)
        XCTAssertEqual(result.catalogGeneration, before.descriptor.generation + 1)
        XCTAssertEqual(try store.current()?.settings.screenIcons[manifest.dashboardId], "square.grid.2x2")
        XCTAssertEqual(try packages.get(dashboardId: manifest.dashboardId,
            revision: manifest.revision).manifest, manifest)
        XCTAssertThrowsError(try WorkbenchScreenIconDomain(workspace: store).set(request)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        _ = try WorkbenchContainedAuthoring(workspace: store)
            .create(name: "Another", kind: "web", trustedKitVersion: "kit-1")
        XCTAssertEqual(try store.current()?.settings.screenIcons[manifest.dashboardId], "square.grid.2x2")
        var nextManifest = manifest
        nextManifest.revision = UUID().uuidString.lowercased()
        nextManifest.digest = try DeploymentDigest.digest(for: nextManifest)
        _ = try packages.importVerified(.init(manifest: nextManifest,
            files: ["index.html": asset]))
        let afterHistory = try XCTUnwrap(store.current())
        _ = try WorkbenchWorkspaceConfiguration(workspace: store).set(key: "theme",
            value: "dark", expectedGeneration: afterHistory.settings.generation)
        XCTAssertEqual(try store.current()?.settings.screenIcons[manifest.dashboardId], "square.grid.2x2")

        let restored = root.appendingPathComponent("restored")
        try FileManager.default.copyItem(at: visible, to: restored)
        let restoredDocs = root.appendingPathComponent("RestoredDocuments")
        try FileManager.default.createDirectory(at: restoredDocs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let other = try WorkspaceStore(documents: ScreenIconDocuments(url: restoredDocs),
            machineRootPath: root.appendingPathComponent("other-machine").path)
        _ = try other.open(at: restored.path)
        XCTAssertEqual(try other.current()?.settings.screenIcons[manifest.dashboardId], "square.grid.2x2")

        var injected = fields; injected["role"] = "gui"
        XCTAssertThrowsError(try WorkbenchScreenIconRequest.parse(injected))
        injected = fields; injected["expectedCatalogGeneration"] = true
        XCTAssertThrowsError(try WorkbenchScreenIconRequest.parse(injected))
        injected = fields; injected["symbol"] = "../../token"
        XCTAssertThrowsError(try WorkbenchScreenIconRequest.parse(injected))
    }

    func testLegacySettingsDecodeWithEmptyIconsAndV2RequiresClosedField() throws {
        let v1 = Data("{\"schemaVersion\":1,\"generation\":3,\"presentation\":{},\"profiles\":{}}".utf8)
        let legacy = try WorkspaceJSON.decode(WorkspaceSettings.self, from: v1, shape: .settings)
        XCTAssertEqual(legacy.screenIcons, [:])
        XCTAssertEqual(legacy.schemaVersion, 1)
        let missing = Data("{\"schemaVersion\":2,\"generation\":3,\"presentation\":{},\"profiles\":{}}".utf8)
        XCTAssertThrowsError(try WorkspaceJSON.decode(WorkspaceSettings.self,
            from: missing, shape: .settings))

        let root = URL(fileURLWithPath: "/private/tmp/sp-icon-v1-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: ScreenIconDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        let visible = root.appendingPathComponent("visible")
        _ = try store.create(at: visible.path)
        let project = try WorkbenchContainedAuthoring(workspace: store)
            .create(name: "Legacy", kind: "web", trustedKitVersion: "kit-1")
        let before = try XCTUnwrap(store.current())
        let oldSettings = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "generation": before.settings.generation,
            "presentation": before.settings.presentation, "profiles": before.settings.profiles],
            options: [.sortedKeys])
        try oldSettings.write(to: visible.appendingPathComponent("Workbench/Settings/workbench.json"),
            options: .atomic)
        XCTAssertEqual(try store.current()?.settings.schemaVersion, 1)
        _ = try WorkbenchScreenIconDomain(workspace: store).set(.parse([
            "schemaVersion": 1, "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": project.project.dashboardId, "symbol": "star.fill"]))
        XCTAssertEqual(try store.current()?.settings.schemaVersion, 2)
        XCTAssertEqual(try store.current()?.settings.screenIcons[project.project.dashboardId], "star.fill")
    }
}
#endif
