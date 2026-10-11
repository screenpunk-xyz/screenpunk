import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct AtomicDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchAtomicSourceCommitTests: XCTestCase {
    private final class Fixture {
        let base: URL
        let visible: URL
        let workspace: WorkspaceStore
        init() throws {
            base = URL(fileURLWithPath: "/private/tmp/sp-atomic-source-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let documents = base.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
            visible = base.appendingPathComponent("visible")
            workspace = try WorkspaceStore(documents: AtomicDocuments(url: documents),
                machineRootPath: base.appendingPathComponent("machine").path)
            _ = try workspace.create(at: visible.path)
        }
        func restored() throws -> WorkspaceStore {
            try WorkspaceStore(documents: AtomicDocuments(url: base.appendingPathComponent("Documents")),
                machineRootPath: base.appendingPathComponent("restored-machine").path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    func testCreateRecoversAsOneGenerationAtHistorySourceAndCatalogCheckpoints() throws {
        let points: [WorkbenchTransactionCheckpoint] = [.journalDurable, .memberPublished(0),
            .memberPublished(4), .memberPublished(8), .generationDurable]
        for point in points {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let interrupted = WorkbenchContainedAuthoring(workspace: fixture.workspace) { current in
                if current == point { throw WorkspaceError.unavailable }
            }
            XCTAssertThrowsError(try interrupted.create(name: "Atomic", kind: "web", trustedKitVersion: "1.0.0"))
            let fresh = try fixture.restored()
            XCTAssertThrowsError(try fresh.open(at: fixture.visible.path))
            let recovery = WorkbenchContainedAuthoring(workspace: fresh)
            XCTAssertEqual(try recovery.recoverContainedBeforeOpen(at: fixture.visible.path).count, 1)
            _ = try fresh.open(at: fixture.visible.path)
            let current = try XCTUnwrap(fresh.current())
            XCTAssertEqual(current.descriptor.generation, 2)
            XCTAssertEqual(current.catalog.generation, 2)
            XCTAssertEqual(current.settings.generation, 2)
            let project = try XCTUnwrap(current.catalog.projects.first)
            let source = try recovery.get(project.projectId)
            XCTAssertEqual(try recovery.versions(project.projectId).map(\.sourceVersion), [source.sourceVersion])
            XCTAssertEqual(try recovery.recoverContainedBeforeOpen(at: fixture.visible.path), [])
        }
    }

    func testEditRecoversSourceAndMatchingHistoryInOneGeneration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let normal = WorkbenchContainedAuthoring(workspace: fixture.workspace)
        let original = try normal.create(name: "Edit", kind: "web", trustedKitVersion: "1.0.0")
        let generation = try XCTUnwrap(fixture.workspace.current()).descriptor.generation
        let interrupted = WorkbenchContainedAuthoring(workspace: fixture.workspace) { point in
            if point == .memberPublished(0) { throw WorkspaceError.unavailable }
        }
        XCTAssertThrowsError(try interrupted.patch(original.project.projectId,
            expectedSourceVersion: original.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>after</html>".utf8))]))
        let fresh = try fixture.restored()
        let recovery = WorkbenchContainedAuthoring(workspace: fresh)
        XCTAssertEqual(try recovery.recoverContainedBeforeOpen(at: fixture.visible.path).count, 1)
        _ = try fresh.open(at: fixture.visible.path)
        let edited = try recovery.get(original.project.projectId)
        XCTAssertNotEqual(edited.sourceVersion, original.sourceVersion)
        let overview = try XCTUnwrap(fresh.current())
        XCTAssertEqual(overview.descriptor.generation, generation + 1)
        XCTAssertEqual(overview.catalog.generation, generation + 1)
        XCTAssertEqual(overview.settings.generation, generation + 1)
        XCTAssertEqual(Set(try recovery.versions(original.project.projectId).map(\.sourceVersion)),
                       Set([original.sourceVersion, edited.sourceVersion]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: edited.path + "/web/index.html")),
                       Data("<html>after</html>".utf8))
    }
}
#endif
