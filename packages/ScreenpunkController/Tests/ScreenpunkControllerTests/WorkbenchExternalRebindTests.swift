#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct ExternalRebindDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchExternalRebindTests: XCTestCase {
    func testAuthenticatedSocketRebindKeepsPortableCatalogAndOriginalSource() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-rebind-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: ExternalRebindDocuments(root: root),
            machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let seed = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let first = root.appendingPathComponent("first")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: seed.path), to: first)
        let descriptor = first.appendingPathComponent("screenpunk.project.json")
        let old = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptor))
        let independent = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "External", kind: old.kind, kitVersion: old.kitVersion,
            entry: old.entry, screenConfig: old.screenConfig)
        try WorkspaceJSON.encode(independent).write(to: descriptor)
        let (project, version) = try WorkbenchPortableSourceArchive(workspace: workspace)
            .openExternalVersioned(at: first.path, explicitExternal: true)
        let second = root.appendingPathComponent("second")
        try FileManager.default.copyItem(at: first, to: second)
        let firstBytes = try Data(contentsOf: descriptor)
        let catalog = try XCTUnwrap(workspace.current()).catalog

        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"),
            rendererFactory: { nil })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace,
            mutationGate: {})
        let server = WorkbenchBrokerServer(environment: environment, domain: domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        let selected = try client.workspaceStatus()
        let request: [String: Any] = ["schemaVersion": 1, "projectId": project.projectId,
            "expectedSourceVersion": version, "path": second.path, "explicitExternal": true,
            "expectedWorkspaceId": try XCTUnwrap(selected.workspaceId),
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        let result = try client.performAuthoring(method: .projectRelocateExternal, params: request)
        XCTAssertEqual(result.sourceLocation?.path, second.path)
        XCTAssertEqual(result.sourceLocation?.backupCoverage, "outside-workspace-backup-coverage")
        XCTAssertEqual(try workspace.resolveProject(project.projectId), second.path)
        XCTAssertEqual(try Data(contentsOf: descriptor), firstBytes)
        XCTAssertEqual(try workspace.current()?.catalog, catalog)
        XCTAssertThrowsError(try client.performAuthoring(method: .projectRelocateExternal,
            params: request))
        var invalid = request
        invalid["explicitExternal"] = false
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(
            method: .projectRelocateExternal, params: invalid))
    }
}
#endif
