import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct ArchiveDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchScreenArchiveAssociationTests: XCTestCase {
    func testLegacyCatalogDecodesAndV2RequiresClosedTombstones() throws {
        let v1 = Data("{\"schemaVersion\":1,\"generation\":1,\"projects\":[]}".utf8)
        let old = try WorkspaceJSON.decode(WorkspaceCatalog.self, from: v1, shape: .catalog)
        XCTAssertEqual(old.archivedDashboardIds, [])
        let upgraded = WorkspaceCatalog(generation: 2, projects: [],
            archivedDashboardIds: ["screen-1"])
        let bytes = try WorkspaceJSON.encode(upgraded)
        XCTAssertEqual(try WorkspaceJSON.decode(WorkspaceCatalog.self,
            from: bytes, shape: .catalog).archivedDashboardIds, ["screen-1"])
        let malformed = Data("{\"schemaVersion\":2,\"generation\":2,\"projects\":[]}".utf8)
        XCTAssertThrowsError(try WorkspaceJSON.decode(WorkspaceCatalog.self,
            from: malformed, shape: .catalog))
    }

    private func fixture() throws -> (URL, WorkspaceStore, WorkbenchContainedAuthoring) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-screen-archive-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: ArchiveDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        return (root, store, WorkbenchContainedAuthoring(workspace: store))
    }

    private func package(_ store: WorkspaceStore, dashboardId: String = UUID().uuidString.lowercased()) throws
        -> WorkbenchPortablePackage {
        let bytes = Data("<!doctype html><title>Stored</title>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: dashboardId, name: "Stored", revision: UUID().uuidString.lowercased(),
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: bytes.count,
                sha256: DeploymentDigest.sha256Hex(bytes))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let value = WorkbenchPortablePackage(manifest: manifest, files: ["index.html": bytes])
        _ = try WorkbenchPortablePackages(workspace: store).importVerified(value)
        return value
    }

    func testArchiveRetainsSourcePackageAndHistoryAcrossFurtherPublication() throws {
        let (root, store, authoring) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try authoring.create(name: "Source", kind: "react", trustedKitVersion: "kit-1")
        let exact = try package(store, dashboardId: source.project.dashboardId)
        let before = try XCTUnwrap(store.current())
        let request = try WorkbenchScreenArchiveRequest.parse([
            "schemaVersion": 1, "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": exact.manifest.dashboardId,
            "expectedRevision": exact.manifest.revision,
            "expectedDigest": try XCTUnwrap(exact.manifest.digest)])
        let result = try WorkbenchScreenArchiveDomain(workspace: store).archive(request)
        XCTAssertTrue(result.sourceRetained)
        XCTAssertTrue(result.packageHistoryRetained)
        XCTAssertTrue(result.deviceContentsUntouched)
        XCTAssertEqual(result.catalogGeneration, before.descriptor.generation + 1)
        XCTAssertTrue(try WorkbenchScreenArchiveDomain(workspace: store).visiblePackageManifests().isEmpty)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: store).get(
            dashboardId: exact.manifest.dashboardId, revision: exact.manifest.revision).files,
            exact.files)
        XCTAssertEqual(try authoring.get(source.project.projectId).sourceVersion, source.sourceVersion)
        XCTAssertEqual(try authoring.versions(source.project.projectId).count, 1)
        XCTAssertThrowsError(try WorkbenchScreenArchiveDomain(workspace: store).archive(request)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        _ = try package(store)
        XCTAssertEqual(try store.current()?.catalog.archivedDashboardIds, [exact.manifest.dashboardId])
        XCTAssertEqual(try WorkbenchScreenArchiveDomain(workspace: store).visiblePackageManifests().count, 1)
        let copy = root.appendingPathComponent("portable-copy")
        try FileManager.default.copyItem(at: root.appendingPathComponent("visible"), to: copy)
        let restored = try WorkspaceStore(documents: ArchiveDocuments(url: root.appendingPathComponent("Documents")),
            machineRootPath: root.appendingPathComponent("other-machine").path)
        let opened = try restored.open(at: copy.path)
        XCTAssertEqual(opened.catalog.archivedDashboardIds, [exact.manifest.dashboardId])
        XCTAssertEqual(opened.catalog.projects.first?.projectId, source.project.projectId)
        XCTAssertEqual(try WorkbenchScreenArchiveDomain(workspace: restored).visiblePackageManifests().count, 1)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: restored).get(
            dashboardId: exact.manifest.dashboardId, revision: exact.manifest.revision).files,
            exact.files)
    }

    func testSourceOnlyArchiveAndWebAssociationRejection() throws {
        let (root, store, authoring) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try authoring.create(name: "Web", kind: "web", trustedKitVersion: "kit-1")
        let before = try XCTUnwrap(store.current())
        let fields: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": source.project.dashboardId,
            "projectId": source.project.projectId,
            "expectedSourceVersion": source.sourceVersion]
        let archive = try WorkbenchScreenArchiveRequest.parse(fields)
        let result = try WorkbenchScreenArchiveDomain(workspace: store).archive(archive)
        XCTAssertTrue(result.sourceRetained)
        XCTAssertEqual(try authoring.get(source.project.projectId).sourceVersion, source.sourceVersion)
        XCTAssertEqual(try store.current()?.catalog.archivedDashboardIds,
            [source.project.dashboardId])
        let exact = try package(store)
        let later = try XCTUnwrap(store.current())
        let attach = try WorkbenchReactSourceAssociationRequest.parse([
            "schemaVersion": 1, "expectedWorkspaceId": later.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(later.selectionGeneration),
            "expectedCatalogGeneration": later.descriptor.generation,
            "projectId": source.project.projectId,
            "expectedSourceVersion": source.sourceVersion,
            "dashboardId": exact.manifest.dashboardId,
            "expectedRevision": exact.manifest.revision,
            "expectedDigest": try XCTUnwrap(exact.manifest.digest)])
        XCTAssertThrowsError(try WorkbenchReactSourceAssociationDomain(workspace: store).attach(attach)) {
            XCTAssertEqual($0 as? WorkspaceError, .invalidSchema)
        }
    }

    func testArchiveReportsAppliedWhenPostCommitReadFails() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-screen-archive-postcommit-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var reject = false
        let store = try WorkspaceStore(documents: ArchiveDocuments(url: docs),
            machineRootPath: root.appendingPathComponent("machine").path,
            postCommitReadGate: { if reject { throw WorkspaceError.unavailable } })
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        let exact = try package(store)
        let before = try XCTUnwrap(store.current())
        let request = try WorkbenchScreenArchiveRequest.parse([
            "schemaVersion": 1, "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "dashboardId": exact.manifest.dashboardId,
            "expectedRevision": exact.manifest.revision,
            "expectedDigest": try XCTUnwrap(exact.manifest.digest)])
        reject = true
        XCTAssertThrowsError(try WorkbenchScreenArchiveDomain(workspace: store).archive(request)) {
            XCTAssertEqual(($0 as? WorkspaceAppliedMutationReadUnavailable)?.operation,
                "screenArchive")
        }
        XCTAssertEqual(try store.current()?.catalog.archivedDashboardIds,
            [exact.manifest.dashboardId])
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: store).get(
            dashboardId: exact.manifest.dashboardId, revision: exact.manifest.revision).files,
            exact.files)
    }

    func testReactAssociationVerifiesExactPackageAndRetainsPriorSource() throws {
        let (root, store, authoring) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try authoring.create(name: "React", kind: "react", trustedKitVersion: "kit-1")
        let oldDescriptor = try Data(contentsOf: URL(fileURLWithPath: source.path)
            .appendingPathComponent("screenpunk.project.json"))
        let exact = try package(store)
        let before = try XCTUnwrap(store.current())
        let fields: [String: Any] = [
            "schemaVersion": 1, "expectedWorkspaceId": before.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(before.selectionGeneration),
            "expectedCatalogGeneration": before.descriptor.generation,
            "projectId": source.project.projectId,
            "expectedSourceVersion": source.sourceVersion,
            "dashboardId": exact.manifest.dashboardId,
            "expectedRevision": exact.manifest.revision,
            "expectedDigest": try XCTUnwrap(exact.manifest.digest)]
        let request = try WorkbenchReactSourceAssociationRequest.parse(fields)
        let result = try WorkbenchReactSourceAssociationDomain(workspace: store).attach(request)
        XCTAssertEqual(result.project.project.dashboardId, exact.manifest.dashboardId)
        XCTAssertNotEqual(result.project.sourceVersion, source.sourceVersion)
        XCTAssertFalse(result.authorityRestored)
        XCTAssertEqual(result.packageRevision, exact.manifest.revision)
        let oldHistory = root.appendingPathComponent(
            "visible/Workbench/History/Builds/\(source.sourceVersion)/source/screenpunk.project.json")
        XCTAssertEqual(try Data(contentsOf: oldHistory), oldDescriptor)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: store).get(
            dashboardId: exact.manifest.dashboardId, revision: exact.manifest.revision).files,
            exact.files)
        XCTAssertThrowsError(try WorkbenchReactSourceAssociationDomain(workspace: store).attach(request)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
    }

    func testPackageImporterRejectsOriginalGenerationAfterIndependentMutation() throws {
        let (root, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try package(store)
        let before = try XCTUnwrap(store.current())
        let second = try package(store)
        let manifest = second.manifest
        XCTAssertThrowsError(try WorkbenchPortablePackages(workspace: store).importVerified(
            .init(manifest: manifest, files: second.files),
            expectedWorkspaceId: before.descriptor.workspaceId,
            expectedSelectionGeneration: before.selectionGeneration,
            expectedCatalogGeneration: before.descriptor.generation)) {
                XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: store).get(
            dashboardId: first.manifest.dashboardId, revision: first.manifest.revision).files,
            first.files)
    }
}
#endif
