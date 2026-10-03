import XCTest
import Foundation
import ScreenpunkController
@testable import WorkbenchCommand

final class WorkbenchProjectCloneRouteIntegrationTests: XCTestCase {
    func testPublicCLIClonesExactSourceIntoSelectedWorkspace() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-clone-cli-" + UUID().uuidString.lowercased())
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
        let source = try WorkbenchContainedAuthoring(workspace: workspace).create(
            name: "Source", kind: "web", trustedKitVersion: "kit-1")
        let broker = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
            limits: .init(timeout: 1))
        let host = try WorkbenchServiceHost(broker: broker, home: home,
            documents: documents, ownerCheck: {}, nativeFactory: { _ in
                WorkbenchNativeComposition(activateOnStart: false,
                    activate: { _ in XCTFail("clone must not activate device transport") },
                    deactivate: {})
            })
        defer { host.stop() }
        XCTAssertEqual(WorkbenchCommand.run(arguments: ["project", "clone",
            source.project.projectId, "--source-version", source.sourceVersion,
            "--to", "Screens/copied", "--home", home.path,
            "--runtime-directory", runtime.path, "--json"], environment: environment), 0)
        let projects = try XCTUnwrap(workspace.current()).catalog.projects
        XCTAssertEqual(projects.count, 2)
        let copied = try XCTUnwrap(projects.first(where: { $0.location.path == "Screens/copied" }))
        XCTAssertNotEqual(copied.projectId, source.project.projectId)
        XCTAssertNotEqual(copied.dashboardId, source.project.dashboardId)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path)
            .appendingPathComponent("web/index.html")),
            try Data(contentsOf: root.appendingPathComponent("visible/Screens/copied/web/index.html")))
    }
}
