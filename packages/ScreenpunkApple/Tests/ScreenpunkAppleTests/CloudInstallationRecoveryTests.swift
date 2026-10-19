import XCTest
@testable import ScreenpunkApple
import ScreenpunkCore

final class CloudInstallationRecoveryTests: XCTestCase {
    private let reference = "candidate-fixture"
    private let secret = Data(repeating: 7, count: 32)
    private func record(phase: DeviceManagementTransitionPhase = .intent) throws -> DeviceManagementTransitionHistory {
        let history = try DeviceManagementTransitionHistory.intent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: reference)
        return phase == .intent ? history : try history.fenced()
    }
    private func stage(_ history: DeviceManagementTransitionHistory, journal: any CloudInstallationTransitionJournal, credentials: CloudInstallationCredentialStore) throws -> Data {
        try CloudInstallationRecovery.stageCredential(history, credentialGenerationID: history.credentials.last!.credentialGenerationID, journal: journal, credentials: credentials)
    }
    private func credentials(_ backend: InstallationBackend) -> CloudInstallationCredentialStore {
        let secret = secret
        return .init(backend: backend, random: { backend.noteGeneration(); return secret })
    }
    func testExistingImmutableKeyIsLoadedWithoutGenerationOrInsert() throws {
        let backend = InstallationBackend(); backend.values[reference] = secret
        XCTAssertEqual(try credentials(backend).stage(reference: reference), secret)
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
    }
    func testDuplicateInsertionLoadsExistingKeyWithoutOverwrite() throws {
        let backend = InstallationBackend(); backend.mode = .duplicate
        let existing = Data(repeating: 8, count: 32)
        XCTAssertEqual(try credentials(backend).stage(reference: reference), existing)
        XCTAssertEqual(backend.values[reference], existing)
        XCTAssertEqual(backend.inserts, 1)
    }
    func testWriteThenThrowRequiresExactSameReferenceReadback() throws {
        let backend = InstallationBackend(); backend.mode = .writeThenThrow
        XCTAssertEqual(try credentials(backend).stage(reference: reference), secret)
        XCTAssertEqual(backend.reads, [reference, reference])
        XCTAssertEqual(backend.generations, 1)
    }
    func testAmbiguousDifferentBytesFailClosedWithoutOverwriteOrRegeneration() {
        let backend = InstallationBackend(); backend.mode = .differentThenThrow
        XCTAssertThrowsError(try credentials(backend).stage(reference: reference)) {
            XCTAssertEqual($0 as? CloudInstallationCredentialError, .mismatchedWrite)
        }
        XCTAssertEqual(backend.values[reference], Data(repeating: 8, count: 32))
        XCTAssertEqual(backend.generations, 1)
        XCTAssertEqual(backend.inserts, 1)
    }
    func testLockedReadAndEnumerationAreNotAbsence() throws {
        let backend = InstallationBackend(); backend.readFailure = .inaccessible(status: -25308)
        XCTAssertThrowsError(try credentials(backend).stage(reference: reference)) {
            XCTAssertEqual($0 as? CloudInstallationCredentialError, .inaccessible(status: -25308))
        }
        XCTAssertEqual(backend.generations, 0)
        backend.enumerationFailure = .inaccessible(status: -25308)
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: InstallationJournal(), credentials: credentials(backend)), .blocked(.credentialUnavailable))
    }
    func testMissingReadbackAndMalformedMaterialCannotBeUsed() {
        let backend = InstallationBackend(); backend.mode = .missingReadback
        XCTAssertThrowsError(try credentials(backend).stage(reference: reference)) {
            XCTAssertEqual($0 as? CloudInstallationCredentialError, .unconfirmedWrite)
        }
        backend.values[reference] = Data([1])
        XCTAssertThrowsError(try credentials(backend).secret(for: reference)) {
            XCTAssertEqual($0 as? CloudInstallationCredentialError, .malformedSecret)
        }
    }
    func testDurableIntentAndReadbackPrecedeSecretGeneration() throws {
        let journal = InstallationJournal()
        let intent = try record()
        let backend = InstallationBackend()
        backend.onGenerate = { XCTAssertEqual(journal.record, intent); XCTAssertEqual(journal.loads, 2); XCTAssertEqual(journal.saves, 1) }
        XCTAssertEqual(try stage(intent, journal: journal, credentials: credentials(backend)), secret)
        XCTAssertEqual(journal.record, intent)
    }
    func testJournalWriteThenThrowCannotRegenerateMissingKeyOnRetry() throws {
        let journal = InstallationJournal(); journal.writeThenThrow = true
        let intent = try record()
        let backend = InstallationBackend()
        XCTAssertThrowsError(try stage(intent, journal: journal, credentials: credentials(backend)))
        XCTAssertEqual(journal.record, intent)
        XCTAssertEqual(backend.generations, 0)
        journal.writeThenThrow = false
        XCTAssertThrowsError(try stage(intent, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .missingCredential)
        }
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
    }
    func testPreexistingIntentMissingKeyNeverGeneratesOrInserts() throws {
        let journal = InstallationJournal(); let intent = try record(); journal.record = intent
        let backend = InstallationBackend()
        XCTAssertThrowsError(try stage(intent, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .missingCredential)
        }
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
        XCTAssertEqual(journal.saves, 0)
    }
    func testPreexistingIntentLoadsSameKeyWithoutGenerationOrInsertion() throws {
        let journal = InstallationJournal(); let intent = try record(); journal.record = intent
        let backend = InstallationBackend(); backend.values[reference] = secret
        XCTAssertEqual(try stage(intent, journal: journal, credentials: credentials(backend)), secret)
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
        XCTAssertEqual(journal.saves, 0)
    }
    func testOrphanSameReferenceBlocksNewIntentBeforeJournalWriteOrGeneration() throws {
        let journal = InstallationJournal(); let intent = try record()
        let backend = InstallationBackend(); backend.values[reference] = secret
        XCTAssertThrowsError(try stage(intent, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .orphanedCredential)
        }
        XCTAssertEqual(journal.saves, 0)
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
    }
    func testExistingIntentWithExtraReferenceBlocksWithoutWritesOrGeneration() throws {
        let journal = InstallationJournal(); let intent = try record(); journal.record = intent
        let backend = InstallationBackend(); backend.values[reference] = secret; backend.values["orphan-fixture"] = secret
        XCTAssertThrowsError(try stage(intent, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .orphanedCredential)
        }
        XCTAssertEqual(journal.saves, 0)
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
    }
    func testInaccessibleInventoryBlocksIntentBeforeMutationOrGeneration() throws {
        let journal = InstallationJournal(); let backend = InstallationBackend()
        backend.enumerationFailure = .inaccessible(status: -25308)
        XCTAssertThrowsError(try stage(try record(), journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationCredentialError, .inaccessible(status: -25308))
        }
        XCTAssertEqual(journal.saves, 0)
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
    }

    func testFenceRacingCredentialInsertionPreventsReturningMaterial() throws {
        let journal = InstallationJournal(); let intent = try record()
        let backend = InstallationBackend(); let fenced = try intent.fenced()
        backend.onInsert = { journal.record = fenced }
        XCTAssertThrowsError(try stage(intent, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .unconfirmedIntent)
        }
        XCTAssertEqual(journal.record, fenced)
        XCTAssertEqual(backend.values[reference], secret)
    }

    func testConflictingTransitionNeverWritesOrGenerates() throws {
        let journal = InstallationJournal(); journal.record = try record()
        let backend = InstallationBackend(); backend.values[reference] = secret
        XCTAssertThrowsError(try stage(try record(), journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .transitionConflict)
        }
        XCTAssertEqual(journal.saves, 0)
        XCTAssertEqual(backend.generations, 0)
    }
    func testClassifierRequiresAbsentJournalAndConfirmedEmptyServiceForLegacyLocal() throws {
        let journal = InstallationJournal(); let backend = InstallationBackend()
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .legacyLocal)
        backend.values[reference] = secret
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.orphanedCredential))
        journal.loadFailure = true
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.journalUnavailable))
    }
    func testIntentMissingKeyAndFenceExtraKeysFailClosed() throws {
        let journal = InstallationJournal(); let backend = InstallationBackend()
        journal.record = try record()
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.missingCredential))
        backend.values[reference] = secret
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.pendingIntent))
        journal.record = try record(phase: .locallyFenced)
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .locallyFenced)
        backend.values["orphan-fixture"] = secret
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.orphanedCredential))
        XCTAssertEqual(backend.values.count, 2) // Classification must not erase remote-cleanup credentials.
    }
    func testDurableFenceAfterRestartAccountsForRetainedKeyWithoutTouchingContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("device/package/content.txt")
        try FileManager.default.createDirectory(at: content.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retained content fixture".utf8).write(to: content)
        let directory = root.appendingPathComponent("management")
        let journal = DeviceManagementTransitionStore(directory: directory)
        let intent = try record()
        let backend = InstallationBackend()
        _ = try stage(intent, journal: journal, credentials: credentials(backend))
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.pendingIntent))
        try journal.save(intent.fenced())
        let restarted = DeviceManagementTransitionStore(directory: directory)
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: restarted, credentials: credentials(backend)), .locallyFenced)
        XCTAssertEqual(backend.values.count, 1)
        XCTAssertEqual(try Data(contentsOf: content), Data("retained content fixture".utf8))
    }

    func testFenceMatchingReferenceStillBlocksUnreadableOrMalformedKey() throws {
        let journal = InstallationJournal(); journal.record = try record(phase: .locallyFenced)
        let backend = InstallationBackend(); backend.values[reference] = Data([1])
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.credentialUnavailable))
        backend.values[reference] = secret; backend.readFailure = .inaccessible(status: -25308)
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.credentialUnavailable))
        XCTAssertEqual(backend.values.count, 1)
    }

    func testRepeatedFencedTransitionsRetainEveryCredentialAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DeviceManagementTransitionStore(directory: root)
        let backend = InstallationBackend()
        let first = try record()
        _ = try stage(first, journal: journal, credentials: credentials(backend))
        let fencedFirst = try first.fenced(); try journal.save(fencedFirst)
        let second = try fencedFirst.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate-second")
        _ = try stage(second, journal: journal, credentials: credentials(backend))
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.pendingIntent))
        try journal.save(second.fenced())
        let restarted = DeviceManagementTransitionStore(directory: root)
        XCTAssertEqual(try restarted.load()?.transitions.count, 2)
        XCTAssertEqual(try restarted.load()?.credentials.count, 2)
        XCTAssertEqual(Set(backend.values.keys), [reference, "candidate-second"])
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: restarted, credentials: credentials(backend)), .locallyFenced)
    }

    func testTwoCredentialGenerationsBelongToOneIntentWithoutActiveSelection() throws {
        let journal = InstallationJournal(); let backend = InstallationBackend()
        let first = try record()
        _ = try stage(first, journal: journal, credentials: credentials(backend))
        let second = try first.appendingCredential(credentialGenerationID: UUID(), credentialReference: "candidate-rotation")
        _ = try stage(second, journal: journal, credentials: credentials(backend))
        XCTAssertEqual(second.transitions.count, 1)
        XCTAssertEqual(second.credentials.count, 2)
        XCTAssertEqual(Set(second.credentials.map(\.transitionID)), [first.transitions[0].transitionID])
        XCTAssertEqual(Set(backend.values.keys), [reference, "candidate-rotation"])
        XCTAssertEqual(backend.generations, 2)
        journal.record = try second.fenced()
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .locallyFenced)
    }

    func testMissingPriorGenerationBlocksAdditionalStagingWithoutNewKey() throws {
        let journal = InstallationJournal(); let first = try record(); journal.record = first
        let backend = InstallationBackend()
        let second = try first.appendingCredential(credentialGenerationID: UUID(), credentialReference: "candidate-rotation")
        XCTAssertThrowsError(try stage(second, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .missingCredential)
        }
        XCTAssertEqual(journal.saves, 0)
        XCTAssertEqual(backend.generations, 0)
        XCTAssertEqual(backend.inserts, 0)
    }

    func testRetainedFencedOrphanPreventsNextTransitionStaging() throws {
        let journal = InstallationJournal(); let backend = InstallationBackend()
        let first = try record(); _ = try stage(first, journal: journal, credentials: credentials(backend))
        let fenced = try first.fenced(); journal.record = fenced
        backend.values["orphan-fixture"] = secret
        let next = try fenced.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate-next")
        let saves = journal.saves; let generations = backend.generations
        XCTAssertThrowsError(try stage(next, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .orphanedCredential)
        }
        XCTAssertEqual(journal.saves, saves)
        XCTAssertEqual(backend.generations, generations)
        XCTAssertNil(backend.values["candidate-next"])
    }

    func testHistoryAppendRacingInsertionRejectsReturnedMaterial() throws {
        let journal = InstallationJournal(); let backend = InstallationBackend(); let first = try record()
        let appended = try first.appendingCredential(credentialGenerationID: UUID(), credentialReference: "candidate-raced")
        backend.onInsert = { journal.record = appended }
        XCTAssertThrowsError(try stage(first, journal: journal, credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .unconfirmedIntent)
        }
        XCTAssertEqual(journal.record, appended)
        XCTAssertEqual(backend.values.count, 1)
    }

    func testVersionOneFenceMigrationPreservesKeyThenPermitsNewHistoryAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = DeviceManagementTransitionStore(directory: root)
        let legacy = try DeviceManagementTransitionRecord(transitionID: UUID(), credentialReference: reference, phase: .locallyFenced)
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: journal.recordURL)
        let backend = InstallationBackend(); backend.values[reference] = secret
        let migrated = try XCTUnwrap(journal.load())
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.credentials[0].credentialReference, reference)
        XCTAssertNotEqual(migrated.credentials[0].credentialGenerationID, legacy.transitionID)
        XCTAssertEqual(try journal.load(), migrated)
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .locallyFenced)
        XCTAssertEqual(try Data(contentsOf: journal.recordURL), original) // Inspection alone does not rewrite migration.
        let next = try migrated.appendingIntent(transitionID: UUID(), credentialGenerationID: UUID(), credentialReference: "candidate-migrated-next")
        _ = try stage(next, journal: journal, credentials: credentials(backend))
        XCTAssertEqual(try journal.load(), next)
        XCTAssertEqual(Set(backend.values.keys), [reference, "candidate-migrated-next"])
        XCTAssertEqual(CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials(backend)), .blocked(.pendingIntent))
    }

    func testFencedIntentCannotStageOrRegenerateCredential() throws {
        let backend = InstallationBackend()
        XCTAssertThrowsError(try stage(try record(phase: .locallyFenced), journal: InstallationJournal(), credentials: credentials(backend))) {
            XCTAssertEqual($0 as? CloudInstallationStagingError, .notIntent)
        }
        XCTAssertEqual(backend.generations, 0)
    }
}

private final class InstallationJournal: CloudInstallationTransitionJournal {
    var record: DeviceManagementTransitionHistory?
    var loadFailure = false
    var writeThenThrow = false
    var loads = 0
    var saves = 0
    func load() throws -> DeviceManagementTransitionHistory? {
        loads += 1
        if loadFailure { throw CocoaError(.fileReadUnknown) }
        return record
    }
    func save(_ record: DeviceManagementTransitionHistory) throws {
        saves += 1; self.record = record
        if writeThenThrow { throw CocoaError(.fileWriteUnknown) }
    }
}
private final class InstallationBackend: CloudInstallationCredentialBackend, @unchecked Sendable {
    enum Mode { case normal, duplicate, writeThenThrow, differentThenThrow, missingReadback }
    var mode = Mode.normal
    var values: [String: Data] = [:]
    var readFailure: CloudInstallationCredentialError?
    var enumerationFailure: CloudInstallationCredentialError?
    var onGenerate: (() -> Void)?
    var onInsert: (() -> Void)?
    private(set) var reads: [String] = []
    private(set) var inserts = 0
    private(set) var generations = 0
    func noteGeneration() { generations += 1; onGenerate?() }
    func read(reference: String) throws -> Data? {
        reads.append(reference)
        if let readFailure { throw readFailure }
        return values[reference]
    }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert {
        inserts += 1
        onInsert?()
        switch mode {
        case .normal: values[reference] = secret; return .inserted
        case .duplicate: values[reference] = Data(repeating: 8, count: 32); return .alreadyExists
        case .writeThenThrow: values[reference] = secret; throw CocoaError(.fileWriteUnknown)
        case .differentThenThrow: values[reference] = Data(repeating: 8, count: 32); throw CocoaError(.fileWriteUnknown)
        case .missingReadback: return .inserted
        }
    }
    func references() throws -> Set<String> {
        if let enumerationFailure { throw enumerationFailure }
        return Set(values.keys)
    }
}
