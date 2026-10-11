#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

private struct MetadataDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}

final class WorkbenchWorkspaceMetadataTests: XCTestCase {
    func testCatalogAdoptionAndSettingsAdvanceOneRecoverableGeneration() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-metadata-trio-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try WorkspaceStore(documents: MetadataDocuments(root: root),
            machineRootPath: root.appendingPathComponent("machine").path)
        let visible = root.appendingPathComponent("visible")
        _ = try workspace.create(at: visible.path)
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let seed = try authoring.create(name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        func aligned() throws -> Int {
            let current = try XCTUnwrap(workspace.current())
            XCTAssertEqual(current.descriptor.generation, current.catalog.generation)
            XCTAssertEqual(current.descriptor.generation, current.settings.generation)
            return current.descriptor.generation
        }
        let before = try aligned()
        let external = root.appendingPathComponent("external")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: seed.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let original = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        let independent = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "External", kind: original.kind, kitVersion: original.kitVersion,
            entry: original.entry, screenConfig: original.screenConfig)
        try WorkspaceJSON.encode(independent).write(to: descriptorURL)
        let transfer = WorkbenchPortableSourceArchive(workspace: workspace)
        let project = try transfer.openExternal(at: external.path, explicitExternal: true)
        XCTAssertEqual(try aligned(), before + 1)
        let version = try WorkbenchSourceHasher.hash([
            "screenpunk.project.json": Data(contentsOf: descriptorURL),
            "screen.json": Data(contentsOf: external.appendingPathComponent("screen.json")),
            "web/index.html": Data(contentsOf: external.appendingPathComponent("web/index.html"))])
        _ = try transfer.adoptExternal(projectId: project.projectId,
            expectedSourceVersion: version, name: "adopted")
        XCTAssertEqual(try aligned(), before + 2)
        let generation = try aligned()
        _ = try workspace.updateSettings(["theme": "dark"], profiles: [:],
            expectedGeneration: generation)
        XCTAssertEqual(try aligned(), before + 3)
        XCTAssertEqual(try workspace.current()?.settings.presentation["theme"], "dark")
        XCTAssertThrowsError(try workspace.updateSettings(["theme": "light"], profiles: [:],
            expectedGeneration: generation))
        let later = try authoring.create(name: "Later", kind: "web", trustedKitVersion: "kit-1")
        XCTAssertEqual(try aligned(), before + 4)
        XCTAssertEqual(try authoring.get(later.project.projectId).sourceVersion,
            later.sourceVersion)
    }
}
#endif
