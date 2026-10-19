import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct AuthoringRecoveryDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkbenchAuthoringRecoveryDomainTests: XCTestCase {
    func testVisiblePlainWebWorkflowAndFreshMachineSnapshotOpen() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-authoring-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: AuthoringRecoveryDocuments(path: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let visible = base.appendingPathComponent("visible")
        _ = try workspace.create(at: visible.path)
        var gateCalls = 0
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: { gateCalls += 1 })
        let created = try XCTUnwrap(domain.perform(.projectCreate(name: "Web", kind: "web")).project)
        let id = created.project.projectId
        XCTAssertEqual(created.sourceHashVersion, 1)
        XCTAssertEqual(try domain.perform(.projectInspect(id: id)).project?.sourceVersion,
                       created.sourceVersion)
        let newHTML = Data("<html><main>changed</main></html>".utf8)
        let edited = try XCTUnwrap(domain.perform(.projectPatch(id: id,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: newHTML)])).project)
        XCTAssertNotEqual(edited.sourceVersion, created.sourceVersion)
        XCTAssertThrowsError(try domain.perform(.projectPatch(id: id,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("stale".utf8))])))
        let built = try XCTUnwrap(domain.perform(.buildRun(id: id,
            expectedSourceVersion: edited.sourceVersion, baseRevision: nil)).build)
        XCTAssertEqual(built.sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try domain.perform(.buildHead(id: id)).build?.revision, built.revision)
        XCTAssertEqual(try domain.perform(.packageHistory(cursor: nil)).packages?.map(\.revision), [built.revision])
        let versions = try WorkbenchContainedAuthoring(workspace: workspace).versions(id)
        XCTAssertEqual(Set(versions.map(\.sourceVersion)), [created.sourceVersion, edited.sourceVersion])
        try Data("auxiliary note".utf8).write(to: visible.appendingPathComponent("notes.txt"))
        let backup = base.appendingPathComponent("backup")
        let snapshot = try XCTUnwrap(domain.perform(.snapshotCreate(path: backup.path)).snapshot)
        XCTAssertTrue(snapshot.complete)
        XCTAssertEqual(snapshot.scope, "authoring")
        XCTAssertEqual(snapshot.omittedAuxiliaryPaths, ["notes.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(snapshot.path, backup.path)
        XCTAssertEqual(gateCalls, 5)

        let restored = try WorkspaceStore(documents: AuthoringRecoveryDocuments(path: documents),
            machineRootPath: base.appendingPathComponent("fresh-machine").path)
        _ = try WorkbenchContainedAuthoring(workspace: restored).recoverContainedBeforeOpen(at: backup.path)
        _ = try restored.open(at: backup.path)
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: restored).get(id).sourceVersion,
                       edited.sourceVersion)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: restored)
            .get(dashboardId: built.dashboardId, revision: built.revision).files["index.html"], newHTML)
        XCTAssertEqual(try WorkbenchAuthoringRecoveryDomain(workspace: restored,
            mutationGate: {}).perform(.buildHead(id: id)).build?.revision, built.revision)
    }

    func testClosedRequestGrammarAndBoundedSourcePayload() throws {
        let id = UUID().uuidString.lowercased()
        let version = String(repeating: "a", count: 64)
        let bytes = Data("<html>bounded</html>".utf8)
        let valid: [String: Any] = ["schemaVersion": 1, "projectId": id,
            "expectedSourceVersion": version,
            "changes": [["path": "web/index.html", "bytesBase64": bytes.base64EncodedString()]]]
        guard case .projectPatch(_, _, let changes) = try WorkbenchAuthoringRecoveryRequest.parse(
            method: .projectPatch, params: valid) else { return XCTFail("Expected typed patch") }
        XCTAssertEqual(changes.first?.bytes, bytes)
        var extra = valid; extra["destination"] = "/private/tmp/foreign"
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(method: .projectPatch, params: extra))
        var oversized = valid
        oversized["changes"] = [["path": "web/index.html",
            "bytesBase64": Data(repeating: 65, count: 5 * 1024 * 1024 + 1).base64EncodedString()]]
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(method: .projectPatch, params: oversized))
        guard case .projectCreate(_, let kind) = try WorkbenchAuthoringRecoveryRequest.parse(
            method: .projectCreate,
            params: ["schemaVersion": 1, "name": "React", "kind": "react"]) else {
            return XCTFail("React must use the closed built-in template route")
        }
        XCTAssertEqual(kind, "react")
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(method: .snapshotCreate,
            params: ["schemaVersion": 1, "path": "relative-backup"]))
        let mismatched = WorkbenchAuthoringRecoveryResult(kind: .authoringProject,
            packages: [])
        XCTAssertThrowsError(try mismatched.validate(for: .projectInspect))
    }

    func testBoundAuthoringRejectsStaleSelectionBeforeMutationIncludingABA() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-bound-authoring-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: AuthoringRecoveryDocuments(path: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let a = try workspace.create(at: base.appendingPathComponent("A").path)
        let oldGeneration = try XCTUnwrap(a.selectionGeneration)
        var gateCalls = 0
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: { gateCalls += 1 })
        func bound(_ method: WorkbenchAuthoringRecoveryMethod, _ fields: [String: Any]) throws
            -> WorkbenchAuthoringRecoveryRequest {
            try WorkbenchAuthoringRecoveryRequest.parse(method: method,
                params: fields.merging(["schemaVersion": 1,
                    "expectedWorkspaceId": a.descriptor.workspaceId,
                    "expectedSelectionGeneration": oldGeneration]) { current, _ in current })
        }
        let created = try XCTUnwrap(domain.perform(bound(.projectCreate,
            ["name": "First", "kind": "web"])).project)
        XCTAssertEqual(gateCalls, 1)
        _ = try workspace.create(at: base.appendingPathComponent("B").path)
        XCTAssertThrowsError(try domain.perform(bound(.projectCreate,
            ["name": "Wrong workspace", "kind": "web"]))) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertEqual(gateCalls, 1)
        XCTAssertTrue(try WorkbenchContainedAuthoring(workspace: workspace).list().isEmpty)
        _ = try workspace.open(at: base.appendingPathComponent("A").path)
        XCTAssertNotEqual(try workspace.current()?.selectionGeneration, oldGeneration)
        let sourceBefore = try WorkbenchContainedAuthoring(workspace: workspace)
            .get(created.project.projectId).sourceVersion
        XCTAssertThrowsError(try domain.perform(bound(.projectPatch,
            ["projectId": created.project.projectId,
             "expectedSourceVersion": sourceBefore,
             "changes": [["path": "web/index.html",
                          "bytesBase64": Data("wrong".utf8).base64EncodedString()]]])))
        XCTAssertThrowsError(try domain.perform(bound(.buildRun,
            ["projectId": created.project.projectId,
             "expectedSourceVersion": sourceBefore])))
        XCTAssertEqual(gateCalls, 1)
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: workspace)
            .get(created.project.projectId).sourceVersion, sourceBefore)
        XCTAssertNil(try WorkbenchBuildCoordinator(workspace: workspace) { _, _, _, _, _, _ in
            throw WorkbenchIPCError(.methodNotFound)
        }.readHead(projectID: created.project.projectId))
    }

    func testMigrationPlanIsReadOnlyAndDoesNotOfferApply() throws {
        let base = URL(fileURLWithPath: "/private/tmp/sp-authoring-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: AuthoringRecoveryDocuments(path: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let legacy = base.appendingPathComponent("legacy")
        let root = try WorkspaceFiles(path: legacy.path, create: true)
        let projectId = UUID().uuidString.lowercased()
        let dashboardId = UUID().uuidString.lowercased()
        let project = try root.directory(["authoring", "projects", projectId], create: true)
        try root.write(project, "project.json", data: Data(
            "{\"dashboardId\":\"\(dashboardId)\",\"kitVersion\":\"1.0.0\"}".utf8), expected: nil)
        close(project)
        let source = try root.directory(["authoring", "projects", projectId, "source"], create: true)
        try root.write(source, "screen.json", data: Data("{\"name\":\"Legacy\"}".utf8), expected: nil)
        close(source)
        let web = try root.directory(["authoring", "projects", projectId, "source", "web"], create: true)
        try root.write(web, "index.html", data: Data("<html>old</html>".utf8), expected: nil)
        close(web)
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
            mutationGate: { XCTFail("Read-only migration plan must not enter mutation gate") })
        let plan = try XCTUnwrap(domain.perform(.migrationPlan(path: legacy.path, destination: nil)).migrationPlan)
        XCTAssertEqual(plan.projectIds, [projectId])
        XCTAssertFalse(plan.applyAvailable)
        XCTAssertNil(try workspace.current())
    }
}
#endif
