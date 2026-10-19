import XCTest
import Foundation
import ScreenpunkController
@testable import WorkbenchCommand

final class WorkbenchExternalRebindRouteIntegrationTests: XCTestCase {
    func testPublicCLIRebindsVerifiedExternalCopyWithoutMovingOriginal() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-rebind-cli-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let documentsRoot = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documentsRoot, withIntermediateDirectories: false)
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent("home")
        let environment = ["SCREENPUNK_DOCUMENTS_DIRECTORY": documentsRoot.path]
        let documents = CLIWorkspaceDocuments(environment: environment)
        let workspace = try WorkspaceStore(documents: documents,
            machineRootPath: runtime.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let seed = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let first = root.appendingPathComponent("first")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: seed.path), to: first)
        let descriptor = first.appendingPathComponent("screenpunk.project.json")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: descriptor)) as? [String: Any])
        var changed = raw
        changed["projectId"] = UUID().uuidString.lowercased()
        changed["dashboardId"] = UUID().uuidString.lowercased()
        try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]).write(to: descriptor)
        let (project, version) = try WorkbenchPortableSourceArchive(workspace: workspace)
            .openExternalVersioned(at: first.path, explicitExternal: true)
        let second = root.appendingPathComponent("second")
        try FileManager.default.copyItem(at: first, to: second)
        let originalBytes = try Data(contentsOf: descriptor)
        let catalog = try XCTUnwrap(workspace.current()).catalog
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
            limits: .init(timeout: 1))
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("external rebind must not activate device transport") },
                    deactivate: {})
            })
        defer { host.stop() }
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["project", "relocate",
            project.projectId, "--source-version", version, "--to", second.path,
            "--external", "--home", home.path, "--runtime-directory", runtime.path,
            "--json"], environment: environment), 0)
        XCTAssertEqual(try workspace.resolveProject(project.projectId), second.path)
        XCTAssertEqual(try workspace.current()?.catalog, catalog)
        XCTAssertEqual(try Data(contentsOf: descriptor), originalBytes)
    }
}
