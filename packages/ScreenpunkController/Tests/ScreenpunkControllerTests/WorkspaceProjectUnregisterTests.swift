import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct UnregisterDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkspaceProjectUnregisterTests: XCTestCase {
    private func fixture() throws -> (URL, WorkspaceStore) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-unregister-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: UnregisterDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        return (root, store)
    }

    func testContainedUnregisterRetainsFolderAndHistoryAndCanReopen() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let authoring = WorkbenchContainedAuthoring(workspace: store)
        let created = try authoring.create(name: "Keep bytes", kind: "web", trustedKitVersion: "kit-1")
        let before = try XCTUnwrap(store.current())
        let descriptor = URL(fileURLWithPath: created.path).appendingPathComponent("screenpunk.project.json")
        let original = try Data(contentsOf: descriptor)
        let history = root.appendingPathComponent("visible/Workbench/History/Builds/\(created.sourceVersion)/source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertThrowsError(try store.unregisterProject(created.project.projectId,
            expectedCatalogGeneration: before.catalog.generation - 1)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        let removed = try store.unregisterProject(created.project.projectId,
            expectedCatalogGeneration: before.catalog.generation)
        XCTAssertTrue(removed.catalog.projects.isEmpty)
        XCTAssertEqual(removed.descriptor.generation, before.descriptor.generation + 1)
        XCTAssertEqual(try Data(contentsOf: descriptor), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertThrowsError(try store.unregisterProject(created.project.projectId,
            expectedCatalogGeneration: removed.catalog.generation))
        let reopened = try authoring.openContained(at: created.path)
        XCTAssertEqual(reopened.project.projectId, created.project.projectId)
        XCTAssertEqual(reopened.sourceVersion, created.sourceVersion)
    }

    func testExternalUnregisterClearsLocalBindingAndRetainsOriginal() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try WorkbenchContainedAuthoring(workspace: store).create(
            name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("outside")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: created.path), to: external)
        let descriptor = external.appendingPathComponent("screenpunk.project.json")
        let old = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptor))
        let rewritten = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "External", kind: old.kind, kitVersion: old.kitVersion,
            entry: old.entry, screenConfig: old.screenConfig)
        try WorkspaceJSON.encode(rewritten).write(to: descriptor)
        let project = try WorkbenchPortableSourceArchive(workspace: store)
            .openExternal(at: external.path, explicitExternal: true)
        let before = try XCTUnwrap(store.current())
        let reference = try XCTUnwrap(project.location.referenceId)
        XCTAssertNotNil(try store.selection.current()?.externalBindings[reference])
        let removed = try store.unregisterProject(project.projectId,
            expectedCatalogGeneration: before.catalog.generation)
        XCTAssertNil(removed.catalog.projects.first(where: { $0.projectId == project.projectId }))
        XCTAssertNil(try store.selection.current()?.externalBindings[reference])
        XCTAssertEqual(try Data(contentsOf: descriptor), try WorkspaceJSON.encode(rewritten))
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: store)
            .get(created.project.projectId).sourceVersion, created.sourceVersion)
    }

    func testPostCommitReadFailureReportsAppliedOutcomeForUnregister() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try WorkbenchContainedAuthoring(workspace: store).create(
            name: "Retain", kind: "web", trustedKitVersion: "kit-1")
        let before = try XCTUnwrap(store.current())
        let failingReadStore = try WorkspaceStore(
            documents: UnregisterDocuments(path: root.appendingPathComponent("Documents")),
            machineRootPath: root.appendingPathComponent("machine").path,
            postCommitReadGate: { throw WorkspaceError.unavailable })
        XCTAssertThrowsError(try failingReadStore.unregisterProject(created.project.projectId,
            expectedCatalogGeneration: before.catalog.generation)) {
            XCTAssertEqual($0 as? WorkspaceAppliedMutationReadUnavailable,
                .init(operation: "projectUnregister", workspaceId: before.descriptor.workspaceId,
                    projectId: created.project.projectId))
        }
        let after = try XCTUnwrap(store.current())
        XCTAssertNil(after.catalog.projects.first { $0.projectId == created.project.projectId })
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }
}
#endif
