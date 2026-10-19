import Foundation
import XCTest
@testable import ScreenpunkController
#if os(macOS)
private struct CreationDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}
final class ControllerCloudCreationScopeTests: XCTestCase {
    func testBrokerNewProjectEventsCaptureScopeAndSurviveClientAndBrokerRestart() throws {
        let base = URL(fileURLWithPath: "/private/tmp/screenpunk-creation-event-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let machine = base.appendingPathComponent("machine"), documents = CreationDocuments(path: base)
        let workspace = try WorkspaceStore(documents: documents, machineRootPath: machine.path)
        let selected = try workspace.create(at: base.appendingPathComponent("workspace").path)
        let root = machine.appendingPathComponent("cloud-controller/test-origin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: {})
        // The official MCP method uses this same closed broker authoring grammar.
        let request = try WorkbenchAuthoringRecoveryRequest.parse(method: .projectCreate,
            params: ["schemaVersion": 1, "name": "Offline", "kind": "web"])
        let offline = try XCTUnwrap(domain.perform(request).project)
        let events = root.appendingPathComponent("projects/\(selected.descriptor.workspaceId)/new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.appendingPathComponent(offline.project.projectId + ".json").path))
        try ControllerCloudCreationScope.publish(root: root, clientId: "screenpunk-cli", accountId: "account-a", workspaceId: "workspace-a", localWorkspaceId: selected.descriptor.workspaceId)
        let created = try XCTUnwrap(domain.perform(.projectCreate(name: "Connected", kind: "web")).project)
        let cloned = try XCTUnwrap(domain.perform(.projectClone(id: created.project.projectId, expectedSourceVersion: created.sourceVersion, name: "clone")).project)
        let archive = base.appendingPathComponent("export")
        _ = try domain.perform(.projectSourceExport(id: created.project.projectId, sourceVersion: created.sourceVersion, path: archive.path))
        let imported = try XCTUnwrap(domain.perform(.projectSourceImport(path: archive.path, name: "import")).project)
        let expected = [created, cloned, imported]
        for project in expected {
            let intent = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: events.appendingPathComponent(project.project.projectId + ".json")))
            XCTAssertEqual(intent.accountId, "account-a"); XCTAssertEqual(intent.workspaceId, "workspace-a")
            XCTAssertEqual(intent.localProjectId, project.project.projectId)
            XCTAssertEqual(intent.kitVersion, "builtin-web-1")
        }
        // Existing projects are never discovered when a cloud account connects.
        _ = try domain.perform(.projectInspect(id: offline.project.projectId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.appendingPathComponent(offline.project.projectId + ".json").path))
        try ControllerCloudCreationScope.publish(root: root, clientId: "screenpunk-cli", accountId: "account-b", workspaceId: "workspace-b", localWorkspaceId: selected.descriptor.workspaceId)
        let reopened = try WorkspaceStore(documents: documents, machineRootPath: machine.path)
        let restarted = WorkbenchAuthoringRecoveryDomain(workspace: reopened, mutationGate: {})
        for project in expected {
            XCTAssertEqual(try restarted.perform(.projectInspect(id: project.project.projectId)).project?.sourceVersion, project.sourceVersion)
            let intent = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: events.appendingPathComponent(project.project.projectId + ".json")))
            XCTAssertEqual(intent.accountId, "account-a") // No retarget after account switch/restart.
        }
        // A crash after durable source/catalog publication must not lose its creation event.
        let interrupted = WorkbenchContainedAuthoring(workspace: reopened, checkpoint: { checkpoint in
            if checkpoint == .generationDurable { throw WorkspaceError.unavailable }
        })
        interrupted.cloudCreationScope = try ControllerCloudCreationScope.capture(workspace: reopened)
        XCTAssertThrowsError(try interrupted.create(name: "Interrupted", kind: "web", trustedKitVersion: "builtin-web-1"))
        _ = try WorkbenchContainedAuthoring(workspace: reopened).recoverContainedBeforeOpen(at: selected.path)
        let recovered = try XCTUnwrap(reopened.current()?.catalog.projects.first(where: { $0.name == "Interrupted" }))
        let recoveredIntent = try JSONDecoder().decode(CloudNewProjectIntent.self, from: Data(contentsOf: events.appendingPathComponent(recovered.projectId + ".json")))
        XCTAssertEqual(recoveredIntent.accountId, "account-b")
        XCTAssertEqual(recoveredIntent.localProjectId, recovered.projectId)
        try ControllerCloudCreationScope.disconnect(root: root, clientId: "screenpunk-cli")
        let signedOut = try XCTUnwrap(restarted.perform(.projectCreate(name: "Signed out", kind: "web")).project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.appendingPathComponent(signedOut.project.projectId + ".json").path))
    }
}
#endif
