import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct KitUpgradeDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}

final class WorkbenchKitUpgradeTransactionTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let visible: URL
        let workspace: WorkspaceStore
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/sp-kit-upgrade-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let documents = root.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
            workspace = try WorkspaceStore(documents: KitUpgradeDocuments(url: documents),
                machineRootPath: root.appendingPathComponent("machine").path)
            visible = root.appendingPathComponent("visible")
            _ = try workspace.create(at: visible.path)
        }
        func restored() throws -> WorkspaceStore {
            try WorkspaceStore(documents: KitUpgradeDocuments(url: root.appendingPathComponent("Documents")),
                machineRootPath: root.appendingPathComponent("restored-machine").path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private let selected = WorkspaceToolchainRequirements.Requirement(catalogEntryId: "test-kit-2",
        kitVersion: "2.0.0", platform: "darwin-arm64", inventoryHash: String(repeating: "a", count: 64))

    private func importPackage(into workspace: WorkspaceStore) throws {
        let bytes = Data("<html>retained package</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Retained",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: bytes.count,
                sha256: DeploymentDigest.sha256Hex(bytes))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        _ = try WorkbenchPortablePackages(workspace: workspace).importVerified(
            .init(manifest: manifest, files: ["index.html": bytes]))
    }

    func testCreateImportThenSettingsUpdateKeepsOneLogicalGeneration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try WorkbenchContainedAuthoring(workspace: fixture.workspace)
            .create(name: "React", kind: "react", trustedKitVersion: "1.0.0")
        try importPackage(into: fixture.workspace)
        let before = try XCTUnwrap(fixture.workspace.current())
        XCTAssertEqual(before.descriptor.generation, before.catalog.generation)
        XCTAssertEqual(before.descriptor.generation, before.settings.generation)
        _ = try fixture.workspace.updateSettings(["theme": "dark"], profiles: [:],
            expectedGeneration: before.settings.generation)
        let after = try XCTUnwrap(fixture.workspace.current())
        XCTAssertEqual(after.settings.presentation["theme"], "dark")
        XCTAssertEqual(after.descriptor.generation, before.descriptor.generation + 1)
        XCTAssertEqual(after.catalog.generation, after.descriptor.generation)
        XCTAssertEqual(after.settings.generation, after.descriptor.generation)
    }

    func testImportThenKitUpgradeWithoutInterveningSourceEdit() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let authoring = WorkbenchContainedAuthoring(workspace: fixture.workspace)
        let created = try authoring.create(name: "React", kind: "react", trustedKitVersion: "1.0.0")
        try importPackage(into: fixture.workspace)
        let before = try XCTUnwrap(fixture.workspace.current())
        let upgraded = try authoring.upgradeKitPreverified(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            expectedCatalogGeneration: before.catalog.generation, requirement: selected)
        XCTAssertNotEqual(upgraded.sourceVersion, created.sourceVersion)
        let after = try XCTUnwrap(fixture.workspace.current())
        XCTAssertEqual(after.descriptor.generation, before.descriptor.generation + 1)
        XCTAssertEqual(after.catalog.generation, after.descriptor.generation)
        XCTAssertEqual(after.settings.generation, after.descriptor.generation)
    }

    func testPreverifiedUpgradePinsSourceAndRequirementsInOneGeneration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let authoring = WorkbenchContainedAuthoring(workspace: fixture.workspace)
        let created = try authoring.create(name: "React", kind: "react", trustedKitVersion: "1.0.0")
        let before = try XCTUnwrap(fixture.workspace.current())
        let upgraded = try authoring.upgradeKitPreverified(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            expectedCatalogGeneration: before.catalog.generation, requirement: selected)
        XCTAssertNotEqual(upgraded.sourceVersion, created.sourceVersion)
        let after = try XCTUnwrap(fixture.workspace.current())
        XCTAssertEqual(after.descriptor.generation, before.descriptor.generation + 1)
        XCTAssertEqual(after.catalog.generation, after.descriptor.generation)
        XCTAssertEqual(after.settings.generation, after.descriptor.generation)
        let descriptor = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: upgraded.path + "/screenpunk.project.json")))
        XCTAssertEqual(descriptor.kitVersion, selected.kitVersion)
        let pin = try JSONDecoder().decode(WorkbenchSourceKitPin.self,
            from: Data(contentsOf: URL(fileURLWithPath: upgraded.path + "/screenpunk.lock.json")))
        XCTAssertEqual(pin.requirement, selected)
        let requirements = try JSONDecoder().decode(WorkspaceToolchainRequirements.self,
            from: Data(contentsOf: fixture.visible.appendingPathComponent("Workbench/Toolchains/requirements.json")))
        XCTAssertEqual(requirements.required, [selected])
        XCTAssertEqual(Set(try authoring.versions(created.project.projectId).map(\.sourceVersion)),
            Set([created.sourceVersion, upgraded.sourceVersion]))
        XCTAssertThrowsError(try authoring.upgradeKitPreverified(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            expectedCatalogGeneration: before.catalog.generation, requirement: selected)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
    }

    func testInterruptedUpgradeRecoversSourcePinRequirementsAndGenerations() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let normal = WorkbenchContainedAuthoring(workspace: fixture.workspace)
        let created = try normal.create(name: "React", kind: "react", trustedKitVersion: "1.0.0")
        let generation = try XCTUnwrap(fixture.workspace.current()).catalog.generation
        let interrupted = WorkbenchContainedAuthoring(workspace: fixture.workspace) { point in
            if point == .memberPublished(0) { throw WorkspaceError.unavailable }
        }
        XCTAssertThrowsError(try interrupted.upgradeKitPreverified(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            expectedCatalogGeneration: generation, requirement: selected))
        let fresh = try fixture.restored()
        XCTAssertThrowsError(try fresh.open(at: fixture.visible.path))
        let recovery = WorkbenchContainedAuthoring(workspace: fresh)
        XCTAssertEqual(try recovery.recoverContainedBeforeOpen(at: fixture.visible.path).count, 1)
        let opened = try fresh.open(at: fixture.visible.path)
        XCTAssertEqual(opened.descriptor.generation, generation + 1)
        XCTAssertEqual(opened.catalog.generation, generation + 1)
        XCTAssertEqual(opened.settings.generation, generation + 1)
        let upgraded = try recovery.get(created.project.projectId)
        XCTAssertNotEqual(upgraded.sourceVersion, created.sourceVersion)
        let pin = try JSONDecoder().decode(WorkbenchSourceKitPin.self,
            from: Data(contentsOf: URL(fileURLWithPath: upgraded.path + "/screenpunk.lock.json")))
        XCTAssertEqual(pin.requirement, selected)
        let requirements = try JSONDecoder().decode(WorkspaceToolchainRequirements.self,
            from: Data(contentsOf: fixture.visible.appendingPathComponent("Workbench/Toolchains/requirements.json")))
        XCTAssertEqual(requirements.required, [selected])
    }
}
#endif
