import XCTest
import Foundation
@testable import ScreenpunkController

#if os(macOS)
private struct SourceArchiveDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkbenchPortableSourceArchiveTests: XCTestCase {
    private func fixture() throws -> (URL, WorkspaceStore, WorkbenchContainedAuthoring,
                                      WorkbenchPortableSourceArchive) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-source-archive-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = try WorkspaceStore(documents: SourceArchiveDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        _ = try store.create(at: root.appendingPathComponent("visible").path)
        return (root, store, WorkbenchContainedAuthoring(workspace: store),
            WorkbenchPortableSourceArchive(workspace: store))
    }

    func testCloneCurrentCreatesFreshIdentitiesAtExactContainedDestination() throws {
        let (root, store, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try authoring.create(name: "Clone Me", kind: "web", trustedKitVersion: "kit-1")
        let edited = try authoring.patch(source.project.projectId,
            expectedSourceVersion: source.sourceVersion,
            changes: [.init(path: "data/demo.json", bytes: Data("{\"source\":1}".utf8))])
        XCTAssertThrowsError(try transfer.cloneCurrent(projectId: source.project.projectId,
            expectedSourceVersion: String(repeating: "0", count: 64),
            destinationName: "copy"))
        let cloned = try transfer.cloneCurrent(projectId: source.project.projectId,
            expectedSourceVersion: edited.sourceVersion, destinationName: "copy")
        XCTAssertNotEqual(cloned.project.projectId, edited.project.projectId)
        XCTAssertNotEqual(cloned.project.dashboardId, edited.project.dashboardId)
        XCTAssertEqual(cloned.project.name, edited.project.name)
        XCTAssertEqual(cloned.project.location.path, "Screens/copy")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cloned.path)
            .appendingPathComponent("data/demo.json")), Data("{\"source\":1}".utf8))
        XCTAssertEqual(try authoring.get(source.project.projectId).sourceVersion,
            edited.sourceVersion)
        XCTAssertEqual(try store.current()?.catalog.projects.count, 2)
        XCTAssertThrowsError(try transfer.cloneCurrent(projectId: source.project.projectId,
            expectedSourceVersion: edited.sourceVersion, destinationName: "copy"))
    }

    func testCloneAtTwoThousandFilesSucceedsAndOverLimitDoesNotReserveDestination() throws {
        let (root, store, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try authoring.create(name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("large-external")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: seed.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let old = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        try FileManager.default.moveItem(at: external.appendingPathComponent("web/index.html"),
            to: external.appendingPathComponent("index.html"))
        try FileManager.default.removeItem(at: external.appendingPathComponent("web"))
        let document = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "Large external", kind: old.kind, kitVersion: old.kitVersion,
            entry: "index.html", screenConfig: old.screenConfig)
        try WorkspaceJSON.encode(document).write(to: descriptorURL)
        for number in 0..<1_997 {
            let name = String(format: "asset-%04d.txt", number)
            try Data([UInt8(number % 251)]).write(to: external.appendingPathComponent(name))
        }
        let registered = try transfer.openExternalVersioned(at: external.path, explicitExternal: true)
        let before = try XCTUnwrap(store.current())
        let cloned = try transfer.cloneCurrent(projectId: registered.0.projectId,
            expectedSourceVersion: registered.1, destinationName: "accepted")
        XCTAssertEqual(cloned.fileCount, 2_000)
        XCTAssertEqual(cloned.project.location.path, "Screens/accepted")
        XCTAssertNotEqual(cloned.project.projectId, registered.0.projectId)
        try Data([9]).write(to: external.appendingPathComponent("over-limit.txt"))
        let destination = root.appendingPathComponent("visible/Screens/overflow")
        XCTAssertThrowsError(try transfer.cloneCurrent(projectId: registered.0.projectId,
            expectedSourceVersion: registered.1, destinationName: "overflow")) {
            XCTAssertEqual($0 as? WorkspaceError, .limitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: external.appendingPathComponent("over-limit.txt"))
        let after = try XCTUnwrap(store.current())
        XCTAssertEqual(after.catalog.projects.count, before.catalog.projects.count + 1)
        XCTAssertEqual(after.descriptor.generation, before.descriptor.generation + 1)
        XCTAssertEqual(try store.resolveProject(registered.0.projectId), external.path)
    }

    func testCloneCountsSharedNestedDirectoryOnce() throws {
        let (root, store, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try authoring.create(name: "Nested seed", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("nested-external")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: seed.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let old = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        let document = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "Nested", kind: old.kind, kitVersion: old.kitVersion,
            entry: old.entry, screenConfig: old.screenConfig)
        try WorkspaceJSON.encode(document).write(to: descriptorURL)
        let assets = external.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        for number in 0..<999 {
            let name = String(format: "asset-%04d.txt", number)
            try Data([UInt8(number % 251)]).write(to: assets.appendingPathComponent(name))
        }
        let registered = try transfer.openExternalVersioned(at: external.path, explicitExternal: true)
        let cloned = try transfer.cloneCurrent(projectId: registered.0.projectId,
            expectedSourceVersion: registered.1, destinationName: "nested-copy")
        XCTAssertEqual(cloned.fileCount, 1_002)
        XCTAssertEqual(cloned.project.location.path, "Screens/nested-copy")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cloned.path)
            .appendingPathComponent("assets/asset-0998.txt")), Data([UInt8(998 % 251)]))
        XCTAssertEqual(try store.resolveProject(registered.0.projectId), external.path)
    }

    func testSourceArchiveRoundTripsEditableAssetsWithNewIdentities() throws {
        let (root, store, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Kitchen", kind: "web", trustedKitVersion: "kit-1")
        let edited = try authoring.patch(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "assets/icon.svg", bytes: Data("<svg/>".utf8)),
                      .init(path: "data/fixtures.json", bytes: Data("{\"value\":1}".utf8))])
        let exports = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let archive = exports.appendingPathComponent("kitchen.source")
        let receipt = try transfer.export(projectId: created.project.projectId,
            expectedSourceVersion: edited.sourceVersion, to: archive.path)
        XCTAssertEqual(receipt.fileCount, edited.fileCount)
        XCTAssertEqual(receipt.sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("source/data/fixtures.json")),
            Data("{\"value\":1}".utf8))
        let imported = try transfer.importSource(from: archive.path)
        XCTAssertNotEqual(imported.project.projectId, edited.project.projectId)
        XCTAssertNotEqual(imported.project.dashboardId, edited.project.dashboardId)
        XCTAssertEqual(imported.project.name, edited.project.name)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported.path)
            .appendingPathComponent("assets/icon.svg")), Data("<svg/>".utf8))
        XCTAssertEqual(try authoring.get(edited.project.projectId).sourceVersion,
            edited.sourceVersion, "import must not rewrite the original")
        XCTAssertEqual(try authoring.list().count, 2)
        XCTAssertTrue(try store.current()!.coverage.complete)
    }

    func testExternalOpenRequiresExplicitChoiceAndReportsBackupExclusion() throws {
        let (root, store, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Reference", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("outside-project")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: created.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let original = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        let changed = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "Outside", kind: original.kind, kitVersion: original.kitVersion,
            entry: original.entry, screenConfig: original.screenConfig)
        try WorkspaceJSON.encode(changed).write(to: descriptorURL)
        XCTAssertThrowsError(try transfer.openExternal(at: external.path, explicitExternal: false))
        let registered = try transfer.openExternal(at: external.path, explicitExternal: true)
        XCTAssertEqual(registered.projectId, changed.projectId)
        XCTAssertEqual(try store.resolveProject(registered.projectId), external.path)
        let coverage = try XCTUnwrap(store.current()).coverage
        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.externalProjectIds, [registered.projectId])
        XCTAssertTrue(coverage.notice.contains("Outside workspace backup coverage"))
    }

    func testExternalAdoptionPreservesIdentityAndOriginalWithContainedCoverage() throws {
        let (root, store, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Seed", kind: "web", trustedKitVersion: "kit-1")
        let external = root.appendingPathComponent("outside-project")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: created.path), to: external)
        let descriptorURL = external.appendingPathComponent("screenpunk.project.json")
        let original = try JSONDecoder().decode(WorkspaceProjectDocument.self,
            from: Data(contentsOf: descriptorURL))
        let changed = WorkspaceProjectDocument(schemaVersion: 1,
            projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
            name: "Outside", kind: original.kind, kitVersion: original.kitVersion,
            entry: original.entry, screenConfig: original.screenConfig)
        try WorkspaceJSON.encode(changed).write(to: descriptorURL)
        let registered = try transfer.openExternal(at: external.path, explicitExternal: true)
        let originalBytes = try Data(contentsOf: descriptorURL)
        let files = ["screenpunk.project.json": originalBytes,
                     "screen.json": try Data(contentsOf: external.appendingPathComponent("screen.json")),
                     "web/index.html": try Data(contentsOf: external.appendingPathComponent("web/index.html"))]
        let version = try WorkbenchSourceHasher.hash(files)
        XCTAssertThrowsError(try transfer.adoptExternal(projectId: registered.projectId,
            expectedSourceVersion: String(repeating: "0", count: 64), name: "Adopted"))
        let adopted = try transfer.adoptExternal(projectId: registered.projectId,
            expectedSourceVersion: version, name: "Adopted")
        XCTAssertEqual(adopted.projectId, registered.projectId)
        XCTAssertEqual(adopted.dashboardId, registered.dashboardId)
        XCTAssertTrue(try XCTUnwrap(store.resolveProject(adopted.projectId)).hasSuffix("/Screens/Adopted"))
        XCTAssertEqual(try Data(contentsOf: descriptorURL), originalBytes)
        XCTAssertTrue(try XCTUnwrap(store.resolveProject(adopted.projectId)).contains("/Screens/"))
        let current = try XCTUnwrap(store.current())
        XCTAssertTrue(current.coverage.complete)
        XCTAssertFalse(current.coverage.externalProjectIds.contains(registered.projectId))
        XCTAssertNil(try store.selection.current()?.externalBindings[registered.location.referenceId!])
    }

    func testImportRejectsUnknownNestedManifestField() throws {
        let (root, _, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Closed", kind: "web", trustedKitVersion: "kit-1")
        let archive = root.appendingPathComponent("closed.source")
        _ = try transfer.export(projectId: created.project.projectId,
            expectedSourceVersion: created.sourceVersion, to: archive.path)
        let manifestURL = archive.appendingPathComponent("source-archive.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var project = try XCTUnwrap(object["project"] as? [String: Any])
        project["unrecognizedAuthority"] = "ignored-by-Codable"
        object["project"] = project
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try transfer.importSource(from: archive.path))
    }

    func testImportRejectsUnlistedTopLevelMember() throws {
        let (root, _, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Closed", kind: "web", trustedKitVersion: "kit-1")
        let archive = root.appendingPathComponent("closed.source")
        _ = try transfer.export(projectId: created.project.projectId,
            expectedSourceVersion: created.sourceVersion, to: archive.path)
        try Data("extra".utf8).write(to: archive.appendingPathComponent("unlisted.txt"))
        XCTAssertThrowsError(try transfer.importSource(from: archive.path))
    }

    func testImportRejectsChangedSourceBytesWithoutRegisteringProject() throws {
        let (root, _, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Unchanged", kind: "web", trustedKitVersion: "kit-1")
        let archive = root.appendingPathComponent("source")
        _ = try transfer.export(projectId: created.project.projectId,
            expectedSourceVersion: created.sourceVersion, to: archive.path)
        try Data("changed".utf8).write(to: archive.appendingPathComponent("source/web/index.html"))
        XCTAssertThrowsError(try transfer.importSource(from: archive.path))
        XCTAssertEqual(try authoring.list().count, 1)
    }

    func testRetainedVersionExportsOriginalBytesAfterCurrentEdit() throws {
        let (root, _, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Versioned", kind: "web", trustedKitVersion: "kit-1")
        let originalHTML = try Data(contentsOf: URL(fileURLWithPath: created.path)
            .appendingPathComponent("web/index.html"))
        let edited = try authoring.patch(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>new</html>".utf8))])
        let archive = root.appendingPathComponent("retained.source")
        let receipt = try transfer.exportRetained(projectId: created.project.projectId,
            sourceVersion: created.sourceVersion, to: archive.path)
        XCTAssertEqual(receipt.sourceVersion, created.sourceVersion)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("source/web/index.html")),
            originalHTML)
        XCTAssertEqual(try authoring.get(created.project.projectId).sourceVersion, edited.sourceVersion)
    }

    func testExplicitImportDestinationKeepsProjectNameAndConflictsExactly() throws {
        let (root, _, authoring, transfer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Display Name", kind: "web", trustedKitVersion: "kit-1")
        let archive = root.appendingPathComponent("explicit.source")
        _ = try transfer.export(projectId: created.project.projectId,
            expectedSourceVersion: created.sourceVersion, to: archive.path)
        let imported = try transfer.importSource(from: archive.path, destinationName: "chosen-folder")
        XCTAssertEqual(imported.project.name, "Display Name")
        XCTAssertTrue(imported.path.hasSuffix("/Screens/chosen-folder"))
        XCTAssertThrowsError(try transfer.importSource(from: archive.path,
            destinationName: "chosen-folder"))
    }

    func testSelectionBoundDomainSourceExportImportRejectsStaleBinding() throws {
        let (root, store, authoring, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try authoring.create(name: "Bound", kind: "web", trustedKitVersion: "kit-1")
        let selected = try XCTUnwrap(store.current())
        let binding: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": selected.descriptor.workspaceId,
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        let domain = WorkbenchAuthoringRecoveryDomain(workspace: store, timeout: 120,
            mutationGate: {})
        let archive = root.appendingPathComponent("bound.source")
        let export = try WorkbenchAuthoringRecoveryRequest.parse(method: .projectSourceExport,
            params: binding.merging(["projectId": created.project.projectId,
                "sourceVersion": created.sourceVersion, "path": archive.path]) { _, new in new })
        XCTAssertEqual(try domain.perform(export).sourceArchive?.sourceVersion, created.sourceVersion)
        let imported = try WorkbenchAuthoringRecoveryRequest.parse(method: .projectSourceImport,
            params: binding.merging(["path": archive.path]) { _, new in new })
        XCTAssertNotEqual(try domain.perform(imported).project?.project.projectId,
            created.project.projectId)
        _ = try store.open(at: selected.path)
        XCTAssertThrowsError(try domain.perform(imported)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }
}
#endif
