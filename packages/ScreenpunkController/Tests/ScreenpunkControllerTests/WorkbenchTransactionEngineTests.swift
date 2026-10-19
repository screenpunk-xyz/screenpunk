#if os(macOS)
import Foundation
import Darwin
import XCTest
@testable import ScreenpunkController

final class WorkbenchTransactionEngineTests: XCTestCase {
    func testMutationGuardRejectsMismatchedRetainedParentBeforeAnyLeafMutation() {
        let root = WorkspaceNodeID(device: 1, inode: 1)
        let expectedParent = WorkspaceNodeID(device: 1, inode: 2)
        let otherParent = WorkspaceNodeID(device: 1, inode: 3)
        let leaf = WorkspaceNodeID(device: 1, inode: 4)
        let present = WorkbenchTransactionImage(state: "present", sha256: String(repeating: "a", count: 64), bytes: 1)
        for (image, node) in [(WorkbenchTransactionImage.absent, nil), (present, leaf)] {
            let binding = WorkbenchMutationGuard(ancestry: [root, expectedParent], image: image, node: node)
            var mutationIssued = false
            if binding.permits(currentAncestry: [root, expectedParent], retainedParent: otherParent,
                               currentImage: image, currentNode: node) { mutationIssued = true }
            XCTAssertFalse(mutationIssued, "creation, replacement and deletion need the retained parent identity")
            XCTAssertFalse(binding.permits(currentAncestry: [root, otherParent], retainedParent: expectedParent,
                                           currentImage: image, currentNode: node))
            XCTAssertTrue(binding.permits(currentAncestry: [root, expectedParent], retainedParent: expectedParent,
                                          currentImage: image, currentNode: node))
        }
    }

    func testOneProjectJournalGrammarAndRepeatedBlobPublicationBudget() throws {
        let hash = String(repeating: "a", count: 64)
        let after = WorkbenchTransactionImage(state: "present", sha256: hash, bytes: 25 * 1024 * 1024)
        let first = WorkbenchTransactionOperation(target: .project("project-one", "src/one.js"),
            before: .absent, after: after, recoveryBlobHash: hash)
        let second = WorkbenchTransactionOperation(target: .project("project-two", "src/two.js"),
            before: .absent, after: after, recoveryBlobHash: hash)
        let base = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: "transaction-one",
            workspaceId: "workspace-one", kind: .projectEdit, expectedGeneration: 1,
            operations: [first, second])
        XCTAssertThrowsError(try base.validate()) { XCTAssertEqual($0 as? WorkspaceError, .invalidSchema) }
        let sameProject = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: "transaction-one",
            workspaceId: "workspace-one", kind: .projectEdit, expectedGeneration: 1,
            operations: [first, .init(target: .project("project-one", "src/two.js"),
                                      before: .absent, after: after, recoveryBlobHash: hash)])
        XCTAssertNoThrow(try sameProject.validate())
        let measured = [hash: 25 * 1024 * 1024]
        XCTAssertEqual(try WorkbenchTransactionAccounting.expandedPublicationBytes(sameProject.operations,
                                                                                      measuredBlobs: measured), 50 * 1024 * 1024)
        let recognized = WorkbenchTransactionOperation(target: .history("package", "object-three", "bytes.bin"),
            before: after, after: after, recoveryBlobHash: hash)
        XCTAssertThrowsError(try WorkbenchTransactionAccounting.expandedPublicationBytes(
            sameProject.operations + [recognized], measuredBlobs: measured)) {
                XCTAssertEqual($0 as? WorkspaceError, .limitExceeded)
            }
    }

    func testProjectedSourcePolicyUsesWorkspaceIgnoreRules() throws {
        let current = try WorkspaceIgnoreRules(data: nil)
        let valid = try WorkspaceIgnoreRules(data: Data("generated/**\n".utf8))
        let required = ["screenpunk.project.json", "screen.json", "src/App.tsx", ".screenpunkignore"]
        XCTAssertNoThrow(try WorkspaceProjectedSourcePolicy.validate(current: current, projected: valid,
            targets: ["src/App.tsx", ".screenpunkignore"], required: required))
        XCTAssertThrowsError(try WorkspaceIgnoreRules(data: Data("!generated/**\n".utf8)))
        let excludesRequired = try WorkspaceIgnoreRules(data: Data("screen.json\n".utf8))
        XCTAssertThrowsError(try WorkspaceProjectedSourcePolicy.validate(current: current,
            projected: excludesRequired, targets: ["src/App.tsx"], required: required))
        let excludesTarget = try WorkspaceIgnoreRules(data: Data("src/App.tsx\n".utf8))
        XCTAssertThrowsError(try WorkspaceProjectedSourcePolicy.validate(current: excludesTarget,
            projected: current, targets: ["src/App.tsx"], required: required))
    }

    func testInvalidProjectedIgnoreFailsBeforeStageAndValidUpdateCommits() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let project = try fixture.addContainedProject()
        let invalid = Data("screen.json\n".utf8)
        let invalidJournal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, ".screenpunkignore"), before: .absent,
                  after: .present(invalid), recoveryBlobHash: WorkbenchTransactionDigest.hex(invalid))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(invalidJournal,
            blobs: [WorkbenchTransactionDigest.hex(invalid): invalid]))
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        XCTAssertTrue(try root.emptyDirectory(["Workbench", "Transactions"]))
        let valid = Data("generated/**\n".utf8)
        let beforeSource = Data("export const x=1;\n".utf8)
        let afterSource = Data("export const x=2;\n".utf8)
        let journal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, ".screenpunkignore"), before: .absent,
                  after: .present(valid), recoveryBlobHash: WorkbenchTransactionDigest.hex(valid)),
            .init(target: .project(project.projectId, "src/App.tsx"), before: .present(beforeSource),
                  after: .present(afterSource), recoveryBlobHash: WorkbenchTransactionDigest.hex(afterSource))
        ])
        try fixture.engine().prepare(journal, blobs: [WorkbenchTransactionDigest.hex(valid): valid,
                                                     WorkbenchTransactionDigest.hex(afterSource): afterSource])
        try fixture.engine().commit(journal.transactionId)
        let source = try root.directory(["Screens", "alpha"]); defer { close(source) }
        XCTAssertEqual(try root.read(source, ".screenpunkignore"), valid)
        let sourceFiles = try root.directory(["Screens", "alpha", "src"]); defer { close(sourceFiles) }
        XCTAssertEqual(try root.read(sourceFiles, "App.tsx"), afterSource)
    }

    func testTargetExcludedByCurrentProjectPolicyFailsBeforeStaging() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let project = try fixture.addContainedProject()
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let projectDirectory = try root.directory(["Screens", "alpha"]); defer { close(projectDirectory) }
        try root.write(projectDirectory, ".screenpunkignore", data: Data("src/new.js\n".utf8), expected: nil)
        let value = Data("export const y=1;\n".utf8)
        let journal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, "src/new.js"), before: .absent,
                  after: .present(value), recoveryBlobHash: WorkbenchTransactionDigest.hex(value))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(journal,
            blobs: [WorkbenchTransactionDigest.hex(value): value]))
        XCTAssertTrue(try root.emptyDirectory(["Workbench", "Transactions"]))
    }

    func testMetadataReferencesRecheckedBeforeDescriptorAndOnResumedReplay() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let (journal, blobs) = try metadataCommit(fixture)
        var checks = 0
        let engine = WorkbenchTransactionEngine(selection: fixture.store.selection, referenceValidationHook: {
            checks += 1
            if checks == 3 { throw WorkspaceError.conflict }
        })
        try engine.prepare(journal, blobs: blobs)
        XCTAssertThrowsError(try engine.commit(journal.transactionId))
        XCTAssertEqual(try fixture.descriptor().generation, journal.expectedGeneration)
        let staged = try WorkspaceFiles(path: fixture.workspace.path)
        let stage = try staged.directory(["Workbench", "Transactions", journal.transactionId]); defer { close(stage) }
        XCTAssertTrue(try staged.exists(stage, "journal.json"))

        let resumedFixture = try TransactionFixture(); defer { resumedFixture.cleanup() }
        let (resumedJournal, resumedBlobs) = try metadataCommit(resumedFixture)
        let interrupted = resumedFixture.engine(crashAt: .memberPublished(1))
        try interrupted.prepare(resumedJournal, blobs: resumedBlobs)
        XCTAssertThrowsError(try interrupted.commit(resumedJournal.transactionId))
        var replayChecks = 0
        let resumed = WorkbenchTransactionEngine(selection: resumedFixture.store.selection, referenceValidationHook: {
            replayChecks += 1
            if replayChecks == 2 { throw WorkspaceError.conflict }
        })
        XCTAssertThrowsError(try resumed.recoverAll())
        XCTAssertEqual(try resumedFixture.descriptor().generation, resumedJournal.expectedGeneration)

        let committedFixture = try TransactionFixture(); defer { committedFixture.cleanup() }
        let (committedJournal, committedBlobs) = try metadataCommit(committedFixture)
        let afterGeneration = committedFixture.engine(crashAt: .generationDurable)
        try afterGeneration.prepare(committedJournal, blobs: committedBlobs)
        XCTAssertThrowsError(try afterGeneration.commit(committedJournal.transactionId))
        XCTAssertEqual(try committedFixture.descriptor().generation, committedJournal.expectedGeneration + 1)
        var postconditionChecks = 0
        let postconditionFailure = WorkbenchTransactionEngine(selection: committedFixture.store.selection,
            referenceValidationHook: {
                postconditionChecks += 1
                if postconditionChecks == 2 { throw WorkspaceError.conflict }
            })
        XCTAssertThrowsError(try postconditionFailure.recoverAll())
        let committedRoot = try WorkspaceFiles(path: committedFixture.workspace.path)
        let committedStage = try committedRoot.directory(["Workbench", "Transactions", committedJournal.transactionId])
        defer { close(committedStage) }
        XCTAssertTrue(try committedRoot.exists(committedStage, "journal.json"))
    }

    private func metadataCommit(_ fixture: TransactionFixture) throws -> (WorkbenchTransactionJournal, [String: Data]) {
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
        let settings = try root.directory(["Workbench", "Settings"]); defer { close(settings) }
        let descriptor = try root.read(root.fd, "workspace.json")
        let catalog = try root.read(library, "catalog.json")
        let preferences = try root.read(settings, "workbench.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptor) as? [String: Any])
        object["generation"] = 2
        let nextDescriptor = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let nextCatalog = try WorkspaceJSON.encode(WorkspaceCatalog(generation: 2))
        let nextPreferences = try WorkspaceJSON.encode(WorkspaceSettings(generation: 2))
        let members = [("workspaceDescriptor", descriptor, nextDescriptor),
                       ("libraryCatalog", catalog, nextCatalog),
                       ("workbenchSettings", preferences, nextPreferences)]
        let operations = members.map { name, before, after in
            WorkbenchTransactionOperation(target: .metadata(name), before: .present(before),
                after: .present(after), recoveryBlobHash: WorkbenchTransactionDigest.hex(after))
        }
        return (fixture.journal(kind: .catalogSettingsCommit, operations: operations),
                Dictionary(uniqueKeysWithValues: members.map { (_, _, after) in (WorkbenchTransactionDigest.hex(after), after) }))
    }
    func testMultiMemberCrashRecoveryAtEachDurableBoundary() throws {
        for interruptedAt in [WorkbenchTransactionCheckpoint.journalDurable,
                              .temporaryDurable(0), .memberPublished(0),
                              .temporaryDurable(2), .generationDurable, .beforeCleanup] {
            let fixture = try TransactionFixture()
            defer { fixture.cleanup() }
            let first = Data("retained first".utf8), second = Data("retained second".utf8)
            let journal = fixture.publish([("first.bin", first), ("second.bin", second)])
            let engine = fixture.engine(crashAt: interruptedAt)
            let blobs = [WorkbenchTransactionDigest.hex(first): first, WorkbenchTransactionDigest.hex(second): second]
            if interruptedAt == .journalDurable {
                XCTAssertThrowsError(try engine.prepare(journal, blobs: blobs))
            } else {
                try engine.prepare(journal, blobs: blobs)
                XCTAssertThrowsError(try engine.commit(journal.transactionId))
            }
            let restarted = fixture.engine()
            XCTAssertEqual(try restarted.recoverAll(), [journal.transactionId])
            XCTAssertEqual(try restarted.recoverAll(), [])
            XCTAssertEqual(try fixture.readHistory("first.bin"), first)
            XCTAssertEqual(try fixture.readHistory("second.bin"), second)
            XCTAssertEqual(try fixture.descriptor().generation, journal.expectedGeneration + 1)
        }
    }

    func testUnknownJournalBlocksAllRecoveryAndPreservesValidPendingBytes() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let value = Data("safe".utf8)
        let journal = fixture.publish([("safe.bin", value)])
        try fixture.engine().prepare(journal, blobs: [WorkbenchTransactionDigest.hex(value): value])
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let directory = try root.directory(["Workbench", "Transactions", "evil"], create: true)
        try root.write(directory, "journal.json", data: Data(#"{"schemaVersion":2,"kind":"execute"}"#.utf8), expected: nil)
        close(directory)
        XCTAssertThrowsError(try fixture.engine().recoverAll()) { error in
            let diagnostic = error as? WorkbenchTransactionFailure
            XCTAssertEqual(diagnostic?.transactionId, "evil")
            XCTAssertTrue(diagnostic?.localizedDescription.contains("Preserve Workbench/Transactions") == true)
        }
        XCTAssertNil(try fixture.readHistory("safe.bin"))
        XCTAssertEqual(try fixture.descriptor().generation, journal.expectedGeneration)
    }

    func testCopiedDestructiveAndMigrationJournalsNeedFreshExactLocalPlan() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let original = Data("keep history".utf8)
        let published = fixture.publish([("retained.bin", original)])
        try fixture.engine().prepare(published, blobs: [WorkbenchTransactionDigest.hex(original): original])
        try fixture.engine().commit(published.transactionId)
        let target = WorkbenchTransactionTarget.history("package", "screen-one", "retained.bin")
        let prune = fixture.journal(kind: .historyPrune, operations: [
            .init(target: target, before: .present(original), after: .absent, recoveryBlobHash: nil)
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(prune, blobs: [:]))
        XCTAssertEqual(try fixture.readHistory("retained.bin"), original)
        let plan = TransactionPlanHolder()
        plan.value = fixture.plan(for: prune, pruneSafe: false)
        XCTAssertThrowsError(try fixture.engine(inspector: plan).prepare(prune, blobs: [:]))
        XCTAssertEqual(try fixture.readHistory("retained.bin"), original)
        plan.value = fixture.plan(for: prune)
        let authorized = fixture.engine(inspector: plan)
        try authorized.prepare(prune, blobs: [:])
        plan.value = nil // A copied journal alone cannot carry approval across restart.
        XCTAssertThrowsError(try authorized.commit(prune.transactionId))
        XCTAssertEqual(try fixture.readHistory("retained.bin"), original)
        plan.value = fixture.plan(for: prune)
        try authorized.commit(prune.transactionId)
        XCTAssertNil(try fixture.readHistory("retained.bin"))
        let migration = fixture.journal(kind: .migrationPublish, operations: [
            .init(target: .migration("move-one", "history", "copy-one", "bytes.bin"),
                  before: .absent, after: .present(original), recoveryBlobHash: WorkbenchTransactionDigest.hex(original))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(migration, blobs: [WorkbenchTransactionDigest.hex(original): original]))
        plan.value = fixture.plan(for: migration)
        try authorized.prepare(migration, blobs: [WorkbenchTransactionDigest.hex(original): original])
        try authorized.commit(migration.transactionId)
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let staged = try root.directory(["Workbench", "Migrations", "move-one", "Staging", "history", "copy-one"])
        XCTAssertEqual(try root.read(staged, "bytes.bin"), original)
        close(staged)
    }

    func testMalformedRelationsPreimagesAndCollisionsFailBeforePublication() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let a = Data("A".utf8), b = Data("B".utf8)
        let target = WorkbenchTransactionTarget.history("package", "screen-one", "sentinel.bin")
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let parent = try root.directory(["Workbench", "History", "Packages", "screen-one"], create: true)
        try root.write(parent, "sentinel.bin", data: a, expected: nil); close(parent)
        let badPreimage = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project("unknown", "../../sentinel.bin"), before: .absent,
                  after: .present(b), recoveryBlobHash: WorkbenchTransactionDigest.hex(b))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(badPreimage, blobs: [WorkbenchTransactionDigest.hex(b): b]))
        let overwrite = fixture.journal(kind: .historyPublish, operations: [
            .init(target: target, before: .present(a), after: .present(b), recoveryBlobHash: WorkbenchTransactionDigest.hex(b))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(overwrite, blobs: [WorkbenchTransactionDigest.hex(b): b]))
        let wrongBefore = fixture.journal(kind: .historyPublish, operations: [
            .init(target: .history("package", "screen-one", "sentinel.bin"), before: .absent,
                  after: .present(b), recoveryBlobHash: WorkbenchTransactionDigest.hex(b))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(wrongBefore, blobs: [WorkbenchTransactionDigest.hex(b): b]))
        let collision = fixture.journal(kind: .historyPublish, operations: [
            .init(target: .history("package", "screen-one", "DUP.bin"), before: .absent,
                  after: .present(a), recoveryBlobHash: WorkbenchTransactionDigest.hex(a)),
            .init(target: .history("package", "screen-one", "dup.bin"), before: .absent,
                  after: .present(b), recoveryBlobHash: WorkbenchTransactionDigest.hex(b))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(collision, blobs: [WorkbenchTransactionDigest.hex(a): a, WorkbenchTransactionDigest.hex(b): b]))
        XCTAssertEqual(try fixture.readHistory("sentinel.bin"), a)
        XCTAssertNil(try fixture.readHistory("DUP.bin"))
    }

    func testSymlinkHardlinkAndCorruptBlobQuarantine() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let payload = Data("good".utf8), hash = WorkbenchTransactionDigest.hex(payload)
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let parent = try root.directory(["Workbench", "History", "Packages", "screen-one"], create: true)
        let target = fixture.workspace.path + "/Workbench/History/Packages/screen-one/link.bin"
        XCTAssertEqual(symlink("/private/tmp/never-follow", target), 0)
        let linked = fixture.publish([("link.bin", payload)])
        XCTAssertThrowsError(try fixture.engine().prepare(linked, blobs: [hash: payload]))
        XCTAssertEqual(unlink(target), 0)
        try root.write(parent, "source.bin", data: payload, expected: nil)
        XCTAssertEqual(linkat(parent, "source.bin", parent, "link.bin", 0), 0)
        XCTAssertThrowsError(try fixture.engine().prepare(linked, blobs: [hash: payload]))
        XCTAssertEqual(unlinkat(parent, "link.bin", 0), 0)
        close(parent)
        let journal = fixture.publish([("recover.bin", payload)])
        try fixture.engine().prepare(journal, blobs: [hash: payload])
        let blobs = try root.directory(["Workbench", "Transactions", journal.transactionId, "blobs"])
        let node = WorkspaceNodeID(try root.metadata(blobs, hash))
        try root.write(blobs, hash, data: Data("evil".utf8), expected: node)
        close(blobs)
        XCTAssertThrowsError(try fixture.engine().recoverAll())
        XCTAssertNil(try fixture.readHistory("recover.bin"))
    }

    func testRawUnknownFieldsDuplicateKeysAndQuotaReject() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let data = Data("x".utf8)
        let journal = fixture.publish([("x.bin", data)])
        let encoded = try WorkbenchTransactionJSON.encode(journal)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        raw["role"] = "gui"
        XCTAssertThrowsError(try WorkbenchTransactionJSON.decode(JSONSerialization.data(withJSONObject: raw)))
        let duplicate = #"{"schemaVersion":1,"schema\u0056ersion":1}"#
        XCTAssertThrowsError(try WorkbenchTransactionJSON.decode(Data(duplicate.utf8)))
        let oversized = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: "large", workspaceId: journal.workspaceId,
            kind: .historyPublish, expectedGeneration: journal.expectedGeneration,
            operations: Array(repeating: journal.operations[0], count: 2_001))
        XCTAssertThrowsError(try fixture.engine().prepare(oversized, blobs: [:]))
        XCTAssertNil(try fixture.readHistory("x.bin"))
    }

    func testChainedInterruptedGenerationsRecoverInOrder() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let first = Data("one".utf8), second = Data("two".utf8)
        let one = fixture.publish([("chain.bin", first)])
        try fixture.engine().prepare(one, blobs: [WorkbenchTransactionDigest.hex(first): first])
        let two = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: UUID().uuidString.lowercased(),
            workspaceId: one.workspaceId, kind: .projectEdit, expectedGeneration: one.expectedGeneration + 1,
            operations: [])
        // A later generation may be staged by a valid writer after the first commit;
        // no copied journal may bypass the type/registered-project grammar.
        XCTAssertThrowsError(try WorkbenchTransactionJSON.encode(two))
        let next = WorkbenchTransactionJournal(schemaVersion: 1, transactionId: UUID().uuidString.lowercased(),
            workspaceId: one.workspaceId, kind: .historyPublish, expectedGeneration: one.expectedGeneration + 1,
            operations: [.init(target: .history("package", "screen-two", "next.bin"), before: .absent,
                               after: .present(second), recoveryBlobHash: WorkbenchTransactionDigest.hex(second))])
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let stage = try root.directory(["Workbench", "Transactions", next.transactionId], create: true)
        let blobDirectory = try root.directory(["Workbench", "Transactions", next.transactionId, "blobs"], create: true)
        let workDirectory = try root.directory(["Workbench", "Transactions", next.transactionId, "work"], create: true)
        try root.write(blobDirectory, WorkbenchTransactionDigest.hex(second), data: second, expected: nil)
        try root.write(stage, "journal.json", data: WorkbenchTransactionJSON.encode(next), expected: nil)
        close(workDirectory); close(blobDirectory); close(stage)
        XCTAssertEqual(try fixture.engine().recoverAll(), [one.transactionId, next.transactionId])
        XCTAssertEqual(try fixture.descriptor().generation, one.expectedGeneration + 2)
        XCTAssertEqual(try fixture.readHistory("chain.bin"), first)
    }

    func testCatalogSettingsCommitPublishesThreeObjectsAndDescriptorLast() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let library = try root.directory(["Workbench", "Library"])
        let settings = try root.directory(["Workbench", "Settings"])
        let beforeDescriptor = try root.read(root.fd, "workspace.json")
        let beforeCatalog = try root.read(library, "catalog.json")
        let beforeSettings = try root.read(settings, "workbench.json")
        close(library); close(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeDescriptor) as? [String: Any])
        object["generation"] = 2
        let afterDescriptor = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let afterCatalog = try WorkspaceJSON.encode(WorkspaceCatalog(generation: 2))
        let afterSettings = try WorkspaceJSON.encode(WorkspaceSettings(generation: 2))
        let cases = [("workspaceDescriptor", beforeDescriptor, afterDescriptor),
                     ("libraryCatalog", beforeCatalog, afterCatalog),
                     ("workbenchSettings", beforeSettings, afterSettings)]
        let operations = cases.map { name, before, after in
            WorkbenchTransactionOperation(target: .metadata(name), before: .present(before),
                after: .present(after), recoveryBlobHash: WorkbenchTransactionDigest.hex(after))
        }
        let journal = fixture.journal(kind: .catalogSettingsCommit, operations: operations)
        let blobs = Dictionary(uniqueKeysWithValues: cases.map { (_, _, after) in (WorkbenchTransactionDigest.hex(after), after) })
        let interrupted = fixture.engine(crashAt: .memberPublished(1))
        try interrupted.prepare(journal, blobs: blobs)
        XCTAssertThrowsError(try interrupted.commit(journal.transactionId))
        XCTAssertEqual(try fixture.descriptor().generation, 1)
        XCTAssertEqual(try fixture.engine().recoverAll(), [journal.transactionId])
        XCTAssertEqual(try fixture.store.current()?.catalog.generation, 2)
        XCTAssertEqual(try fixture.store.current()?.settings.generation, 2)
        XCTAssertEqual(try fixture.descriptor().generation, 2)
    }

    func testExternalProjectRequiresFreshBindingAndExactInspectedPlan() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let project = try fixture.addExternalProject()
        let old = Data("export const x=1;\n".utf8), next = Data("export const x=2;\n".utf8)
        let journal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, "src/App.tsx"), before: .present(old),
                  after: .present(next), recoveryBlobHash: WorkbenchTransactionDigest.hex(next))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(journal, blobs: [WorkbenchTransactionDigest.hex(next): next]))
        let plans = TransactionPlanHolder()
        plans.value = fixture.plan(for: journal, externalIDs: [project.projectId])
        let engine = fixture.engine(inspector: plans)
        try engine.prepare(journal, blobs: [WorkbenchTransactionDigest.hex(next): next])
        let current = try XCTUnwrap(fixture.store.selection.current())
        let workspace = try WorkspaceFiles(path: fixture.workspace.path)
        _ = try fixture.store.selection.select(path: workspace.path, descriptor: try fixture.descriptor(), identity: workspace.identity)
        XCTAssertThrowsError(try engine.commit(journal.transactionId))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("external/src/App.tsx")), old)
        XCTAssertNotEqual(try fixture.store.selection.current()?.bindingId, current.bindingId)
        plans.value = fixture.plan(for: journal, externalIDs: [project.projectId])
        try engine.commit(journal.transactionId)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("external/src/App.tsx")), next)
    }

    func testContainedProjectEditRechecksExpectedBytesAndKeepsSourceDescriptor() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let project = try fixture.addContainedProject()
        let old = Data("export const x=1;\n".utf8), next = Data("export const x=2;\n".utf8)
        let journal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, "src/App.tsx"), before: .present(old),
                  after: .present(next), recoveryBlobHash: WorkbenchTransactionDigest.hex(next))
        ])
        try fixture.engine().prepare(journal, blobs: [WorkbenchTransactionDigest.hex(next): next])
        try fixture.engine().commit(journal.transactionId)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("visible/Screens/alpha/src/App.tsx")), next)
        XCTAssertEqual(try fixture.descriptor().generation, journal.expectedGeneration + 1)
        let attemptedDelete = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, "screenpunk.project.json"),
                  before: .present(Data()), after: .absent, recoveryBlobHash: nil)
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(attemptedDelete, blobs: [:]))
    }

    func testFreshMachineExplicitOpenRecoversContainedJournalWithoutOldSelection() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let payload = Data("portable history".utf8)
        let journal = fixture.publish([("restored.bin", payload)])
        try fixture.engine().prepare(journal, blobs: [WorkbenchTransactionDigest.hex(payload): payload])
        let competing = fixture.publish([("other.bin", payload)])
        XCTAssertThrowsError(try fixture.engine().prepare(competing,
            blobs: [WorkbenchTransactionDigest.hex(payload): payload]))
        let freshMachine = fixture.root.appendingPathComponent("fresh-machine")
        let selection = try WorkspaceSelectionStore(machineRootPath: freshMachine.path)
        XCTAssertNil(try selection.current())
        let recovery = try WorkbenchTransactionEngine(forExplicitOpenAt: fixture.workspace.path, selection: selection)
        XCTAssertThrowsError(try recovery.commit(journal.transactionId))
        XCTAssertEqual(try recovery.recoverAll(), [journal.transactionId])
        let restored = try WorkspaceStore(documents: TransactionDocuments(root: fixture.root),
                                          machineRootPath: freshMachine.path)
        let opened = try restored.open(at: fixture.workspace.path)
        XCTAssertEqual(opened.descriptor.generation, journal.expectedGeneration + 1)
        XCTAssertEqual(try fixture.readHistory("restored.bin"), payload)
        XCTAssertEqual(opened.historyAuthority, "historical-only")
    }

    func testSameBytesDifferentInodeDuringCommitConflicts() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let project = try fixture.addContainedProject()
        let old = Data("export const x=1;\n".utf8), after = Data("export const x=2;\n".utf8)
        let journal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, "src/App.tsx"), before: .present(old),
                  after: .present(after), recoveryBlobHash: WorkbenchTransactionDigest.hex(after))
        ])
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let parent = try root.directory(["Screens", "alpha", "src"])
        defer { close(parent) }
        let original = WorkspaceNodeID(try root.metadata(parent, "App.tsx"))
        let racing = WorkbenchTransactionEngine(selection: fixture.store.selection, checkpoint: { point in
            if point == .beforeMemberMutation(0) {
                let id = WorkspaceNodeID(try root.metadata(parent, "App.tsx"))
                try root.write(parent, "App.tsx", data: old, expected: id)
            }
        })
        try racing.prepare(journal, blobs: [WorkbenchTransactionDigest.hex(after): after])
        XCTAssertThrowsError(try racing.commit(journal.transactionId))
        XCTAssertNotEqual(WorkspaceNodeID(try root.metadata(parent, "App.tsx")), original)
        XCTAssertEqual(try root.read(parent, "App.tsx"), old)
        XCTAssertEqual(try fixture.descriptor().generation, journal.expectedGeneration)
    }

    func testSourcePerFileQuotaFailsBeforeStagingOrOverwriting() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let project = try fixture.addContainedProject()
        let old = Data("export const x=1;\n".utf8)
        let oversized = Data(repeating: 0x61, count: 5 * 1024 * 1024 + 1)
        let journal = fixture.journal(kind: .projectEdit, operations: [
            .init(target: .project(project.projectId, "src/App.tsx"), before: .present(old),
                  after: .present(oversized), recoveryBlobHash: WorkbenchTransactionDigest.hex(oversized))
        ])
        XCTAssertThrowsError(try fixture.engine().prepare(journal,
            blobs: [WorkbenchTransactionDigest.hex(oversized): oversized])) { error in
            XCTAssertEqual(error as? WorkspaceError, .limitExceeded)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("visible/Screens/alpha/src/App.tsx")), old)
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        XCTAssertTrue(try root.emptyDirectory(["Workbench", "Transactions"]))
    }

    func testSelectionSwitchBeforeFinalMutationLeavesTargetUntouched() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let original = Data("current".utf8), replacement = Data("next".utf8)
        let root = try WorkspaceFiles(path: fixture.workspace.path)
        let folder = try root.directory(["Workbench", "History", "Packages", "screen-one"], create: true)
        try root.write(folder, "selection.bin", data: original, expected: nil)
        close(folder)
        let replace = fixture.journal(kind: .historyPublish, operations: [
            .init(target: .history("package", "screen-one", "other.bin"), before: .absent,
                  after: .present(replacement), recoveryBlobHash: WorkbenchTransactionDigest.hex(replacement))
        ])
        let engine = WorkbenchTransactionEngine(selection: fixture.store.selection, checkpoint: { point in
            if point == .beforeMemberMutation(0) {
                _ = try fixture.store.selection.select(path: root.path, descriptor: try fixture.descriptor(),
                                                       identity: root.identity)
            }
        })
        try engine.prepare(replace, blobs: [WorkbenchTransactionDigest.hex(replacement): replacement])
        XCTAssertThrowsError(try engine.commit(replace.transactionId)) { error in
            XCTAssertEqual(error as? WorkspaceError, .conflict)
        }
        XCTAssertNil(try fixture.readHistory("other.bin"))
        XCTAssertEqual(try fixture.readHistory("selection.bin"), original)
        XCTAssertEqual(try fixture.descriptor().generation, replace.expectedGeneration)
    }

    func testCommittedPruneCanRetireAfterLocalPlanDisappears() throws {
        let fixture = try TransactionFixture(); defer { fixture.cleanup() }
        let bytes = Data("retained".utf8)
        let publish = fixture.publish([("prunable.bin", bytes)])
        try fixture.engine().prepare(publish, blobs: [WorkbenchTransactionDigest.hex(bytes): bytes])
        try fixture.engine().commit(publish.transactionId)
        let prune = fixture.journal(kind: .historyPrune, operations: [
            .init(target: .history("package", "screen-one", "prunable.bin"),
                  before: .present(bytes), after: .absent, recoveryBlobHash: nil)
        ])
        let holder = TransactionPlanHolder()
        holder.value = fixture.plan(for: prune)
        let interrupted = fixture.engine(inspector: holder, crashAt: .generationDurable)
        try interrupted.prepare(prune, blobs: [:])
        XCTAssertThrowsError(try interrupted.commit(prune.transactionId))
        holder.value = nil
        XCTAssertEqual(try fixture.engine(inspector: holder).recoverAll(), [prune.transactionId])
        XCTAssertNil(try fixture.readHistory("prunable.bin"))
    }
}

private struct TransactionDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}
private final class TransactionPlanHolder: WorkbenchTransactionPlanInspector {
    var value: WorkbenchInspectedTransactionPlan?
    func currentPlan(transactionId: String) throws -> WorkbenchInspectedTransactionPlan? {
        value?.transactionId == transactionId ? value : nil
    }
}
private final class TransactionFixture {
    let root: URL
    let store: WorkspaceStore
    let workspace: WorkspaceOverview
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/sp-transaction-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("machine"),
                                                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = try WorkspaceStore(documents: TransactionDocuments(root: root),
                                   machineRootPath: root.appendingPathComponent("machine").path)
        workspace = try store.create(at: root.appendingPathComponent("visible").path)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func engine(inspector: WorkbenchTransactionPlanInspector? = nil,
                crashAt: WorkbenchTransactionCheckpoint? = nil) -> WorkbenchTransactionEngine {
        WorkbenchTransactionEngine(selection: store.selection, inspector: inspector,
            checkpoint: crashAt.map { target in { checkpoint in if checkpoint == target { throw WorkspaceError.unavailable } } })
    }
    func descriptor() throws -> WorkspaceDescriptor {
        let root = try WorkspaceFiles(path: workspace.path)
        let value = try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: root.read(root.fd, "workspace.json"), shape: .descriptor)
        return value
    }
    func journal(kind: WorkbenchTransactionKind, operations: [WorkbenchTransactionOperation]) -> WorkbenchTransactionJournal {
        let root = try! WorkspaceFiles(path: workspace.path)
        let descriptor = try! WorkspaceJSON.decode(WorkspaceDescriptor.self, from: root.read(root.fd, "workspace.json"), shape: .descriptor)
        return .init(schemaVersion: 1, transactionId: UUID().uuidString.lowercased(),
                     workspaceId: workspace.descriptor.workspaceId, kind: kind,
                     expectedGeneration: descriptor.generation, operations: operations)
    }
    func publish(_ files: [(String, Data)]) -> WorkbenchTransactionJournal {
        journal(kind: .historyPublish, operations: files.map { name, bytes in
            .init(target: .history("package", "screen-one", name), before: .absent,
                  after: .present(bytes), recoveryBlobHash: WorkbenchTransactionDigest.hex(bytes))
        })
    }
    func plan(for journal: WorkbenchTransactionJournal, externalIDs: Set<String> = [],
              pruneSafe: Bool = true) -> WorkbenchInspectedTransactionPlan {
        let selection = try! store.selection.current()!
        return .init(transactionId: journal.transactionId, kind: journal.kind, workspaceId: journal.workspaceId,
                     bindingId: selection.bindingId, selectionGeneration: selection.selectionGeneration,
                     expectedGeneration: journal.expectedGeneration, operations: journal.operations,
                     reviewedExternalProjectIds: externalIDs,
                     prunableHistoryTargets: journal.kind == .historyPrune && pruneSafe ? Set(journal.operations.map(targetKey)) : [],
                     verifiedMigrationTargets: journal.kind == .migrationPublish ? Set(journal.operations.map(targetKey)) : [])
    }
    private func targetKey(_ operation: WorkbenchTransactionOperation) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(operation.target), as: UTF8.self)
    }
    func addExternalProject() throws -> WorkspaceProject {
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external.appendingPathComponent("src"),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(projectId: UUID().uuidString.lowercased(),
            dashboardId: UUID().uuidString.lowercased(), name: "External",
            location: .external("external-source"))
        let descriptor: [String: Any] = ["schemaVersion": 1, "projectId": project.projectId,
            "dashboardId": project.dashboardId, "name": project.name, "kind": "react",
            "kitVersion": "1.0.0", "entry": "src/App.tsx", "screenConfig": "screen.json"]
        let files: [(String, Data)] = [
            ("screenpunk.project.json", try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])),
            ("screen.json", Data("{}".utf8)),
            ("src/App.tsx", Data("export const x=1;\n".utf8))
        ]
        for (name, data) in files {
            let path = external.appendingPathComponent(name).path
            try data.write(to: URL(fileURLWithPath: path))
            guard chmod(path, 0o600) == 0 else { throw WorkspaceError.unavailable }
        }
        _ = try store.registerExternal(project, sourcePath: external.path,
                                       explicitExternal: true, expectedCatalogGeneration: 1)
        return project
    }
    func addContainedProject() throws -> WorkspaceProject {
        let source = root.appendingPathComponent("visible/Screens/alpha/src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(projectId: UUID().uuidString.lowercased(),
            dashboardId: UUID().uuidString.lowercased(), name: "Contained",
            location: .contained("Screens/alpha"))
        let descriptor: [String: Any] = ["schemaVersion": 1, "projectId": project.projectId,
            "dashboardId": project.dashboardId, "name": project.name, "kind": "react",
            "kitVersion": "1.0.0", "entry": "src/App.tsx", "screenConfig": "screen.json"]
        let folder = root.appendingPathComponent("visible/Screens/alpha")
        let files: [(String, Data)] = [
            ("screenpunk.project.json", try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])),
            ("screen.json", Data("{}".utf8)),
            ("src/App.tsx", Data("export const x=1;\n".utf8))
        ]
        for (name, data) in files {
            let path = folder.appendingPathComponent(name).path
            try data.write(to: URL(fileURLWithPath: path))
            guard chmod(path, 0o600) == 0 else { throw WorkspaceError.unavailable }
        }
        _ = try store.registerContained(project, expectedCatalogGeneration: 1)
        return project
    }
    func readHistory(_ name: String) throws -> Data? {
        let root = try WorkspaceFiles(path: workspace.path)
        let directory: Int32
        do { directory = try root.directory(["Workbench", "History", "Packages", "screen-one"]) }
        catch WorkspaceError.unavailable { return nil }
        catch WorkspaceError.unsafeFile { return nil }
        defer { close(directory) }
        guard try root.exists(directory, name) else { return nil }
        return try root.read(directory, name)
    }
}
#endif
