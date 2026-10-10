import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct SnapshotDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkspaceSnapshotTests: XCTestCase {
    func testCaseVariantScreenUsesFilesystemIdentityForCoverage() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-snapshot-case-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: SnapshotDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let original = base.appendingPathComponent("original")
        _ = try workspace.create(at: original.path)
        let created = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "draft", kind: "web", trustedKitVersion: "1.0.0")
        let lower = original.appendingPathComponent("Screens/draft")
        let upper = original.appendingPathComponent("Screens/Draft")
        let probe = base.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let one = probe.appendingPathComponent("one")
        let alternate = probe.appendingPathComponent("One")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: false)
        let caseSensitive: Bool
        do {
            try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
            caseSensitive = true
        } catch { caseSensitive = false }
        if caseSensitive {
            try FileManager.default.copyItem(at: lower, to: upper)
            XCTAssertThrowsError(try WorkspaceSnapshot(workspace: workspace).create(
                at: base.appendingPathComponent("refused").path))
            let partial = try WorkspaceSnapshot(workspace: workspace).create(
                at: base.appendingPathComponent("partial").path, allowIncomplete: true)
            XCTAssertEqual(partial.unregisteredScreenPaths, ["Screens/Draft"])
            XCTAssertFalse(partial.complete)
        } else {
            try FileManager.default.moveItem(at: lower, to: upper)
            XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: workspace).get(
                created.project.projectId).sourceVersion, created.sourceVersion)
            let result = try WorkspaceSnapshot(workspace: workspace).create(
                at: base.appendingPathComponent("complete").path)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.unregisteredScreenPaths, [])
            XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent(
                "complete/Screens/draft/web/index.html")),
                try Data(contentsOf: upper.appendingPathComponent("web/index.html")))
        }
    }

    func testUnregisteredUsableScreenIsReportedAndRequiresIncompleteOptIn() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-snapshot-unregistered-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: SnapshotDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let original = base.appendingPathComponent("original")
        _ = try workspace.create(at: original.path)
        let root = try WorkspaceFiles(path: original.path)
        let draft = try root.directory(["Screens", "draft"], create: true)
        let projectID = UUID().uuidString.lowercased()
        let dashboardID = UUID().uuidString.lowercased()
        let document = WorkspaceProjectDocument(schemaVersion: 1, projectId: projectID,
            dashboardId: dashboardID, name: "Draft", kind: "web", kitVersion: "1.0.0",
            entry: "web/index.html", screenConfig: "screen.json")
        try root.write(draft, "screenpunk.project.json", data: WorkspaceJSON.encode(document), expected: nil)
        try root.write(draft, "screen.json", data: Data("{\"name\":\"Draft\"}".utf8), expected: nil)
        close(draft)
        let web = try root.directory(["Screens", "draft", "web"], create: true)
        try root.write(web, "index.html", data: Data("<html>draft</html>".utf8), expected: nil)
        close(web)
        let exporter = WorkspaceSnapshot(workspace: workspace)
        XCTAssertThrowsError(try exporter.create(at: base.appendingPathComponent("refused").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("refused").path))
        let partial = try exporter.create(at: base.appendingPathComponent("partial").path,
                                          allowIncomplete: true)
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.unregisteredScreenPaths, ["Screens/draft"])
        XCTAssertTrue(partial.omittedAuxiliaryPaths.contains("Screens/draft"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            base.appendingPathComponent("partial/Screens/draft").path))
        _ = try WorkbenchContainedAuthoring(workspace: workspace).openContained(
            at: original.appendingPathComponent("Screens/draft").path)
        let complete = try exporter.create(at: base.appendingPathComponent("complete").path)
        XCTAssertTrue(complete.complete)
        XCTAssertEqual(complete.unregisteredScreenPaths, [])
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("complete/Screens/draft/web/index.html")),
                       Data("<html>draft</html>".utf8))
    }

    func testExternalCoverageRequiresExplicitIncompleteOrCopiedSource() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-snapshot-external-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: SnapshotDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        _ = try workspace.create(at: base.appendingPathComponent("visible").path)
        let externalPath = base.appendingPathComponent("external")
        let external = try WorkspaceFiles(path: externalPath.path, create: true)
        let project = WorkspaceProject(projectId: UUID().uuidString.lowercased(),
            dashboardId: UUID().uuidString.lowercased(), name: "External",
            location: .external(UUID().uuidString.lowercased()))
        let document = WorkspaceProjectDocument(schemaVersion: 1, projectId: project.projectId,
            dashboardId: project.dashboardId, name: project.name, kind: "web", kitVersion: "1.0.0",
            entry: "web/index.html", screenConfig: "screen.json")
        try external.write(external.fd, "screenpunk.project.json", data: WorkspaceJSON.encode(document), expected: nil)
        try external.write(external.fd, "screen.json", data: Data("{}".utf8), expected: nil)
        let web = try external.directory(["web"], create: true); defer { close(web) }
        try external.write(web, "index.html", data: Data("<html>external</html>".utf8), expected: nil)
        _ = try workspace.registerExternal(project, sourcePath: externalPath.path,
            explicitExternal: true, expectedCatalogGeneration: 1)
        let snapshot = WorkspaceSnapshot(workspace: workspace)
        XCTAssertThrowsError(try snapshot.create(at: base.appendingPathComponent("denied").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: base.path)
            .contains(where: { $0.hasPrefix(".screenpunk-snapshot-") }))
        let partial = try snapshot.create(at: base.appendingPathComponent("partial").path,
                                          allowIncomplete: true)
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.excludedExternalProjectIds, [project.projectId])
        let complete = try snapshot.create(at: base.appendingPathComponent("complete").path,
                                           includeExternal: true)
        XCTAssertTrue(complete.complete)
        let fresh = try WorkspaceStore(documents: SnapshotDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("fresh-machine").path)
        _ = try fresh.open(at: complete.path)
        let copied = try WorkbenchContainedAuthoring(workspace: fresh).get(project.projectId)
        XCTAssertTrue(copied.path.contains("/Screens/external-"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied.path + "/web/index.html")),
                       Data("<html>external</html>".utf8))
        XCTAssertEqual(try Data(contentsOf: externalPath.appendingPathComponent("web/index.html")),
                       Data("<html>external</html>".utf8))
    }

    func testSnapshotIsOpenableAndPreservesPortableAuthoringObjects() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: SnapshotDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let original = base.appendingPathComponent("original")
        _ = try workspace.create(at: original.path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let one = try authoring.create(name: "One", kind: "web", trustedKitVersion: "1.0.0")
        let two = try authoring.create(name: "Two", kind: "react", trustedKitVersion: "1.0.0")
        let edited = try authoring.patch(one.project.projectId, expectedSourceVersion: one.sourceVersion,
            changes: [.init(path: "data/demo.json", bytes: Data("{\"demo\":1}".utf8))])
        let root = try WorkspaceFiles(path: original.path)
        let attachments = try root.directory(["Workbench", "Attachments", "notes"], create: true)
        defer { close(attachments) }
        try root.write(attachments, "readme.txt", data: Data("user note".utf8), expected: nil)
        let pin = Data("{\"schemaVersion\":1,\"required\":[]}".utf8)
        let toolchains = try root.directory(["Workbench", "Toolchains"]); defer { close(toolchains) }
        let pinID = WorkspaceNodeID(try root.metadata(toolchains, "requirements.json"))
        try root.write(toolchains, "requirements.json", data: pin, expected: pinID)
        let html = Data("<html>retained</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: one.project.dashboardId,
            name: "Retained", revision: UUID().uuidString.lowercased(), entrypoint: "index.html",
            sdkVersion: "1", target: ManifestTarget(profileId: "test", width: 390, height: 844,
                scale: 1, orientation: "portrait"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let output = base.appendingPathComponent("snapshot")
        let result = try WorkspaceSnapshot(workspace: workspace).create(at: output.path)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.excludedExternalProjectIds, [])
        XCTAssertEqual(result.workspaceId, try XCTUnwrap(workspace.current()).descriptor.workspaceId)
        XCTAssertThrowsError(try WorkspaceSnapshot(workspace: workspace).create(at: output.path))
        let fresh = try WorkspaceStore(documents: SnapshotDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("fresh-machine").path)
        _ = try fresh.open(at: output.path)
        let restored = WorkbenchContainedAuthoring(workspace: fresh)
        XCTAssertEqual(try restored.get(one.project.projectId).sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try restored.get(two.project.projectId).sourceVersion, two.sourceVersion)
        XCTAssertEqual(try restored.versions(one.project.projectId).count, 2)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: fresh).get(
            dashboardId: one.project.dashboardId, revision: manifest.revision).files["index.html"], html)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Workbench/Attachments/notes/readme.txt")),
                       Data("user note".utf8))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Workbench/Toolchains/requirements.json")), pin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Workbench/snapshot-manifest.json").path))
    }
}
#endif
