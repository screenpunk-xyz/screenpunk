import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct PackageRenameDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchScreenPackageRenameDomainTests: XCTestCase {
    func testOrientationSupportCreatesNewTargetCompatibleRevision() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-package-orient-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: PackageRenameDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        let bytes = Data("<html>portrait</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Orient",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 390, height: 844, scale: 1,
                orientation: "portrait"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: bytes.count,
                sha256: DeploymentDigest.sha256Hex(bytes))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: store)
        _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": bytes]))
        let before = try XCTUnwrap(store.current())
        let raw: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": manifest.dashboardId, "expectedRevision": manifest.revision,
            "expectedDigest": try XCTUnwrap(manifest.digest), "support": "landscape"]
        let request = try WorkbenchScreenPackageOrientationRequest.parse(raw)
        let changed = try WorkbenchScreenPackageOrientationDomain(workspace: store).set(request)
        let old = try packages.get(dashboardId: manifest.dashboardId, revision: manifest.revision)
        let updated = try packages.get(dashboardId: manifest.dashboardId, revision: changed.revision)
        XCTAssertEqual(old.manifest, manifest)
        XCTAssertNil(old.files[ScreenDesignSettings.path])
        XCTAssertEqual(updated.manifest.target.orientation, "landscape")
        XCTAssertEqual(updated.manifest.target.width, 844)
        XCTAssertEqual(updated.manifest.target.height, 390)
        XCTAssertEqual(try ScreenDesignSettings.read(files: updated.files).orientations, .landscape)
        XCTAssertEqual(updated.files["index.html"], bytes)
        XCTAssertEqual(updated.manifest.digest, changed.digest)
        XCTAssertThrowsError(try WorkbenchScreenPackageOrientationDomain(workspace: store)
            .set(request)) { XCTAssertEqual($0 as? WorkspaceError, .conflict) }
        var injected = raw; injected["role"] = "gui"
        XCTAssertThrowsError(try WorkbenchScreenPackageOrientationRequest.parse(injected))
        injected = raw; injected["expectedCatalogGeneration"] = true
        XCTAssertThrowsError(try WorkbenchScreenPackageOrientationRequest.parse(injected))
    }

    func testDuplicateUsesNewIdentityAndKeepsSourcePackageUntouched() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-package-copy-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: PackageRenameDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        let bytes = Data("<html>copy</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Original",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: bytes.count,
                sha256: DeploymentDigest.sha256Hex(bytes))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: store)
        _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": bytes]))
        let before = try XCTUnwrap(store.current())
        let request = try WorkbenchScreenPackageDuplicateRequest.parse([
            "schemaVersion": 1, "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": manifest.dashboardId, "expectedRevision": manifest.revision,
            "expectedDigest": try XCTUnwrap(manifest.digest), "name": "Original Copy"])
        let copied = try WorkbenchScreenPackageDuplicateDomain(workspace: store).duplicate(request)
        XCTAssertNotEqual(copied.dashboardId, manifest.dashboardId)
        XCTAssertNotEqual(copied.revision, manifest.revision)
        XCTAssertEqual(copied.sourceDashboardId, manifest.dashboardId)
        XCTAssertEqual(try packages.get(dashboardId: manifest.dashboardId,
            revision: manifest.revision).manifest, manifest)
        let copy = try packages.get(dashboardId: copied.dashboardId, revision: copied.revision)
        XCTAssertEqual(copy.files["index.html"], bytes)
        XCTAssertEqual(copy.manifest.name, "Original Copy")
        XCTAssertEqual(copy.manifest.digest, copied.digest)
        XCTAssertEqual(try packages.list().count, 2)
        XCTAssertThrowsError(try WorkbenchScreenPackageDuplicateDomain(workspace: store)
            .duplicate(request)) { XCTAssertEqual($0 as? WorkspaceError, .conflict) }
    }

    func testPackageOnlyRenamePublishesNewRevisionAndPreservesOriginal() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-package-rename-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: PackageRenameDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        let files = ["index.html": Data("<html>original</html>".utf8)]
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Original",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: files["index.html"]!.count,
                sha256: DeploymentDigest.sha256Hex(files["index.html"]!))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: store)
        _ = try packages.importVerified(.init(manifest: manifest, files: files))
        let before = try XCTUnwrap(store.current())
        let raw: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": manifest.dashboardId, "expectedRevision": manifest.revision,
            "expectedDigest": try XCTUnwrap(manifest.digest), "name": "Renamed"]
        let request = try WorkbenchScreenPackageRenameRequest.parse(raw)
        let result = try WorkbenchScreenPackageRenameDomain(workspace: store).rename(request)
        XCTAssertEqual(result.dashboardId, manifest.dashboardId)
        XCTAssertEqual(result.priorRevision, manifest.revision)
        XCTAssertNotEqual(result.revision, manifest.revision)
        XCTAssertEqual(result.catalogGeneration, before.descriptor.generation + 1)
        let old = try packages.get(dashboardId: manifest.dashboardId, revision: manifest.revision)
        let renamed = try packages.get(dashboardId: manifest.dashboardId, revision: result.revision)
        XCTAssertEqual(old.manifest, manifest)
        XCTAssertEqual(old.files, files)
        XCTAssertEqual(renamed.manifest.name, "Renamed")
        XCTAssertEqual(renamed.manifest.dashboardId, manifest.dashboardId)
        XCTAssertEqual(renamed.files, files)
        XCTAssertEqual(renamed.manifest.digest, result.digest)
        XCTAssertEqual(try packages.list().count, 2)
        XCTAssertThrowsError(try WorkbenchScreenPackageRenameDomain(workspace: store).rename(request)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try store.current()?.descriptor.generation,
            before.descriptor.generation + 1)

        var injected = raw; injected["role"] = "gui"
        XCTAssertThrowsError(try WorkbenchScreenPackageRenameRequest.parse(injected))
        injected = raw; injected["expectedCatalogGeneration"] = true
        XCTAssertThrowsError(try WorkbenchScreenPackageRenameRequest.parse(injected))
    }
}
#endif
