import XCTest
import Foundation
import ScreenpunkCore
@testable import ScreenpunkController

#if os(macOS)
private struct AuthoringDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}

final class WorkbenchContainedAuthoringTests: XCTestCase {
    func testSourceHashV1GoldenVectorAndPortableCollision() throws {
        XCTAssertEqual(try WorkbenchSourceHasher.hash(["src/App.tsx": Data("export const x=1;\n".utf8)]),
                       "2a585cae32005b29e9d6883fbf3af99e77f1d52ff6fb0ed61692afc15e915130")
        let files = ["screen.json": Data("{}".utf8), "web/index.html": Data("<html/>".utf8)]
        XCTAssertEqual(try WorkbenchSourceHasher.hash(files),
                       "d277dc1169ca97f1a2f8b0efd3513bf8b05bf18524d6c6db0b42591a96c7cd02")
        XCTAssertThrowsError(try WorkbenchSourceHasher.hash([
            "data/Value.json": Data("a".utf8), "data/value.json": Data("b".utf8)]))
    }

    func testSourceHashRejectsProjectLargerThan25MiBBeforeCommit() {
        let files = Dictionary(uniqueKeysWithValues: (0..<6).map {
            ("data/part-\($0).txt", Data(repeating: UInt8(65 + $0), count: 5 * 1024 * 1024))
        })
        XCTAssertThrowsError(try WorkbenchSourceHasher.hash(files)) {
            XCTAssertEqual($0 as? WorkspaceError, .limitExceeded)
        }
    }

    private final class Fixture {
        let root: URL
        let store: WorkspaceStore
        let domain: WorkbenchContainedAuthoring
        let visible: URL
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/sp-authoring-" + UUID().uuidString.prefix(10))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let documents = root.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
            store = try WorkspaceStore(documents: AuthoringDocuments(path: documents),
                                       machineRootPath: root.appendingPathComponent("machine").path)
            visible = root.appendingPathComponent("visible")
            _ = try store.create(at: visible.path)
            domain = WorkbenchContainedAuthoring(workspace: store)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testCreatePatchHistoryAndReopenWithoutOldSelection() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let created = try fixture.domain.create(name: "Kitchen", kind: "react", trustedKitVersion: "1.0.0")
        XCTAssertTrue(created.path.hasSuffix("/Screens/kitchen"))
        XCTAssertEqual(created.sourceHashVersion, 1)
        XCTAssertEqual(try fixture.domain.list().map(\.projectId), [created.project.projectId])
        XCTAssertEqual(try fixture.domain.versions(created.project.projectId).map(\.sourceVersion), [created.sourceVersion])
        let edited = try fixture.domain.patch(created.project.projectId, expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "src/main.tsx", bytes: Data("export const text = 'changed';\n".utf8)),
                      .init(path: "data/fixture.json", bytes: Data("{\"sample\":true}".utf8))])
        XCTAssertNotEqual(edited.sourceVersion, created.sourceVersion)
        XCTAssertEqual(try fixture.domain.versions(created.project.projectId).count, 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: edited.path + "/data/fixture.json")), "{\"sample\":true}")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.copyItem(at: fixture.visible, to: backup)
        let restored = try WorkspaceStore(documents: AuthoringDocuments(path: fixture.root.appendingPathComponent("Documents")),
                                          machineRootPath: fixture.root.appendingPathComponent("fresh-machine").path)
        XCTAssertNil(try restored.current())
        _ = try restored.open(at: backup.path)
        let recovered = WorkbenchContainedAuthoring(workspace: restored)
        XCTAssertEqual(try recovered.get(created.project.projectId).sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try recovered.versions(created.project.projectId).count, 2)
    }

    func testTwoCreatesEditPackageImportAndReopen() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = try fixture.domain.create(name: "First", kind: "web", trustedKitVersion: "1.0.0")
        let second = try fixture.domain.create(name: "Second", kind: "react", trustedKitVersion: "1.0.0")
        let edited = try fixture.domain.patch(first.project.projectId, expectedSourceVersion: first.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>edited</html>".utf8))])
        let file = Data("<html>package</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Package", revision: UUID().uuidString.lowercased(),
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1, orientation: "landscape"),
            connections: [], files: [ManifestFile(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let packages = WorkbenchPortablePackages(workspace: fixture.store)
        _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": file]))
        let backup = fixture.root.appendingPathComponent("mixed-backup")
        try FileManager.default.copyItem(at: fixture.visible, to: backup)
        let restored = try WorkspaceStore(documents: AuthoringDocuments(path: fixture.root.appendingPathComponent("Documents")),
                                          machineRootPath: fixture.root.appendingPathComponent("mixed-machine").path)
        _ = try restored.open(at: backup.path)
        let reopened = WorkbenchContainedAuthoring(workspace: restored)
        XCTAssertEqual(Set(try reopened.list().map(\.projectId)), Set([first.project.projectId, second.project.projectId]))
        XCTAssertEqual(try reopened.get(first.project.projectId).sourceVersion, edited.sourceVersion)
        XCTAssertEqual(try reopened.get(second.project.projectId).sourceVersion, second.sourceVersion)
        XCTAssertEqual(try reopened.versions(first.project.projectId).count, 2)
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: restored).get(
            dashboardId: manifest.dashboardId, revision: manifest.revision).files["index.html"], file)
    }

    func testBoundedSourceReadRejectsStaleWorkspaceSelectionAndExcludedFiles() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = try fixture.domain.create(name: "First", kind: "web", trustedKitVersion: "1.0.0")
        let initial = try XCTUnwrap(fixture.store.current())
        let generation = try XCTUnwrap(initial.selectionGeneration)
        let read = try fixture.domain.readText(first.project.projectId, path: "web/index.html",
            expectedWorkspaceId: initial.descriptor.workspaceId,
            expectedSelectionGeneration: generation)
        XCTAssertEqual(read.sourceVersion, first.sourceVersion)
        XCTAssertTrue(read.text.contains("New screen"))
        XCTAssertThrowsError(try fixture.domain.readText(first.project.projectId, path: "screenpunk.project.json",
            expectedWorkspaceId: initial.descriptor.workspaceId,
            expectedSelectionGeneration: generation))
        XCTAssertThrowsError(try fixture.domain.readText(first.project.projectId, path: ".env.local",
            expectedWorkspaceId: initial.descriptor.workspaceId,
            expectedSelectionGeneration: generation))
        _ = try fixture.store.create(at: fixture.root.appendingPathComponent("second-visible").path)
        XCTAssertThrowsError(try fixture.domain.readText(first.project.projectId, path: "web/index.html",
            expectedWorkspaceId: initial.descriptor.workspaceId,
            expectedSelectionGeneration: generation))
    }

    func testSourceChunksBindEveryPageToFullSourceVersionAndSelectedWorkspace() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let created = try fixture.domain.create(name: "Chunks", kind: "web", trustedKitVersion: "1.0.0")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let edited = try fixture.domain.patch(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "data/large.txt", bytes: bytes)])
        let selected = try XCTUnwrap(fixture.store.current())
        let generation = try XCTUnwrap(selected.selectionGeneration)
        func request(_ offset: Int, version: String = edited.sourceVersion) throws -> WorkbenchSourceChunkRequest {
            try .init(expectedWorkspaceId: selected.descriptor.workspaceId,
                expectedSelectionGeneration: generation, projectId: created.project.projectId,
                path: "data/large.txt", expectedSourceVersion: version, offset: offset)
        }
        var downloaded = Data(), offset = 0
        repeat {
            let asked = try request(offset)
            let chunk = try fixture.domain.readChunk(asked)
            try chunk.validate(for: asked)
            downloaded.append(try XCTUnwrap(Data(base64Encoded: chunk.bytesBase64)))
            offset = chunk.nextOffset
            XCTAssertEqual(chunk.fileBytes, bytes.count)
            XCTAssertEqual(chunk.fileSHA256, WorkbenchTransactionDigest.hex(bytes))
            if chunk.complete { break }
        } while true
        XCTAssertEqual(downloaded, bytes)
        XCTAssertEqual(offset, bytes.count)
        let oldPage = try request(64 * 1024)
        _ = try fixture.domain.patch(created.project.projectId,
            expectedSourceVersion: edited.sourceVersion,
            changes: [.init(path: "data/large.txt", bytes: Data(repeating: 7, count: 200_000))])
        XCTAssertThrowsError(try fixture.domain.readChunk(oldPage)) {
            XCTAssertEqual($0 as? WorkspaceError, .conflict)
        }
        XCTAssertThrowsError(try WorkbenchSourceChunkRequest(expectedWorkspaceId: selected.descriptor.workspaceId,
            expectedSelectionGeneration: generation, projectId: created.project.projectId,
            path: "../outside", expectedSourceVersion: edited.sourceVersion, offset: 0))
        let wire: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": selected.descriptor.workspaceId,
            "expectedSelectionGeneration": generation,
            "projectId": created.project.projectId,
            "path": "data/large.txt", "expectedSourceVersion": edited.sourceVersion,
            "offset": 0]
        XCTAssertEqual(try WorkbenchSourceChunkRequest.parse(wire).path, "data/large.txt")
        for (field, value) in [("role", "gui" as Any), ("approvalMode", "scripted" as Any),
                               ("schemaVersion", 2 as Any), ("offset", true as Any)] {
            var invalid = wire; invalid[field] = value
            XCTAssertThrowsError(try WorkbenchSourceChunkRequest.parse(invalid))
        }
        _ = try fixture.store.create(at: fixture.root.appendingPathComponent("second-visible-chunks").path)
        XCTAssertThrowsError(try fixture.domain.readChunk(oldPage))
    }

    func testHistoryMetadataMustMatchVerifiedDescriptor() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let created = try fixture.domain.create(name: "History", kind: "web", trustedKitVersion: "1.0.0")
        let metadata = fixture.visible.appendingPathComponent("Workbench/History/Builds/\(created.sourceVersion)/source/.screenpunk-snapshot.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object["dashboardId"] = UUID().uuidString.lowercased()
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: metadata)
        XCTAssertThrowsError(try fixture.domain.versions(created.project.projectId)) { error in
            XCTAssertEqual(error as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try fixture.domain.get(created.project.projectId).sourceVersion, created.sourceVersion)
    }

    func testAuthoringAndPackageReadsHonorOneExpiredDeadlineBehindSelectionLock() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let created = try fixture.domain.create(name: "Deadline", kind: "web", trustedKitVersion: "1.0.0")
        let lock = open(fixture.root.appendingPathComponent("machine/.screenpunk.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        XCTAssertThrowsError(try fixture.domain.versions(created.project.projectId, deadline: deadline))
        XCTAssertThrowsError(try WorkbenchPortablePackages(workspace: fixture.store).list(deadline: deadline))
    }

    func testStaleVersionCannotOverwriteSecondEditAndExcludedPathIsRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let created = try fixture.domain.create(name: "Web", kind: "web", trustedKitVersion: "1.0.0")
        let first = try fixture.domain.patch(created.project.projectId, expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>first</html>".utf8))])
        XCTAssertThrowsError(try fixture.domain.patch(created.project.projectId, expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "web/index.html", bytes: Data("<html>stale</html>".utf8))])) { error in
            XCTAssertEqual(error as? WorkspaceError, .conflict)
        }
        XCTAssertEqual(try fixture.domain.get(created.project.projectId).sourceVersion, first.sourceVersion)
        XCTAssertThrowsError(try fixture.domain.patch(created.project.projectId, expectedSourceVersion: first.sourceVersion,
            changes: [.init(path: ".env.local", bytes: Data("secret".utf8))]))
        XCTAssertThrowsError(try fixture.domain.patch(created.project.projectId, expectedSourceVersion: first.sourceVersion,
            changes: [.init(path: "data/Value.json", bytes: Data("{}".utf8)),
                      .init(path: "data/value.json", bytes: Data("{}".utf8))]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path + "/.env.local"))
        XCTAssertEqual(try fixture.domain.versions(created.project.projectId).count, 2)
    }

    func testOpenRegistersCompleteOrphanContainedFolder() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let root = try WorkspaceFiles(path: fixture.visible.path)
        let folder = try root.directory(["Screens", "orphan"], create: true)
        defer { close(folder) }
        let code = try root.directory(["Screens", "orphan", "web"], create: true)
        defer { close(code) }
        let id = UUID().uuidString.lowercased(), dashboard = UUID().uuidString.lowercased()
        let descriptor = WorkspaceProjectDocument(schemaVersion: 1, projectId: id,
            dashboardId: dashboard, name: "Orphan", kind: "web", kitVersion: "1.0.0",
            entry: "web/index.html", screenConfig: "screen.json")
        try root.write(folder, "screenpunk.project.json", data: WorkspaceJSON.encode(descriptor), expected: nil)
        try root.write(folder, "screen.json", data: Data("{\"connections\":[]}".utf8), expected: nil)
        try root.write(code, "index.html", data: Data("<html>orphan</html>".utf8), expected: nil)
        let opened = try fixture.domain.openContained(at: fixture.visible.appendingPathComponent("Screens/orphan").path)
        XCTAssertEqual(opened.project.projectId, id)
        XCTAssertEqual(try fixture.domain.versions(id).count, 1)
        XCTAssertThrowsError(try fixture.domain.openContained(at: fixture.visible.appendingPathComponent("Screens/orphan").path))
    }

    func testInterruptedCreateHistoryRemainsInertUntilExplicitOrphanRegistration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let root = try WorkspaceFiles(path: fixture.visible.path)
        let folder = try root.directory(["Screens", "pending"], create: true); defer { close(folder) }
        let code = try root.directory(["Screens", "pending", "web"], create: true); defer { close(code) }
        let project = WorkspaceProject(projectId: UUID().uuidString.lowercased(),
            dashboardId: UUID().uuidString.lowercased(), name: "Pending", location: .contained("Screens/pending"))
        let descriptor = WorkspaceProjectDocument(schemaVersion: 1, projectId: project.projectId,
            dashboardId: project.dashboardId, name: project.name, kind: "web", kitVersion: "1.0.0",
            entry: "web/index.html", screenConfig: "screen.json")
        let files = ["screenpunk.project.json": try WorkspaceJSON.encode(descriptor),
                     "screen.json": Data("{}".utf8), "web/index.html": Data("<html>pending</html>".utf8)]
        try root.write(folder, "screenpunk.project.json", data: files["screenpunk.project.json"]!, expected: nil)
        try root.write(folder, "screen.json", data: files["screen.json"]!, expected: nil)
        try root.write(code, "index.html", data: files["web/index.html"]!, expected: nil)
        let version = try WorkbenchSourceHasher.hash(files)
        let metadata = WorkbenchSourceHistoryEntry(sourceVersion: version, sourceHashVersion: 1,
            projectId: project.projectId, dashboardId: project.dashboardId,
            files: files.keys.sorted().map { .init(path: $0, sha256: WorkbenchTransactionDigest.hex(files[$0]!),
                                                   bytes: files[$0]!.count) })
        var payloads = files
        payloads[".screenpunk-snapshot.json"] = try JSONEncoder().encode(metadata)
        let overview = try XCTUnwrap(fixture.store.current())
        let operations = payloads.keys.sorted().map { member -> WorkbenchTransactionOperation in
            let bytes = payloads[member]!
            return .init(target: .history("buildSource", version, member), before: .absent,
                         after: .present(bytes), recoveryBlobHash: WorkbenchTransactionDigest.hex(bytes))
        }
        let journal = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: UUID().uuidString.lowercased(),
            workspaceId: overview.descriptor.workspaceId, kind: .historyPublish,
            expectedGeneration: overview.descriptor.generation, operations: operations)
        let blobs = Dictionary(uniqueKeysWithValues: payloads.values.map { (WorkbenchTransactionDigest.hex($0), $0) })
        let engine = WorkbenchTransactionEngine(selection: fixture.store.selection)
        try engine.prepare(journal, blobs: blobs)
        try engine.commit(journal.transactionId)
        XCTAssertTrue(try fixture.domain.list().isEmpty)
        let opened = try fixture.domain.openContained(at: fixture.visible.appendingPathComponent("Screens/pending").path)
        XCTAssertEqual(opened.sourceVersion, version)
        XCTAssertEqual(try fixture.domain.versions(project.projectId).map(\.sourceVersion), [version])
        let current = try XCTUnwrap(fixture.store.current())
        _ = try fixture.store.updateSettings(["theme": "dark"], profiles: [:],
            expectedGeneration: current.settings.generation)
        let aligned = try XCTUnwrap(fixture.store.current())
        XCTAssertEqual(aligned.catalog.generation, aligned.descriptor.generation)
        XCTAssertEqual(aligned.settings.generation, aligned.descriptor.generation)
    }

    func testVerifiedImmutablePackageImportRejectsCorruptionBeforeHistoryChange() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let packages = WorkbenchPortablePackages(workspace: fixture.store)
        let file = Data("<html><main>Demo</main></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Demo",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480, scale: 1,
                                   orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: file.count,
                                 sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let imported = try packages.importVerified(.init(manifest: manifest, files: ["index.html": file]))
        XCTAssertFalse(imported.sourceReconstructible)
        XCTAssertEqual(imported.files["index.html"], file)
        XCTAssertEqual(try packages.list().map(\.revision), [manifest.revision])
        XCTAssertEqual(try packages.exportVerified(dashboardId: manifest.dashboardId,
                                                   revision: manifest.revision).files, imported.files)
        let originalGeneration = try XCTUnwrap(fixture.store.current()).descriptor.generation
        var bad = manifest
        bad.revision = UUID().uuidString.lowercased()
        bad.digest = try DeploymentDigest.digest(for: bad)
        XCTAssertThrowsError(try packages.importVerified(.init(manifest: bad,
            files: ["index.html": Data("tampered".utf8)])))
        XCTAssertEqual(try XCTUnwrap(fixture.store.current()).descriptor.generation, originalGeneration)
        XCTAssertEqual(try packages.list().count, 1)
    }

    func testContainedInterruptedEditReplaysBeforeExplicitOpen() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let created = try fixture.domain.create(name: "Recover", kind: "web", trustedKitVersion: "1.0.0")
        let old = try Data(contentsOf: URL(fileURLWithPath: created.path + "/web/index.html"))
        let after = Data("<html>recovered</html>".utf8)
        let descriptor = try XCTUnwrap(fixture.store.current()).descriptor
        let journal = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: UUID().uuidString.lowercased(),
            workspaceId: descriptor.workspaceId, kind: .projectEdit, expectedGeneration: descriptor.generation,
            operations: [.init(target: .project(created.project.projectId, "web/index.html"),
                               before: .present(old), after: .present(after),
                               recoveryBlobHash: WorkbenchTransactionDigest.hex(after))])
        let engine = WorkbenchTransactionEngine(selection: fixture.store.selection, checkpoint: { point in
            if point == .memberPublished(0) { throw WorkspaceError.unavailable }
        })
        try engine.prepare(journal, blobs: [WorkbenchTransactionDigest.hex(after): after])
        XCTAssertThrowsError(try engine.commit(journal.transactionId))
        let fresh = try WorkspaceStore(documents: AuthoringDocuments(path: fixture.root.appendingPathComponent("Documents")),
                                       machineRootPath: fixture.root.appendingPathComponent("fresh-machine").path)
        XCTAssertThrowsError(try fresh.open(at: fixture.visible.path))
        let recovery = WorkbenchContainedAuthoring(workspace: fresh)
        XCTAssertEqual(try recovery.recoverContainedBeforeOpen(at: fixture.visible.path), [journal.transactionId])
        _ = try fresh.open(at: fixture.visible.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: created.path + "/web/index.html")), after)
    }
}
#endif
