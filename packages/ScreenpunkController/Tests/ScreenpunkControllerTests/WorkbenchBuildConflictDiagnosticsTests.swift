import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct BuildConflictDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchBuildConflictDiagnosticsTests: XCTestCase {
    func testContentGenerationSixSelectionOneAndBuildConflictsStayDistinct() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-build-conflict-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: BuildConflictDocuments(url: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: {})
        var project = try XCTUnwrap(domain.perform(.projectCreate(name: "Phone", kind: "web")).project)
        let id = project.project.projectId
        for index in 0..<4 {
            project = try XCTUnwrap(domain.perform(.projectPatch(id: id,
                expectedSourceVersion: project.sourceVersion,
                changes: [.init(path: "web/index.html", bytes: Data("<html>format \(index)</html>".utf8))])).project)
        }
        let selected = WorkbenchWorkspaceStatus(overview: try workspace.current())
        XCTAssertEqual(selected.generation, 6)
        XCTAssertEqual(selected.selectionGeneration, 1)
        let workspaceId = try XCTUnwrap(selected.workspaceId)
        func request(source: String, base: String? = nil, generation: Int = 1) throws -> WorkbenchAuthoringRecoveryRequest {
            var params: [String: Any] = ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
                "expectedSelectionGeneration": generation, "projectId": id, "expectedSourceVersion": source]
            if let base { params["baseRevision"] = base }
            // Exercise the actual JSON numeric/id roundtrip, not a hand-built enum.
            let bytes = try JSONSerialization.data(withJSONObject: params)
            return try .parse(method: .buildRun, params: WorkbenchWireJSON.object(bytes))
        }
        XCTAssertThrowsError(try domain.perform(request(source: project.sourceVersion, generation: 6))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertThrowsError(try domain.perform(request(source: String(repeating: "0", count: 64)))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .buildSourceConflict)
        }
        let first = try XCTUnwrap(domain.perform(request(source: project.sourceVersion)).build)
        XCTAssertEqual(first.sourceVersion, project.sourceVersion)
        let beforeFormatting = first.revision
        project = try XCTUnwrap(domain.perform(.projectPatch(id: id,
            expectedSourceVersion: project.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>new formatting</html>".utf8))])).project)
        XCTAssertThrowsError(try domain.perform(request(source: project.sourceVersion))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .buildHeadConflict)
        }
        XCTAssertEqual(try domain.perform(.buildHead(id: id)).build?.revision, beforeFormatting)
        let rebuilt = try XCTUnwrap(domain.perform(request(source: project.sourceVersion,
            base: beforeFormatting)).build)
        XCTAssertEqual(rebuilt.sourceVersion, project.sourceVersion)
        XCTAssertNotEqual(rebuilt.revision, first.revision)
        XCTAssertEqual(try workspace.current()?.selectionGeneration, 1)
        XCTAssertEqual(try workspace.current()?.descriptor.workspaceId, workspaceId)
    }
}
#endif
