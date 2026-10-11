#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct PortableSocketDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchPortableSourceSocketTests: XCTestCase {
    func testOrdinarySocketSourceArchiveAndExplicitExternalAdoption() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-source-socket-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let workspace = try WorkspaceStore(documents: PortableSocketDocuments(root: root),
            machineRootPath: machine.path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let original = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Original", kind: "web", trustedKitVersion: "kit-1")
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
        let bound: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": try XCTUnwrap(selected.workspaceId),
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        func parameters(_ values: [String: Any]) -> [String: Any] {
            bound.merging(values) { _, incoming in incoming }
        }
        let archive = root.appendingPathComponent("source-export")
        let exported = try client.performAuthoring(method: .projectSourceExport,
            params: parameters(["projectId": original.project.projectId,
                "sourceVersion": original.sourceVersion, "path": archive.path]))
        XCTAssertEqual(exported.sourceArchive?.sourceVersion, original.sourceVersion)
        let imported = try client.performAuthoring(method: .projectSourceImport,
            params: parameters(["path": archive.path]))
        XCTAssertNotEqual(imported.project?.project.projectId, original.project.projectId)

        let external = root.appendingPathComponent("external")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: original.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let old = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        let replacement = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "External", kind: old.kind, kitVersion: old.kitVersion,
            entry: old.entry, screenConfig: old.screenConfig)
        try WorkspaceJSON.encode(replacement).write(to: descriptorURL)
        let originalExternalBytes = try Data(contentsOf: descriptorURL)
        let opened = try client.performAuthoring(method: .projectOpenExternal,
            params: parameters(["path": external.path, "explicitExternal": true]))
        let location = try XCTUnwrap(opened.sourceLocation)
        XCTAssertEqual(location.backupCoverage, "outside-workspace-backup-coverage")
        let rebound = try client.workspaceStatus()
        let adopted = try client.performAuthoring(method: .projectAdoptExternal,
            params: ["schemaVersion": 1,
                "expectedWorkspaceId": try XCTUnwrap(rebound.workspaceId),
                "expectedSelectionGeneration": try XCTUnwrap(rebound.selectionGeneration),
                "projectId": location.project.projectId,
                "expectedSourceVersion": location.sourceVersion, "name": "adopted"])
        XCTAssertEqual(adopted.sourceLocation?.project.projectId, location.project.projectId)
        XCTAssertEqual(adopted.sourceLocation?.backupCoverage, "included-in-workspace-backup")
        XCTAssertEqual(try Data(contentsOf: descriptorURL), originalExternalBytes)
        XCTAssertTrue(try XCTUnwrap(workspace.current()).coverage.complete)
    }
}
#endif
