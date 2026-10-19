import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct ImportDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkbenchBoundedPackageImportTests: XCTestCase {
    func testExportParentSyncFailureReportsPublishedDestinationWithUncertainDurability() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-package-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: ImportDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let html = Data("<html>published</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Exported package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html]))
        let destination = root.appendingPathComponent("published-package")
        var called = false
        let exporter = WorkbenchPortablePackageArchive(workspace: workspace,
            syncPublishedParent: { _ in called = true; return -1 })
        XCTAssertThrowsError(try exporter.export(dashboardId: manifest.dashboardId,
            revision: manifest.revision, to: destination.path)) { error in
            let uncertain = error as? WorkbenchPortablePackageExportPublicationUncertain
            XCTAssertEqual(uncertain?.receipt.path, destination.path)
            XCTAssertEqual(uncertain?.receipt.digest, manifest.digest)
        }
        XCTAssertTrue(called)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try WorkbenchPortablePackageArchive(workspace: workspace)
            .readVerified(from: destination.path).files["index.html"], html)
        let staged = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".screenpunk-package-export-") }
        XCTAssertTrue(staged.isEmpty)
    }

    func testExportVerifiedHistoricalPackageAsImportableDirectory() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-package-export-" + UUID().uuidString.prefix(10))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: ImportDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let selected = try XCTUnwrap(workspace.current())
        let html = Data("<html>historical package</html>".utf8)
        let image = Data([0, 1, 2, 3])
        let runtimeManifest = Data("{\"runtime\":true}".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Exported package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html)),
                ManifestFile(path: "assets/icon.bin", bytes: image.count,
                sha256: DeploymentDigest.sha256Hex(image)),
                ManifestFile(path: "manifest.json", bytes: runtimeManifest.count,
                sha256: DeploymentDigest.sha256Hex(runtimeManifest))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": html, "assets/icon.bin": image,
                "manifest.json": runtimeManifest]))
        let destination = root.appendingPathComponent("package-export")
        let receipt = try WorkbenchPortablePackageArchive(workspace: workspace).export(
            dashboardId: manifest.dashboardId, revision: manifest.revision, to: destination.path)
        XCTAssertEqual(receipt.path, destination.path)
        XCTAssertEqual(receipt.digest, manifest.digest)
        XCTAssertEqual(receipt.fileCount, 3)
        XCTAssertEqual(receipt.includedBytes, html.count + image.count + runtimeManifest.count)
        let envelope = try JSONDecoder().decode(WorkbenchPortablePackageArchiveEnvelope.self,
            from: Data(contentsOf: destination.appendingPathComponent("package-archive.json")))
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.kind, "immutable-runtime-package")
        XCTAssertEqual(envelope.digest, manifest.digest)
        XCTAssertEqual(try JSONDecoder().decode(DashboardManifest.self,
            from: Data(contentsOf: destination.appendingPathComponent("manifest.json"))), manifest)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("files/index.html")), html)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("files/assets/icon.bin")), image)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("files/manifest.json")),
            runtimeManifest)
        let roundTrip = try WorkbenchPortablePackageArchive(workspace: workspace)
            .readVerified(from: destination.path)
        XCTAssertEqual(roundTrip.manifest, manifest)
        XCTAssertEqual(roundTrip.files["manifest.json"], runtimeManifest)
        XCTAssertEqual(try workspace.current()?.selectionGeneration, selected.selectionGeneration)
        XCTAssertThrowsError(try WorkbenchPortablePackageArchive(workspace: workspace).export(
            dashboardId: manifest.dashboardId, revision: manifest.revision, to: destination.path)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("files/index.html")), html)
        let unlisted = destination.appendingPathComponent("unlisted")
        try FileManager.default.createDirectory(at: unlisted, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WorkbenchPortablePackageArchive(workspace: workspace)
            .readVerified(from: destination.path))
        try FileManager.default.removeItem(at: unlisted)
        try Data("changed".utf8).write(to: destination.appendingPathComponent("files/manifest.json"))
        XCTAssertThrowsError(try WorkbenchPortablePackageArchive(workspace: workspace)
            .readVerified(from: destination.path))
    }

    func testImmutablePackageImportRetainsBytesWithoutRestoringAuthority() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-package-import-" + UUID().uuidString.prefix(10))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: ImportDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let selected = try XCTUnwrap(workspace.current())
        let generation = try XCTUnwrap(selected.selectionGeneration)
        let file = Data("<html>retained original</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Imported package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let package = WorkbenchPortablePackage(manifest: manifest, files: ["index.html": file])
        let request = try WorkbenchBoundedPackageImportRequest(
            expectedWorkspaceId: selected.descriptor.workspaceId,
            expectedSelectionGeneration: generation,
            expectedDigest: try XCTUnwrap(manifest.digest), package: package)
        let importer = WorkbenchBoundedPackageImport(workspace: workspace)
        let receipt = try importer.perform(request)
        XCTAssertEqual(receipt.digest, manifest.digest)
        XCTAssertEqual(receipt.includedBytes, file.count)
        XCTAssertEqual(receipt.provenance, "imported-package-untrusted")
        XCTAssertFalse(receipt.editableSourceIncluded)
        XCTAssertFalse(receipt.localBindingsImported)
        XCTAssertEqual(receipt.deploymentAuthority, "none")
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: manifest.dashboardId, revision: manifest.revision).files["index.html"], file)
        XCTAssertEqual(try importer.perform(request), receipt)
        var changed = manifest
        changed.name = "Different historical bytes"
        changed.digest = try DeploymentDigest.digest(for: changed)
        let collision = try WorkbenchBoundedPackageImportRequest(
            expectedWorkspaceId: selected.descriptor.workspaceId,
            expectedSelectionGeneration: generation,
            expectedDigest: try XCTUnwrap(changed.digest),
            package: WorkbenchPortablePackage(manifest: changed, files: ["index.html": file]))
        XCTAssertThrowsError(try importer.perform(collision)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: manifest.dashboardId, revision: manifest.revision).manifest, manifest)
        XCTAssertThrowsError(try WorkbenchBoundedPackageImportRequest(
            expectedWorkspaceId: selected.descriptor.workspaceId,
            expectedSelectionGeneration: generation,
            expectedDigest: String(repeating: "0", count: 64), package: package))
        _ = try workspace.create(at: root.appendingPathComponent("other-visible").path)
        XCTAssertThrowsError(try importer.perform(request)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
    }
}
#endif
