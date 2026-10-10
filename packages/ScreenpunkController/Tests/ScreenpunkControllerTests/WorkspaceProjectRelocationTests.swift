import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct ProjectRelocationDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkspaceProjectRelocationTests: XCTestCase {
    private func fixture() throws -> (URL, WorkspaceStore, WorkbenchSourceProject) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-project-relocation-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: ProjectRelocationDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        let source = try WorkbenchContainedAuthoring(workspace: store).create(
            name: "Source", kind: "web", trustedKitVersion: "kit-1")
        return (root, store, source)
    }

    func testPreparedCopySwitchesCatalogAndRetainsOriginal() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("visible/Screens/prepared")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: destination)
        let original = try Data(contentsOf: URL(fileURLWithPath: source.path)
            .appendingPathComponent("screenpunk.project.json"))
        let before = try XCTUnwrap(store.current())
        XCTAssertThrowsError(try store.relocateContainedProject(source.project.projectId,
            expectedSourceVersion: String(repeating: "0", count: 64), to: "Screens/prepared",
            expectedCatalogGeneration: before.catalog.generation)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        let moved = try store.relocateContainedProject(source.project.projectId,
            expectedSourceVersion: source.sourceVersion, to: "Screens/prepared",
            expectedCatalogGeneration: before.catalog.generation)
        XCTAssertEqual(moved.catalog.projects.first?.location.path, "Screens/prepared")
        XCTAssertEqual(moved.descriptor.generation, before.descriptor.generation + 1)
        XCTAssertEqual(try store.resolveProject(source.project.projectId), destination.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path)
            .appendingPathComponent("screenpunk.project.json")), original)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("screenpunk.project.json")),
            original)
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: store)
            .get(source.project.projectId).sourceVersion, source.sourceVersion)
    }

    func testManuallyMovedFolderCanBeReboundWithoutAnotherCopy() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try XCTUnwrap(store.current())
        let destination = root.appendingPathComponent("visible/Screens/manually-moved")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: source.path), to: destination)
        let moved = try store.relocateContainedProject(source.project.projectId,
            expectedSourceVersion: source.sourceVersion, to: "Screens/manually-moved",
            expectedCatalogGeneration: before.catalog.generation)
        XCTAssertEqual(moved.catalog.projects.first?.location.path, "Screens/manually-moved")
        XCTAssertEqual(try store.resolveProject(source.project.projectId), destination.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testChangedPreparedFolderDoesNotSwitchCatalog() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("visible/Screens/changed")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: destination)
        try Data("<html>different</html>".utf8).write(to:
            destination.appendingPathComponent("web/index.html"))
        let before = try XCTUnwrap(store.current())
        XCTAssertThrowsError(try store.relocateContainedProject(source.project.projectId,
            expectedSourceVersion: source.sourceVersion, to: "Screens/changed",
            expectedCatalogGeneration: before.catalog.generation)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        let after = try XCTUnwrap(store.current())
        XCTAssertEqual(after.catalog, before.catalog)
        XCTAssertEqual(try store.resolveProject(source.project.projectId), source.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPostCommitReadFailureReportsAppliedOutcomeForRelocation() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("visible/Screens/prepared")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: destination)
        let before = try XCTUnwrap(store.current())
        let failingReadStore = try WorkspaceStore(
            documents: ProjectRelocationDocuments(path: root.appendingPathComponent("Documents")),
            machineRootPath: root.appendingPathComponent("machine").path,
            postCommitReadGate: { throw WorkspaceError.unavailable })
        XCTAssertThrowsError(try failingReadStore.relocateContainedProject(source.project.projectId,
            expectedSourceVersion: source.sourceVersion, to: "Screens/prepared",
            expectedCatalogGeneration: before.catalog.generation)) {
            XCTAssertEqual($0 as? WorkspaceAppliedMutationReadUnavailable,
                .init(operation: "projectRelocate", workspaceId: before.descriptor.workspaceId,
                    projectId: source.project.projectId))
        }
        let after = try XCTUnwrap(store.current())
        XCTAssertEqual(after.catalog.projects.first?.location.path, "Screens/prepared")
        XCTAssertEqual(after.descriptor.generation, before.descriptor.generation + 1)
    }
}
#endif
