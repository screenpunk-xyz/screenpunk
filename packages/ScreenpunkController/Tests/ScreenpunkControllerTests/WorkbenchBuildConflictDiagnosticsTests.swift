import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct BuildConflictDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchBuildConflictDiagnosticsTests: XCTestCase {
    func testExternalEditsAreRetainedAndMissingBuildSourceCanBeRepairedWithoutNewRevision() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-build-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: BuildConflictDocuments(url: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        let visible = root.appendingPathComponent("visible")
        _ = try workspace.create(at: visible.path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let created = try authoring.create(name: "Editor", kind: "web", trustedKitVersion: "1.0.0")
        let id = created.project.projectId
        let file = URL(fileURLWithPath: created.path).appendingPathComponent("web/index.html")
        let bytes = Data("<html>edited outside Screenpunk</html>".utf8)
        try bytes.write(to: file)
        let edited = try authoring.get(id)
        XCTAssertNotEqual(edited.sourceVersion, created.sourceVersion)
        XCTAssertThrowsError(try authoring.retainSourceVersion(id, expectedSourceVersion: created.sourceVersion))
        XCTAssertFalse(try authoring.versions(id).contains { $0.sourceVersion == edited.sourceVersion })
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: {})
        let built = try XCTUnwrap(domain.perform(.buildRun(id: id,
            expectedSourceVersion: edited.sourceVersion, baseRevision: nil)).build)
        XCTAssertEqual(try domain.perform(.buildHead(id: id)).build?.revision, built.revision)
        XCTAssertTrue(try authoring.versions(id).contains { $0.sourceVersion == edited.sourceVersion })
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        // Reproduce the old release's published head with absent source history.
        let history = visible.appendingPathComponent("Workbench/History/Builds/" + edited.sourceVersion)
        try FileManager.default.removeItem(at: history)
        XCTAssertThrowsError(try domain.perform(.buildHead(id: id)))
        let headPath = visible.appendingPathComponent("Workbench/Library/BuildHeads/" + id + ".json")
        let headBefore = try Data(contentsOf: headPath)
        let repaired = try authoring.patch(id, expectedSourceVersion: edited.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: bytes)])
        XCTAssertEqual(repaired.sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try Data(contentsOf: headPath), headBefore)
        XCTAssertEqual(try domain.perform(.buildHead(id: id)).build?.revision, built.revision)
        let generation = try XCTUnwrap(workspace.current()?.descriptor.generation)
        _ = try authoring.patch(id, expectedSourceVersion: edited.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: bytes)])
        XCTAssertEqual(try workspace.current()?.descriptor.generation, generation)
    }

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
    func testExistingWebLayoutUsesOnlyExplicitRuntimeAssets() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-existing-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: BuildConflictDocuments(url: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("workspace").path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let project = try authoring.create(name: "Existing", kind: "web", trustedKitVersion: "1.0.0")
        let folder = URL(fileURLWithPath: project.path)
        let descriptorURL = folder.appendingPathComponent("screenpunk.project.json")
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL)) as? [String: Any])
        descriptor["entry"] = "index.html"
        try JSONSerialization.data(withJSONObject: descriptor).write(to: descriptorURL)
        try Data("<html>Original source</html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("sound.mp3"))
        try Data("private receipt".utf8).write(to: folder.appendingPathComponent("receipt.json"))
        func configure(_ assets: [String]) throws {
            try JSONSerialization.data(withJSONObject: ["name": "Existing", "assets": assets, "connections": []])
                .write(to: folder.appendingPathComponent("screen.json"))
        }
        let coordinator = WorkbenchBuildCoordinator(workspace: workspace) { _, _, _, _, _, _ in "" }
        let id = project.project.projectId
        try configure(["index.html", "sound.mp3"])
        let before = try authoring.get(id)
        let current = try authoring.patch(id, expectedSourceVersion: before.sourceVersion,
            changes: [.init(path: "index.html", bytes: Data("<html>Original source retained</html>".utf8))])
        let result = try coordinator.build(projectID: id, expectedSourceVersion: current.sourceVersion, baseRevision: nil)
        let package = try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: project.project.dashboardId, revision: result.head.revision)
        XCTAssertEqual(Set(package.files.keys), ["index.html", "sound.mp3"])
        for assets in [["index.html", "missing.js"], ["index.html", "../receipt.json"], ["index.html", "index.html"]] {
            try configure(assets)
            XCTAssertThrowsError(try coordinator.build(projectID: id,
                expectedSourceVersion: authoring.get(id).sourceVersion, baseRevision: result.head.revision))
        }
    }

}
#endif
