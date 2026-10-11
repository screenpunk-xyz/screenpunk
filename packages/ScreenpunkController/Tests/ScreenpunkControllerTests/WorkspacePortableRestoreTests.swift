import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct PortableRestoreDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkspacePortableRestoreTests: XCTestCase {
    func testCopiedWorkspaceOpensWithFreshMachineRootAndRetainsPortableAuthoring() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-portable-restore-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let originalMachine = root.appendingPathComponent("old-machine")
        let old = try WorkspaceStore(documents: PortableRestoreDocuments(path: documents),
            machineRootPath: originalMachine.path)
        let originalPath = root.appendingPathComponent("visible")
        _ = try old.create(at: originalPath.path)
        let authoring = WorkbenchContainedAuthoring(workspace: old)
        let project = try authoring.create(name: "Recover", kind: "web", trustedKitVersion: "kit-1")
        let edited = try authoring.patch(project.project.projectId,
            expectedSourceVersion: project.sourceVersion,
            changes: [.init(path: "data/demo.json", bytes: Data("{\"demo\":true}".utf8))])
        let initial = try XCTUnwrap(old.current())
        _ = try old.updateSettings(["theme": "dark"], profiles: ["desk": ["view": "list"]],
            expectedGeneration: initial.settings.generation)
        let note = Data("saved review note".utf8)
        let attachment = originalPath.appendingPathComponent("Workbench/Attachments/note.txt")
        try note.write(to: attachment)
        let html = Data("<html>retained package</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: project.project.dashboardId, name: "Recovered package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: old).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let restoredPath = root.appendingPathComponent("copied-workspace")
        try FileManager.default.copyItem(at: originalPath, to: restoredPath)
        let freshMachine = root.appendingPathComponent("fresh-machine")
        let restored = try WorkspaceStore(documents: PortableRestoreDocuments(path: documents),
            machineRootPath: freshMachine.path)
        XCTAssertNil(try restored.current())
        let opened = try restored.open(at: restoredPath.path)
        XCTAssertEqual(opened.descriptor.workspaceId, initial.descriptor.workspaceId)
        XCTAssertEqual(opened.catalog.projects.count, 1)
        XCTAssertEqual(opened.settings.presentation["theme"], "dark")
        XCTAssertEqual(opened.settings.profiles["desk"]?["view"], "list")
        XCTAssertEqual(opened.authenticatedDeviceCount, 0)
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: restored)
            .get(edited.project.projectId).sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try Data(contentsOf: restoredPath.appendingPathComponent(
            "Screens/recover/data/demo.json")), Data("{\"demo\":true}".utf8))
        XCTAssertEqual(try Data(contentsOf: restoredPath.appendingPathComponent(
            "Workbench/Attachments/note.txt")), note)
        let retained = try WorkbenchPortablePackages(workspace: restored)
            .get(dashboardId: manifest.dashboardId, revision: manifest.revision)
        XCTAssertEqual(retained.manifest, manifest)
        XCTAssertEqual(retained.files["index.html"], html)
        XCTAssertEqual(Set(try WorkbenchContainedAuthoring(workspace: restored)
            .versions(edited.project.projectId).map(\.sourceVersion)),
            Set([project.sourceVersion, edited.sourceVersion]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalMachine.path + "/bootstrap.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshMachine.path + "/bootstrap.json"))
    }
}
#endif
