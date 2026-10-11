import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct MigrationDocuments: WorkspaceDocumentsResolver {
    let url: URL
    func documentsDirectory() throws -> URL { url }
}
private struct TestMigrationGate: WorkspaceOldWriterExclusionGate {
    let allowed: Bool
    func withExclusion<T>(legacyPath: String, device: UInt64, inode: UInt64,
                          perform: () throws -> T) throws -> T {
        guard allowed, legacyPath.hasPrefix("/private/tmp/"), device != 0, inode != 0 else {
            throw WorkspaceError.unavailable
        }
        return try perform()
    }
}

final class WorkspaceLegacyMigrationTests: XCTestCase {
    private func fixture() throws -> (URL, URL, WorkspaceStore, String, String, String, Data) {
        let base = URL(fileURLWithPath: "/private/tmp/sp-legacy-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        let workspace = try WorkspaceStore(documents: MigrationDocuments(url: documents),
            machineRootPath: base.appendingPathComponent("machine").path)
        let old = base.appendingPathComponent("old")
        let root = try WorkspaceFiles(path: old.path, create: true)
        let projectId = UUID().uuidString.lowercased()
        let dashboardId = UUID().uuidString.lowercased()
        let revision = UUID().uuidString.lowercased()
        let source = try root.directory(["authoring", "projects", projectId, "source", "src"], create: true)
        try root.write(source, "main.tsx", data: Data("export default function App() { return null }".utf8), expected: nil)
        close(source)
        let sourceRoot = try root.directory(["authoring", "projects", projectId, "source"])
        try root.write(sourceRoot, "screen.json", data: Data("{\"name\":\"Migrated\"}".utf8), expected: nil)
        close(sourceRoot)
        let project = try root.directory(["authoring", "projects", projectId])
        try root.write(project, "project.json", data: Data("{\"dashboardId\":\"\(dashboardId)\",\"kitVersion\":\"1.0.0\"}".utf8), expected: nil)
        close(project)
        let html = Data("<html>legacy</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: dashboardId,
            name: "Legacy", revision: revision, entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 390, height: 844, scale: 1,
                orientation: "portrait"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let package = try root.directory(["dashboards", dashboardId, "revisions", revision], create: true)
        try root.write(package, "manifest.json", data: JSONEncoder().encode(manifest), expected: nil)
        try root.write(package, "index.html", data: html, expected: nil)
        close(package)
        let attachments = try root.directory(["attachments"], create: true)
        try root.write(attachments, "note.txt", data: Data("keep me".utf8), expected: nil)
        close(attachments)
        return (base, old, workspace, projectId, dashboardId, revision, html)
    }

    func testCopiesAndVerifiesBeforeSelectingNewWorkspace() throws {
        let (base, old, workspace, projectId, dashboardId, revision, html) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        XCTAssertEqual(plan.summary.projectIds, [projectId])
        XCTAssertEqual(plan.summary.packageRevisions, [dashboardId + "/" + revision])
        XCTAssertNil(try workspace.current())
        let destination = base.appendingPathComponent("new")
        let result = try migration.apply(plan, to: destination.path, gate: TestMigrationGate(allowed: true))
        XCTAssertEqual(result.catalog.projects.map(\.projectId), [projectId])
        XCTAssertEqual(try workspace.current()?.path, destination.path)
        XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: workspace).versions(projectId).count, 1)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: dashboardId, revision: revision).files["index.html"], html)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Workbench/Attachments/note.txt")),
                       Data("keep me".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("authoring/projects/\(projectId)/project.json").path))
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: destination,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var actualMembers = 0, actualBytes = 0
        for case let url as URL in enumerator {
            actualMembers += 1
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { actualBytes += values.fileSize ?? 0 }
        }
        XCTAssertEqual(plan.summary.plannedMembers, actualMembers)
        XCTAssertEqual(plan.summary.expandedBytes, actualBytes)
    }

    func testReviewedBrokerPlanAppliesOnlyMatchingOneUseIdAndPreservesOriginals() throws {
        let (base, old, workspace, projectId, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("reviewed")
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
            timeout: 120, mutationGate: {})
        let initial = try XCTUnwrap(domain.perform(.migrationPlan(
            path: old.path, destination: destination.path)).migrationPlan)
        XCTAssertTrue(initial.applyAvailable)
        XCTAssertEqual(initial.destinationPath, destination.path)
        XCTAssertEqual(try domain.perform(.migrationReview(id: initial.migrationId)).migrationPlan,
                       initial)
        XCTAssertThrowsError(try domain.perform(.migrationApply(id: UUID().uuidString.lowercased())))
        XCTAssertNil(try workspace.current())
        let applied = try XCTUnwrap(domain.perform(.migrationApply(id: initial.migrationId)).migrationApplied)
        XCTAssertEqual(applied.path, destination.path)
        XCTAssertEqual(try workspace.current()?.path, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent(
            "authoring/projects/\(projectId)/project.json").path))
        XCTAssertThrowsError(try domain.perform(.migrationApply(id: initial.migrationId)))
    }

    func testReviewedBrokerApplyRejectsChangedLegacySourceBeforeSwitch() throws {
        let (base, old, workspace, projectId, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("stale-reviewed")
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
            timeout: 120, mutationGate: {})
        let id = try XCTUnwrap(domain.perform(.migrationPlan(path: old.path,
            destination: destination.path)).migrationPlan?.migrationId)
        let source = old.appendingPathComponent("authoring/projects/\(projectId)/source/screen.json")
        try Data("{\"name\":\"changed after review\"}".utf8).write(to: source)
        XCTAssertThrowsError(try domain.perform(.migrationApply(id: id)))
        XCTAssertNil(try workspace.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try domain.perform(.migrationApply(id: id)))
    }

    func testRejectsChangedSourceAndMissingWriterExclusion() throws {
        let (base, old, workspace, projectId, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        XCTAssertThrowsError(try migration.apply(plan, to: base.appendingPathComponent("denied").path,
                                               gate: TestMigrationGate(allowed: false)))
        XCTAssertNil(try workspace.current())
        let changed = old.appendingPathComponent("authoring/projects/\(projectId)/source/screen.json")
        try Data("{\"name\":\"Changed\"}".utf8).write(to: changed)
        XCTAssertThrowsError(try migration.apply(plan, to: base.appendingPathComponent("changed").path,
                                               gate: TestMigrationGate(allowed: true)))
        XCTAssertNil(try workspace.current())
    }

    func testIgnorePolicyKeepsLegacyHashAndCanonicalCurrentHistoryAligned() throws {
        for rule in ["# comment only\n", "src/unused.ts\n"] {
            let (base, old, workspace, projectId, _, _, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: base) }
            let source = old.appendingPathComponent("authoring/projects/\(projectId)/source")
            try Data(rule.utf8).write(to: source.appendingPathComponent(".screenpunkignore"))
            let extra = Data("export const unused = true\n".utf8)
            try extra.write(to: source.appendingPathComponent("src/unused.ts"))
            let legacyFiles: [String: Data] = [
                "screen.json": try Data(contentsOf: source.appendingPathComponent("screen.json")),
                "src/main.tsx": try Data(contentsOf: source.appendingPathComponent("src/main.tsx")),
                "src/unused.ts": extra
            ]
            let material = legacyFiles.keys.sorted().map {
                "\($0):\(DeploymentDigest.sha256Hex(legacyFiles[$0]!))"
            }.joined(separator: "\n")
            let expectedOld = DeploymentDigest.sha256Hex(Data(material.utf8))
            let migration = WorkspaceLegacyMigration(workspace: workspace)
            let plan = try migration.inspectLegacy(at: old.path)
            let destination = base.appendingPathComponent("new")
            _ = try migration.apply(plan, to: destination.path, gate: TestMigrationGate(allowed: true))
            let current = try WorkbenchContainedAuthoring(workspace: workspace).get(projectId)
            XCTAssertEqual(try WorkbenchContainedAuthoring(workspace: workspace).versions(projectId)
                .map(\.sourceVersion), [current.sourceVersion])
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(
                "Screens/legacy-\(projectId)/src/unused.ts")), extra)
            let record = try Data(contentsOf: destination.appendingPathComponent(
                "Workbench/Migrations/\(plan.summary.migrationId)/record.json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
            let map = try XCTUnwrap(object["sourceVersionMap"] as? [String: String])
            XCTAssertEqual(map[projectId], expectedOld + " -> " + current.sourceVersion)
        }
    }

    func testKnownDraftHeadIsPreservedWithSelectedRevision() throws {
        let (base, old, workspace, _, dashboardId, revision, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let head = old.appendingPathComponent("dashboards/\(dashboardId)/head.json")
        try Data("{\"name\":\"Draft\",\"draftRevision\":\"\(revision)\",\"updatedAt\":\"2026-09-29T00:00:00Z\"}".utf8)
            .write(to: head)
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        XCTAssertTrue(plan.summary.unsupportedPortablePaths.isEmpty)
        XCTAssertGreaterThan(plan.summary.plannedMembers, 0)
        let destination = base.appendingPathComponent("new")
        _ = try migration.apply(plan, to: destination.path,
                                gate: TestMigrationGate(allowed: true))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(
            "Workbench/Migrations/\(plan.summary.migrationId)/legacy-heads/\(dashboardId).json")),
            try Data(contentsOf: head))
        let record = try Data(contentsOf: destination.appendingPathComponent(
            "Workbench/Migrations/\(plan.summary.migrationId)/record.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        XCTAssertEqual((object["legacyDraftHeads"] as? [String: String])?[dashboardId], revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: head.path))
    }

    func testCacheOnlyRevisionIsImportedWithoutDeviceAuthority() throws {
        let (base, old, workspace, _, dashboardId, libraryRevision, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let deviceId = UUID().uuidString.lowercased()
        let cacheId = UUID().uuidString.lowercased()
        let revision = UUID().uuidString.lowercased()
        let html = Data("<html>cached only</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: cacheId,
            name: "Cached", revision: revision, entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 390, height: 844, scale: 1,
                orientation: "portrait"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: html.count,
                sha256: DeploymentDigest.sha256Hex(html))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let package = old.appendingPathComponent(
            "device-packages/\(deviceId)/dashboards/\(cacheId)/revisions/\(revision)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        try html.write(to: package.appendingPathComponent("index.html"))
        try Data("private device state".utf8).write(to: old.appendingPathComponent("devices.json"))
        let approval = old.appendingPathComponent("public-read-approvals")
        try FileManager.default.createDirectory(at: approval, withIntermediateDirectories: true)
        try Data("private approval".utf8).write(to: approval.appendingPathComponent("record"))
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        XCTAssertTrue(plan.summary.unsupportedPortablePaths.isEmpty)
        XCTAssertEqual(Set(plan.summary.packageRevisions),
                       Set([dashboardId + "/" + libraryRevision, cacheId + "/" + revision]))
        let destination = base.appendingPathComponent("new")
        _ = try migration.apply(plan, to: destination.path, gate: TestMigrationGate(allowed: true))
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: cacheId, revision: revision).files["index.html"], html)
        let record = try Data(contentsOf: destination.appendingPathComponent(
            "Workbench/Migrations/\(plan.summary.migrationId)/record.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        XCTAssertEqual(object["cacheOnlyRevisions"] as? [String], [cacheId + "/" + revision])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("devices.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("public-read-approvals").path))
    }

    func testDraftHeadWithoutRetainedRevisionRefusesMigration() throws {
        let (base, old, workspace, _, dashboardId, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = UUID().uuidString.lowercased()
        let head = old.appendingPathComponent("dashboards/\(dashboardId)/head.json")
        try Data("{\"name\":\"Draft\",\"draftRevision\":\"\(missing)\",\"updatedAt\":\"2026-09-29T00:00:00Z\"}".utf8)
            .write(to: head)
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        XCTAssertThrowsError(try migration.inspectLegacy(at: old.path))
        XCTAssertNil(try workspace.current())
    }

    func testUnknownPortableProjectMemberBlocksSwitch() throws {
        let (base, old, workspace, projectId, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let extra = old.appendingPathComponent("authoring/projects/\(projectId)/notes.txt")
        try Data("keep".utf8).write(to: extra)
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        XCTAssertEqual(plan.summary.unsupportedPortablePaths,
                       ["authoring/projects/\(projectId)/notes.txt"])
        let destination = base.appendingPathComponent("new")
        XCTAssertThrowsError(try migration.apply(plan, to: destination.path,
                                               gate: TestMigrationGate(allowed: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(try workspace.current())
    }

    func testOrphanDashboardMemberWithoutRevisionsBlocksSwitch() throws {
        let (base, old, workspace, _, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let orphanId = UUID().uuidString.lowercased()
        let orphan = old.appendingPathComponent("dashboards/\(orphanId)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: orphan.appendingPathComponent("notes.txt"))
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        XCTAssertEqual(plan.summary.unsupportedPortablePaths,
                       ["dashboards/\(orphanId)/notes.txt"])
        let destination = base.appendingPathComponent("new")
        XCTAssertThrowsError(try migration.apply(plan, to: destination.path,
                                               gate: TestMigrationGate(allowed: true)))
        XCTAssertNil(try workspace.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancelledApplyDoesNotSwitchOrPublishDestination() throws {
        let (base, old, workspace, _, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let migration = WorkspaceLegacyMigration(workspace: workspace)
        let plan = try migration.inspectLegacy(at: old.path)
        let destination = base.appendingPathComponent("new")
        XCTAssertThrowsError(try migration.apply(plan, to: destination.path,
            gate: TestMigrationGate(allowed: true), cancelled: { true }))
        XCTAssertNil(try workspace.current())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
#endif
