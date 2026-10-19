import Foundation
import XCTest
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct WebContentDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class PackageWebContentValidationTests: XCTestCase {
    func testRejectedInlineUpdateKeepsExistingPackageAndHead() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sp-web-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DashboardPackageStore(root: root)
        let target = ManifestTarget(profileId: "fixture", width: 420, height: 912,
            scale: 1, orientation: "portrait", safeArea: nil)
        let first = try store.putDashboard(dashboardId: nil, name: "Fixture", baseRevision: nil,
            target: target, connections: [], files: [.init(path: "index.html", text: "<p>Original</p>", base64: nil)])
        XCTAssertThrowsError(try store.putDashboard(dashboardId: first.manifest.dashboardId,
            name: "Fixture", baseRevision: first.manifest.revision, target: target, connections: [],
            files: [.init(path: "index.html", text: "<style>body{color:red}</style><script>run()</script>", base64: nil)])) {
            XCTAssertEqual(($0 as? ControllerError)?.code, .validationFailed)
            XCTAssertTrue(String(describing: $0).contains("styles.css"))
        }
        XCTAssertEqual(try store.getRevision(dashboardId: first.manifest.dashboardId, revision: nil).manifest.revision, first.manifest.revision)
        XCTAssertEqual(try store.listRevisions(dashboardId: first.manifest.dashboardId), [first.manifest.revision])
    }

    func testWebTemplateAndBuildUseLocalAssetsAndRejectedBuildKeepsHead() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sp-web-build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: WebContentDocuments(url: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: {})
        var project = try XCTUnwrap(domain.perform(.projectCreate(name: "Fixture", kind: "web")).project)
        let id = project.project.projectId
        let first = try XCTUnwrap(domain.perform(.buildRun(id: id, expectedSourceVersion: project.sourceVersion, baseRevision: nil)).build)
        let package = try WorkbenchPortablePackages(workspace: workspace).get(dashboardId: project.project.dashboardId, revision: first.revision)
        XCTAssertNotNil(package.files["styles.css"])
        XCTAssertNotNil(package.files["app.js"])
        XCTAssertTrue(PackageWebContentDiagnostics.inspect(files: package.files).isEmpty)
        project = try XCTUnwrap(domain.perform(.projectPatch(id: id,
            expectedSourceVersion: project.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<style>body{color:red}</style><p>0</p><script>tick()</script>".utf8))])).project)
        XCTAssertThrowsError(try domain.perform(.buildRun(id: id,
            expectedSourceVersion: project.sourceVersion, baseRevision: first.revision)))
        XCTAssertEqual(try domain.perform(.buildHead(id: id)).build?.revision, first.revision)
    }

    func testPreparedPackageFreezeRejectsAuthenticatedInlineBytesBeforeTransfer() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sp-web-freeze-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: WebContentDocuments(url: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        let files = ["index.html": Data("<style>body{color:red}</style>".utf8)]
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(),
            name: "Fixture", revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "fixture", width: 420, height: 912, scale: 1,
                orientation: "portrait", safeArea: nil), connections: [],
            files: [ManifestFile(path: "index.html", bytes: files["index.html"]!.count,
                sha256: DeploymentDigest.sha256Hex(files["index.html"]!))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let prepared = WorkbenchPreparedPackage(sourceRevision: UUID().uuidString.lowercased(), manifest: manifest, files: files)
        XCTAssertThrowsError(try WorkbenchPreparedPackages(workspace: workspace).freeze(prepared,
            deviceId: "fixture", dataDescription: "No connections")) {
            XCTAssertEqual(($0 as? ControllerError)?.code, .validationFailed)
        }
    }
}
#endif
