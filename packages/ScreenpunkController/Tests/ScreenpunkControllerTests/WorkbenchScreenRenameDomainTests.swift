import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct ScreenRenameDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchScreenRenameDomainTests: XCTestCase {
    private func fixture() throws -> (URL, WorkspaceStore, WorkbenchContainedAuthoring, WorkbenchSourceProject) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-screen-rename-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: ScreenRenameDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        let authoring = WorkbenchContainedAuthoring(workspace: store)
        let project = try authoring.create(name: "Old screen", kind: "web", trustedKitVersion: "kit-1")
        return (root, store, authoring, project)
    }

    private func request(_ overview: WorkspaceOverview, project: WorkbenchSourceProject,
                         name: String) throws -> WorkbenchScreenRenameRequest {
        try WorkbenchScreenRenameRequest.parse([
            "schemaVersion": 1,
            "expectedWorkspaceId": overview.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(overview.selectionGeneration),
            "expectedCatalogGeneration": overview.catalog.generation,
            "projectId": project.project.projectId,
            "expectedSourceVersion": project.sourceVersion,
            "name": name
        ])
    }

    func testRenameCommitsSourceCatalogAndHistoryWithoutRewritingPackage() throws {
        let (root, store, authoring, created) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Data("{\"name\":\"Old screen\",\"opacity\":0.5,\"offset\":-1}".utf8)
        let edited = try authoring.patch(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "screen.json", bytes: config)])
        let other = try authoring.create(name: "Other", kind: "web", trustedKitVersion: "kit-1")
        let oldHistory = root.appendingPathComponent("visible/Workbench/History/Builds/\(edited.sourceVersion)/source")
        let oldConfig = try Data(contentsOf: oldHistory.appendingPathComponent("screen.json"))
        let oldDescriptor = try Data(contentsOf: oldHistory.appendingPathComponent("screenpunk.project.json"))
        let asset = Data("<html>retained</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: created.project.dashboardId, name: "Old screen",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: asset.count,
                sha256: DeploymentDigest.sha256Hex(asset))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: store)
        _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": asset]))
        let before = try XCTUnwrap(store.current())
        let stale = try request(before, project: edited, name: "Renamed")
        let renamed = try WorkbenchScreenRenameDomain(workspace: store).rename(stale)
        XCTAssertEqual(renamed.project.project.name, "Renamed")
        XCTAssertNotEqual(renamed.project.sourceVersion, edited.sourceVersion)
        XCTAssertEqual(renamed.catalogGeneration, before.descriptor.generation + 1)
        let after = try XCTUnwrap(store.current())
        XCTAssertEqual(after.catalog.projects.first { $0.projectId == created.project.projectId }?.name, "Renamed")
        XCTAssertEqual(after.catalog.projects.first { $0.projectId == other.project.projectId }, other.project)
        XCTAssertEqual(try authoring.versions(created.project.projectId).count, 3)
        XCTAssertEqual(try Data(contentsOf: oldHistory.appendingPathComponent("screen.json")), oldConfig)
        XCTAssertEqual(try Data(contentsOf: oldHistory.appendingPathComponent("screenpunk.project.json")), oldDescriptor)
        let renamedConfig = try XCTUnwrap(WorkspaceJSON.object(from:
            Data(contentsOf: URL(fileURLWithPath: renamed.project.path).appendingPathComponent("screen.json")))["name"] as? String)
        XCTAssertEqual(renamedConfig, "Renamed")
        XCTAssertEqual(try packages.get(dashboardId: manifest.dashboardId,
            revision: manifest.revision).files["index.html"], asset)
        XCTAssertThrowsError(try WorkbenchScreenRenameDomain(workspace: store).rename(stale)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try store.current()?.descriptor.generation, after.descriptor.generation)
    }

    func testClosedRequestAndDuplicateKeyConfigurationFailBeforePublication() throws {
        let (root, store, authoring, created) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try XCTUnwrap(store.current())
        var fields: [String: Any] = [
            "schemaVersion": 1, "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.catalog.generation,
            "projectId": created.project.projectId,
            "expectedSourceVersion": created.sourceVersion, "name": "New"]
        fields["role"] = "gui"
        XCTAssertThrowsError(try WorkbenchScreenRenameRequest.parse(fields))
        fields.removeValue(forKey: "role")
        fields["expectedCatalogGeneration"] = true
        XCTAssertThrowsError(try WorkbenchScreenRenameRequest.parse(fields))

        let duplicate = Data("{\"name\":\"Old\",\"name\":\"Forged\"}".utf8)
        let edited = try authoring.patch(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "screen.json", bytes: duplicate)])
        let selected = try XCTUnwrap(store.current())
        XCTAssertThrowsError(try WorkbenchScreenRenameDomain(workspace: store)
            .rename(request(selected, project: edited, name: "New"))) {
            XCTAssertEqual($0 as? WorkspaceError, .invalidSchema)
        }
        XCTAssertEqual(try store.current()?.catalog, selected.catalog)
        XCTAssertEqual(try authoring.versions(created.project.projectId).count, 2)
    }
}
#endif
