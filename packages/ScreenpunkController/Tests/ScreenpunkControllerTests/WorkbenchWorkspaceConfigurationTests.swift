#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct ConfigurationDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchWorkspaceConfigurationTests: XCTestCase {
    func testClosedPresentationConfigurationAndGenerationConflict() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-config-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: ConfigurationDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try workspace.create(at: root.appendingPathComponent("visible").path)
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace, mutationGate: {})
        let initial = try XCTUnwrap(domain.perform(.workspaceConfigGet).configuration)
        XCTAssertEqual(initial.path, root.appendingPathComponent("visible/workspace.json").path)
        let changed = try XCTUnwrap(domain.perform(.workspaceConfigSet(
            key: "theme", value: "dark", expectedGeneration: initial.generation)).configuration)
        XCTAssertEqual(changed.presentation["theme"], "dark")
        XCTAssertEqual(changed.generation, initial.generation + 1)
        XCTAssertEqual(try workspace.current()?.descriptor.generation, changed.generation)
        XCTAssertEqual(try workspace.current()?.catalog.generation, changed.generation)
        XCTAssertThrowsError(try domain.perform(.workspaceConfigSet(
            key: "theme", value: "light", expectedGeneration: initial.generation))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertThrowsError(try WorkbenchAuthoringRecoveryRequest.parse(method: .workspaceConfigSet,
            params: ["schemaVersion": 1, "key": "credential", "value": "secret",
                     "expectedGeneration": changed.generation]))
        let removed = try XCTUnwrap(domain.perform(.workspaceConfigUnset(
            key: "theme", expectedGeneration: changed.generation)).configuration)
        XCTAssertNil(removed.presentation["theme"])
        XCTAssertEqual(removed.generation, changed.generation + 1)
    }
}
#endif
