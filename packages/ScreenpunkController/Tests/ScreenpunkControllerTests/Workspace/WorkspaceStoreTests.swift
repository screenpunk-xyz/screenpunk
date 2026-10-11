#if os(macOS)
import XCTest
import Foundation
import Darwin
@testable import ScreenpunkController

private struct FakeDocuments: WorkspaceDocumentsResolver {
    let path: String
    func documentsDirectory() throws -> URL { URL(fileURLWithPath: path, isDirectory: true) }
}

final class WorkspaceStoreTests: XCTestCase {
    private var temporary: URL!
    private var documents: URL!
    private var machine: URL!
    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath: "/private/tmp/sp-ws-" + UUID().uuidString.prefix(12))
        documents = temporary.appendingPathComponent("Fake Documents", isDirectory: true)
        machine = temporary.appendingPathComponent("Fake Machine", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { if let temporary { try FileManager.default.removeItem(at: temporary) } }
    private func store(machinePath: URL? = nil) throws -> WorkspaceStore {
        try WorkspaceStore(documents: FakeDocuments(path: documents.path), machineRootPath: (machinePath ?? machine).path)
    }
    private func folder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    private func project(_ name: String, relative: String, location: WorkspaceProjectLocation) -> WorkspaceProject {
        WorkspaceProject(projectId: UUID().uuidString.lowercased(), dashboardId: UUID().uuidString.lowercased(),
                         name: name, location: location)
    }
    private func source(_ entry: WorkspaceProject, root: String) throws {
        guard let relative = entry.location.path else { return }
        let directory = root + "/" + relative
        let source = directory + "/src"
        try folder(source)
        let descriptor: [String: Any] = ["schemaVersion": 1, "projectId": entry.projectId,
            "dashboardId": entry.dashboardId, "name": entry.name, "kind": "react",
            "kitVersion": "1.0.0", "entry": "src/App.tsx", "screenConfig": "screen.json"]
        let data = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: directory + "/screenpunk.project.json"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: directory + "/screen.json"))
        try Data("export const x=1;\n".utf8).write(to: URL(fileURLWithPath: source + "/App.tsx"))
        for path in [directory + "/screenpunk.project.json", directory + "/screen.json", source + "/App.tsx"] {
            XCTAssertEqual(chmod(path, 0o600), 0)
        }
    }
    private func write(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    private func expect(_ expected: WorkspaceError, _ action: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? WorkspaceError, expected, file: file, line: line)
        }
    }

    func testDefaultProposalCreationAndPortableLayout() throws {
        let subject = try store()
        XCTAssertNil(try subject.current())
        XCTAssertEqual(try subject.proposedPath(), documents.appendingPathComponent("Screenpunk").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try subject.proposedPath()))
        let opened = try subject.create()
        XCTAssertEqual(opened.path, documents.appendingPathComponent("Screenpunk").path)
        XCTAssertEqual(opened.descriptor.schemaVersion, 1)
        XCTAssertEqual(opened.descriptor.paths.screens, "Screens")
        XCTAssertEqual(opened.descriptor.paths.workbench, "Workbench")
        XCTAssertEqual(opened.selectionGeneration, 1)
        XCTAssertTrue(opened.coverage.complete)
        let descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: opened.path).appendingPathComponent("workspace.json"))) as! [String: Any]
        XCTAssertEqual(Set(descriptor.keys), ["schemaVersion", "workspaceId", "name", "generation", "paths", "defaults", "recovery"])
        for relative in ["Screens", "Workbench/Library/catalog.json", "Workbench/Settings/workbench.json",
                         "Workbench/Settings/connections.json", "Workbench/Toolchains/requirements.json",
                         "Workbench/History/Builds", "Workbench/History/Packages", "Workbench/Attachments"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path + "/" + relative))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path + "/devices"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path + "/approvals"))
    }
    func testExplicitRootAndRelocatedRestoreWithoutOldMachineState() throws {
        let original = temporary.appendingPathComponent("Café work space")
        let subject = try store()
        let created = try subject.create(at: original.path, name: "Café")
        XCTAssertEqual(created.path, original.path)
        let relative = try subject.nextContainedDestination(named: "Kitchen Café")
        XCTAssertEqual(relative, "Screens/kitchen-café")
        try folder(original.path + "/" + relative)
        let entry = project("Kitchen", relative: relative, location: .contained(relative))
        try source(entry, root: original.path)
        _ = try subject.registerContained(entry, expectedCatalogGeneration: 1)
        let retained = original.appendingPathComponent("Workbench/History/Packages/retained.bin")
        try Data("historical bytes".utf8).write(to: retained)
        XCTAssertEqual(chmod(retained.path, 0o600), 0)
        let relocated = temporary.appendingPathComponent("Restored 目录")
        try FileManager.default.copyItem(at: original, to: relocated)
        let freshMachine = temporary.appendingPathComponent("Another Machine")
        let restored = try store(machinePath: freshMachine)
        XCTAssertNil(try restored.current())
        let opened = try restored.open(at: relocated.path)
        XCTAssertEqual(opened.descriptor.workspaceId, created.descriptor.workspaceId)
        XCTAssertEqual(opened.selectionGeneration, 1)
        XCTAssertEqual(try restored.resolveProject(entry.projectId), relocated.path + "/" + relative)
        XCTAssertEqual(opened.historyAuthority, "historical-only")
        XCTAssertEqual(opened.authenticatedDeviceCount, 0)
        XCTAssertEqual(opened.localConnections, "unconfigured")
        XCTAssertTrue(opened.coverage.complete)
        XCTAssertEqual(try Data(contentsOf: relocated.appendingPathComponent("Workbench/History/Packages/retained.bin")), Data("historical bytes".utf8))
        XCTAssertGreaterThan(opened.coverage.includedBytes, 14)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testMalformedNewerDuplicateAndUnknownDescriptorRejectBeforeSelection() throws {
        let subject = try store(); let created = try subject.create()
        let source = URL(fileURLWithPath: created.path).appendingPathComponent("workspace.json")
        let original = try Data(contentsOf: source)
        let newer = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try write(newer, at: source)
        expect(.newerSchema) { _ = try subject.open(at: created.path) }
        let duplicate = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"generation\":1", with: "\"generation\":1,\"generation\":2")
        try write(duplicate, at: source)
        expect(.invalidSchema) { _ = try subject.open(at: created.path) }
        let unknown = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"generation\":1", with: "\"generation\":1,\"controllerToken\":\"no\"")
        try write(unknown, at: source)
        expect(.invalidSchema) { _ = try subject.open(at: created.path) }
        let malformed = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"generation\":1", with: "\"generation\":1.5")
        try write(malformed, at: source)
        expect(.invalidSchema) { _ = try subject.open(at: created.path) }
        try original.write(to: source, options: .atomic); XCTAssertEqual(chmod(source.path, 0o600), 0)
        XCTAssertEqual(try subject.current()?.descriptor.workspaceId, created.descriptor.workspaceId)
    }
    func testSymlinkTraversalCollisionAndNonemptyDestinationPreserved() throws {
        let subject = try store(); let created = try subject.create()
        let other = temporary.appendingPathComponent("Other")
        try folder(other.path)
        let alias = created.path + "/Screens/alias"
        XCTAssertEqual(symlink(other.path, alias), 0)
        let bad = project("Alias", relative: "Screens/alias", location: .contained("Screens/alias"))
        expect(.unsafeFile) { _ = try subject.registerContained(bad, expectedCatalogGeneration: 1) }
        expect(.invalidSchema) { try WorkspaceProjectLocation.contained("Screens/../Workbench").validate() }
        expect(.invalidSchema) { try WorkspaceProjectLocation.contained("Workbench/secret").validate() }
        try folder(created.path + "/Screens/regular")
        let one = project("One", relative: "Screens/regular", location: .contained("Screens/regular"))
        try source(one, root: created.path)
        let after = try subject.registerContained(one, expectedCatalogGeneration: 1)
        let colliding = project("Two", relative: "Screens/Regular", location: .contained("Screens/Regular"))
        expect(.invalidSchema) { _ = try subject.registerContained(colliding, expectedCatalogGeneration: after.catalog.generation) }
        expect(.conflict) { try WorkspaceCatalog(generation: 3, projects: [one, colliding]).validate() }
        XCTAssertEqual(try subject.current()?.catalog.generation, 2)
        let outside = temporary.appendingPathComponent("Existing destination")
        try folder(outside.path)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
        expect(.alreadyExists) { _ = try subject.create(at: outside.path) }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("sentinel")), Data("keep".utf8))
    }
    func testExternalCoverageAndNoBindingAuthorityAfterRestore() throws {
        let subject = try store(); let created = try subject.create()
        let external = temporary.appendingPathComponent("Outside 目录")
        try folder(external.path)
        XCTAssertEqual(chmod(external.path, 0o755), 0) // An ordinary user-selected project folder.
        let entry = project("External", relative: "", location: .external(UUID().uuidString.lowercased()))
        try writeProjectSource(entry, at: external.path, entryPath: "src/App.tsx")
        expect(.invalidPath) { _ = try subject.registerExternal(entry, sourcePath: external.path, explicitExternal: false, expectedCatalogGeneration: 1) }
        let reference = try XCTUnwrap(entry.location.referenceId)
        expect(.conflict) { _ = try subject.registerExternal(entry, sourcePath: external.path, explicitExternal: true, expectedCatalogGeneration: 0) }
        XCTAssertNil(try subject.selection.current()?.externalBindings[reference])
        let after = try subject.registerExternal(entry, sourcePath: external.path, explicitExternal: true, expectedCatalogGeneration: 1)
        XCTAssertEqual(after.selectionGeneration, 2)
        XCTAssertFalse(after.coverage.complete)
        XCTAssertEqual(after.coverage.externalProjectIds, [entry.projectId])
        XCTAssertEqual(after.coverage.unresolvedExternalProjectIds, [])
        XCTAssertTrue(after.coverage.notice.contains("Outside workspace backup coverage"))
        XCTAssertEqual(try subject.resolveProject(entry.projectId), external.path)
        let portable = try Data(contentsOf: URL(fileURLWithPath: created.path).appendingPathComponent("Workbench/Library/catalog.json"))
        XCTAssertFalse(String(decoding: portable, as: UTF8.self).contains(external.path))
        let restored = try store(machinePath: temporary.appendingPathComponent("Replacement Machine"))
        let reopened = try restored.open(at: created.path)
        XCTAssertFalse(reopened.coverage.complete)
        XCTAssertEqual(reopened.coverage.unresolvedExternalProjectIds, [entry.projectId])
        XCTAssertNil(try restored.resolveProject(entry.projectId))
        XCTAssertEqual(reopened.authenticatedDeviceCount, 0)
    }
    func testExternalRegistrationRejectsEmptyAncestorAndMismatchedSourceWithoutChangingState() throws {
        let subject = try store(); let created = try subject.create()
        let entry = project("External", relative: "", location: .external(UUID().uuidString.lowercased()))
        let initial = try XCTUnwrap(subject.selection.current())
        expect(.invalidPath) { _ = try subject.registerExternal(entry, sourcePath: documents.path,
            explicitExternal: true, expectedCatalogGeneration: 1) }
        for reserved in [created.path, created.path + "/Screens", machine.path] {
            expect(.invalidPath) { _ = try subject.registerExternal(entry, sourcePath: reserved,
                explicitExternal: true, expectedCatalogGeneration: 1) }
        }
        XCTAssertEqual(try subject.selection.current(), initial)
        XCTAssertEqual(try subject.current()?.catalog.projects.count, 0)

        let external = temporary.appendingPathComponent("Independent Source")
        try folder(external.path)
        expect(.unavailable) { _ = try subject.registerExternal(entry, sourcePath: external.path,
            explicitExternal: true, expectedCatalogGeneration: 1) }
        XCTAssertEqual(try subject.selection.current(), initial)
        try writeProjectSource(entry, at: external.path, entryPath: "src/App.tsx", projectId: UUID().uuidString.lowercased())
        expect(.invalidSchema) { _ = try subject.registerExternal(entry, sourcePath: external.path,
            explicitExternal: true, expectedCatalogGeneration: 1) }
        XCTAssertEqual(try subject.selection.current(), initial)
        XCTAssertEqual(try subject.current()?.catalog.projects.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path + "/Screens/External"))
    }

    func testRequiredExcludedEntryIsRejectedBeforeCatalogMutation() throws {
        let subject = try store(); let created = try subject.create()
        for (index, entryPath) in [".env", ".env.tsx", "node_modules/main.tsx", "dist/main.tsx", ".hidden/main.tsx"].enumerated() {
            let relative = "Screens/excluded-\(index)"
            let directory = created.path + "/" + relative
            try folder(directory)
            let project = self.project("Excluded", relative: relative, location: .contained(relative))
            try writeProjectSource(project, at: directory, entryPath: entryPath)
            expect(.invalidSchema) { _ = try subject.registerContained(project, expectedCatalogGeneration: 1) }
            XCTAssertEqual(try subject.current()?.catalog.projects.count, 0)
        }
    }

    func testRequiredEntryCannotBeIgnoredButAuxiliaryCan() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/ignored-entry"
        let directory = created.path + "/" + relative
        try folder(directory)
        let entry = project("Ignored", relative: relative, location: .contained(relative))
        try writeProjectSource(entry, at: directory, entryPath: "src/App.tsx")
        let ignore = URL(fileURLWithPath: directory + "/.screenpunkignore")
        try write("src/**\n", at: ignore)
        expect(.invalidSchema) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
        try write("*.json\n", at: ignore)
        expect(.invalidSchema) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
        try write("{}", at: URL(fileURLWithPath: directory + "/screenpunk.lock.json"))
        try write("screenpunk.lock.json\n", at: ignore)
        expect(.invalidSchema) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
        try write("notes/*.bak\n", at: ignore)
        try folder(directory + "/notes")
        try write("backup", at: URL(fileURLWithPath: directory + "/notes/old.bak"))
        let registered = try subject.registerContained(entry, expectedCatalogGeneration: 1)
        XCTAssertTrue(registered.coverage.complete)
        XCTAssertEqual(registered.coverage.omittedAuxiliaryPaths, [relative + "/notes/old.bak"])
    }

    func testExcludedSymlinkIsStillUnsafe() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/ignored-link"
        let directory = created.path + "/" + relative
        try folder(directory)
        let entry = project("Ignored link", relative: relative, location: .contained(relative))
        try writeProjectSource(entry, at: directory, entryPath: "src/App.tsx")
        let outside = temporary.appendingPathComponent("outside-secret")
        try write("private", at: outside)
        XCTAssertEqual(symlink(outside.path, directory + "/.env"), 0)
        expect(.unsafeFile) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
    }

    func testExternalBindingBecomesUnresolvedWhenProjectIdentityChanges() throws {
        let subject = try store(); _ = try subject.create()
        let external = temporary.appendingPathComponent("Identity Source")
        try folder(external.path)
        let entry = project("External", relative: "", location: .external(UUID().uuidString.lowercased()))
        try writeProjectSource(entry, at: external.path, entryPath: "src/App.tsx")
        _ = try subject.registerExternal(entry, sourcePath: external.path, explicitExternal: true, expectedCatalogGeneration: 1)
        XCTAssertEqual(try subject.resolveProject(entry.projectId), external.path)
        let descriptor = external.appendingPathComponent("screenpunk.project.json")
        let original = try String(contentsOf: descriptor, encoding: .utf8)
        try write(original.replacingOccurrences(of: entry.projectId, with: UUID().uuidString.lowercased()), at: descriptor)
        XCTAssertNil(try subject.resolveProject(entry.projectId))
        XCTAssertEqual(try subject.current()?.coverage.unresolvedExternalProjectIds, [entry.projectId])
    }

    func testExternalRegistrationRequiresValidScreenConfigAndEntryFile() throws {
        let subject = try store(); _ = try subject.create()
        let external = temporary.appendingPathComponent("Source Format")
        try folder(external.path)
        let entry = project("External", relative: "", location: .external(UUID().uuidString.lowercased()))
        try writeProjectSource(entry, at: external.path, entryPath: "src/App.tsx")
        let initial = try XCTUnwrap(subject.selection.current())
        let config = external.appendingPathComponent("screen.json")
        try write("[]", at: config)
        expect(.invalidSchema) { _ = try subject.registerExternal(entry, sourcePath: external.path,
            explicitExternal: true, expectedCatalogGeneration: 1) }
        try write("{}", at: config)
        try FileManager.default.removeItem(at: external.appendingPathComponent("src/App.tsx"))
        expect(.unsafeFile) { _ = try subject.registerExternal(entry, sourcePath: external.path,
            explicitExternal: true, expectedCatalogGeneration: 1) }
        XCTAssertEqual(try subject.selection.current(), initial)
        XCTAssertEqual(try subject.current()?.catalog.projects.count, 0)
    }

    func testReactEntrypointRejectsUnsupportedFormat() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/wrong-format"
        let directory = created.path + "/" + relative
        try folder(directory)
        let entry = project("Wrong format", relative: relative, location: .contained(relative))
        try writeProjectSource(entry, at: directory, entryPath: "src/App.json")
        expect(.invalidSchema) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
    }

    func testIgnoredMemberFanoutHitsSourceTraversalLimit() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/fanout"
        let directory = created.path + "/" + relative
        try folder(directory)
        let entry = project("Fanout", relative: relative, location: .contained(relative))
        try writeProjectSource(entry, at: directory, entryPath: "src/App.tsx")
        for index in 0..<2_100 {
            let path = directory + "/.env.omitted-\(index)"
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { close(fd) }
        }
        expect(.limitExceeded) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
        let catalog = try Data(contentsOf: URL(fileURLWithPath: created.path + "/Workbench/Library/catalog.json"))
        XCTAssertFalse(String(decoding: catalog, as: UTF8.self).contains(entry.projectId))
    }

    func testEmptyDirectoryFanoutHitsSourceTraversalLimit() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/empty-fanout"
        let directory = created.path + "/" + relative
        try folder(directory)
        let entry = project("Fanout", relative: relative, location: .contained(relative))
        try writeProjectSource(entry, at: directory, entryPath: "src/App.tsx")
        for index in 0..<2_100 { try folder(directory + "/empty-\(index)") }
        expect(.limitExceeded) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
    }

    func testRetainedTraversalBudgetCountsEmptyDirectories() throws {
        let subject = try store(); let created = try subject.create()
        let attachments = created.path + "/Workbench/Attachments"
        try folder(attachments + "/one")
        try folder(attachments + "/two")
        let root = try WorkspaceFiles(path: created.path)
        expect(.limitExceeded) { _ = try root.inventory(["Workbench", "Attachments"], retained: true, memberLimit: 1) }
    }

    func testPortableInventoryCollisionPredicateForSourceAndRetainedPaths() throws {
        var source = WorkspacePathCollisionDetector()
        try source.insert("src/Foo.tsx")
        expect(.conflict) { try source.insert("src/foo.tsx") }
        var retained = WorkspacePathCollisionDetector()
        try retained.insert("History/Packages/Café/record.json")
        expect(.conflict) { try retained.insert("History/Packages/Cafe\u{301}/record.json") }
        var distinct = WorkspacePathCollisionDetector()
        try distinct.insert("src/Foo.tsx")
        XCTAssertNoThrow(try distinct.insert("assets/foo.tsx"))
    }

    private func writeProjectSource(_ project: WorkspaceProject, at directory: String,
                                    entryPath: String, projectId: String? = nil) throws {
        let descriptor: [String: Any] = ["schemaVersion": 1, "projectId": projectId ?? project.projectId,
            "dashboardId": project.dashboardId, "name": project.name, "kind": "react",
            "kitVersion": "1.0.0", "entry": entryPath, "screenConfig": "screen.json"]
        try write(String(data: JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys]), encoding: .utf8)!,
                  at: URL(fileURLWithPath: directory + "/screenpunk.project.json"))
        try write("{}", at: URL(fileURLWithPath: directory + "/screen.json"))
        let parts = entryPath.split(separator: "/").map(String.init)
        if parts.count > 1 {
            var path = directory
            for part in parts.dropLast() { path += "/" + part; try folder(path) }
        }
        try write("export const x = 1;", at: URL(fileURLWithPath: directory + "/" + entryPath))
    }
    func testEscapedDuplicateKeyRejectsAndRetainedSymlinkBlocksSelection() throws {
        let subject = try store(); let created = try subject.create()
        let root = URL(fileURLWithPath: created.path)
        let descriptor = root.appendingPathComponent("workspace.json")
        let original = try Data(contentsOf: descriptor)
        let duplicate = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"generation\":1", with: "\"generation\":1,\"genera\u{0074}ion\":2")
        // The raw spelling differs, but both JSON keys decode to the same field.
        let wireDuplicate = duplicate.replacingOccurrences(of: "generation\":2", with: "genera\\u0074ion\":2")
        try write(wireDuplicate, at: descriptor)
        expect(.invalidSchema) { _ = try subject.open(at: created.path) }
        try original.write(to: descriptor, options: .atomic); XCTAssertEqual(chmod(descriptor.path, 0o600), 0)
        let outside = temporary.appendingPathComponent("outside")
        try Data("no follow".utf8).write(to: outside)
        let retained = root.appendingPathComponent("Workbench/History/Builds/escape")
        XCTAssertEqual(symlink(outside.path, retained.path), 0)
        let overview = try subject.inspect(at: created.path)
        XCTAssertFalse(overview.coverage.complete)
        XCTAssertEqual(overview.coverage.missingPaths, ["Workbench"])
        expect(.incomplete) { _ = try subject.open(at: created.path) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("no follow".utf8))
    }
    func testOversizedProjectSourceFailsWithoutCatalogMutation() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/large"
        try folder(created.path + "/" + relative)
        let entry = project("Large", relative: relative, location: .contained(relative))
        try source(entry, root: created.path)
        let extra = created.path + "/" + relative + "/oversized.bin"
        let file = open(extra, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(file, 0)
        XCTAssertEqual(ftruncate(file, 5 * 1024 * 1024 + 1), 0)
        close(file)
        expect(.unsafeFile) { _ = try subject.registerContained(entry, expectedCatalogGeneration: 1) }
        XCTAssertEqual(try subject.current()?.catalog.generation, 1)
        XCTAssertEqual(try subject.current()?.catalog.projects.count, 0)
    }
    func testPendingJournalOrNewerCatalogStopsOpenWithoutSelectionChange() throws {
        let subject = try store(); let created = try subject.create()
        let initial = try XCTUnwrap(subject.selection.current())
        let root = URL(fileURLWithPath: created.path)
        let journal = root.appendingPathComponent("Workbench/Transactions/pending.json")
        try Data("untrusted".utf8).write(to: journal)
        expect(.incomplete) { _ = try subject.open(at: created.path) }
        XCTAssertEqual(try subject.selection.current(), initial)
        try FileManager.default.removeItem(at: journal)
        let catalog = root.appendingPathComponent("Workbench/Library/catalog.json")
        let original = try Data(contentsOf: catalog)
        var futureCatalog = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        futureCatalog["schemaVersion"] = try XCTUnwrap(futureCatalog["schemaVersion"] as? Int) + 1
        // Keep the legacy closed shape so the version-specific decoder reaches its future-version guard.
        futureCatalog.removeValue(forKey: "archivedDashboardIds")
        let newer = try JSONSerialization.data(withJSONObject: futureCatalog, options: [.sortedKeys])
        try newer.write(to: catalog, options: .atomic); XCTAssertEqual(chmod(catalog.path, 0o600), 0)
        expect(.newerSchema) { _ = try subject.open(at: created.path) }
        XCTAssertEqual(try subject.selection.current(), initial)
        try original.write(to: catalog, options: .atomic); XCTAssertEqual(chmod(catalog.path, 0o600), 0)
    }
    func testPortablePathCollisionUsesUnicodeCanonicalForms() throws {
        let one = project("One", relative: "Screens/café", location: .contained("Screens/café"))
        let two = project("Two", relative: "Screens/cafe\u{301}", location: .contained("Screens/cafe\u{301}"))
        expect(.conflict) { try WorkspaceCatalog(generation: 1, projects: [one, two]).validate() }
        XCTAssertFalse(WorkspaceValidation.member("Screens/../Workbench"))
        XCTAssertFalse(WorkspaceValidation.member("C:/outside"))
        XCTAssertFalse(WorkspaceValidation.absolute("/private/tmp/../escape"))
    }
    func testIncludedSourceInventoryAndUnsafeExtraSymlink() throws {
        let subject = try store(); let created = try subject.create()
        let relative = "Screens/inventory"
        try folder(created.path + "/" + relative)
        let entry = project("Inventory", relative: relative, location: .contained(relative))
        try source(entry, root: created.path)
        try Data("private auxiliary".utf8).write(to: URL(fileURLWithPath: created.path + "/" + relative + "/.env"))
        try Data("private auxiliary".utf8).write(to: URL(fileURLWithPath: created.path + "/" + relative + "/.env.local"))
        let registered = try subject.registerContained(entry, expectedCatalogGeneration: 1)
        XCTAssertTrue(registered.coverage.complete)
        XCTAssertGreaterThan(registered.coverage.includedBytes, 0)
        XCTAssertEqual(registered.coverage.omittedAuxiliaryPaths, [relative + "/.env", relative + "/.env.local"])
        let outside = temporary.appendingPathComponent("outside-file")
        try Data("elsewhere".utf8).write(to: outside)
        XCTAssertEqual(symlink(outside.path, created.path + "/" + relative + "/escape"), 0)
        let inspected = try subject.inspect(at: created.path)
        XCTAssertFalse(inspected.coverage.complete)
        XCTAssertEqual(inspected.coverage.missingPaths, [relative])
        expect(.incomplete) { _ = try subject.open(at: created.path) }
    }
    func testConcurrentCatalogCASSelectionGenerationAndSettingsRollback() throws {
        let subject = try store(); let created = try subject.create()
        try folder(created.path + "/Screens/one")
        try folder(created.path + "/Screens/two")
        let entries = [project("One", relative: "Screens/one", location: .contained("Screens/one")),
                       project("Two", relative: "Screens/two", location: .contained("Screens/two"))]
        try source(entries[0], root: created.path); try source(entries[1], root: created.path)
        let resultLock = NSLock(); var successes = 0, conflicts = 0
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do { _ = try subject.registerContained(entries[index], expectedCatalogGeneration: 1); resultLock.lock(); successes += 1; resultLock.unlock() }
            catch WorkspaceError.conflict { resultLock.lock(); conflicts += 1; resultLock.unlock() }
            catch { XCTFail("Unexpected metadata result: \(error)") }
        }
        XCTAssertEqual(successes, 1); XCTAssertEqual(conflicts, 1)
        XCTAssertEqual(try subject.current()?.catalog.generation, 2)
        XCTAssertEqual(try subject.current()?.catalog.projects.count, 1)
        let oldSettings = try subject.current()!.settings
        expect(.invalidSchema) { _ = try subject.updateSettings(["secret": "not portable"], profiles: [:], expectedGeneration: oldSettings.generation) }
        XCTAssertEqual(try subject.current()?.settings, oldSettings)
        DispatchQueue.concurrentPerform(iterations: 5) { _ in
            do { _ = try subject.open(at: created.path) } catch { XCTFail("Unexpected selection error: \(error)") }
        }
        XCTAssertEqual(try subject.current()?.selectionGeneration, 6)
        XCTAssertEqual(try subject.current()?.catalog.projects.count, 1)
    }
}
#endif
