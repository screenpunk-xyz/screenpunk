import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeEnrollmentPairedEvidenceStoreTests: XCTestCase {
#if canImport(Darwin)
    private final class QualificationAssertionObserver: NSObject, XCTestObservation {
        weak var expected: XCTestCase?
        let marker: FileHandle
        private let lock = NSLock()
        private var recorded = false
        init(expected: XCTestCase, marker: FileHandle) { self.expected = expected; self.marker = marker }
        func testCase(_ testCase: XCTestCase, didFailWithDescription _: String, inFile _: String?, atLine _: Int) {
            guard let expected, testCase === expected else { return }
            lock.lock(); defer { lock.unlock() }
            guard !recorded else { return }; recorded = true
            do { try marker.write(contentsOf: Data("first-assertion-failure\n".utf8)); try marker.synchronize() }
            catch { NativeEnrollmentPairedEvidenceStoreTests.markerUnsupported() }
        }
    }
    private var qualificationObserver: QualificationAssertionObserver?
    private static func markerUnsupported() {
        try? FileHandle.standardError.write(contentsOf: Data("PAIRED_QUALIFICATION_ASSERTION_MARKER_UNSUPPORTED\n".utf8))
        _ = Darwin.kill(getpid(), SIGTERM) // Only the exact supervised testcase process.
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let configured = ProcessInfo.processInfo.environment["SCREENPUNK_PAIRED_QUALIFICATION_MARKER_DIRECTORY"] else { return }
        let selected = [
            "testCommandPoolEscapedStagePairAndDiagnosticRetainExactInputs",
            "testCommandPoolDiagnosticThrowAndMutationPreserveExitGuards",
            "testCommandPoolOriginalFaultRecoveryAndTerminalNextRetainInputs",
            "testSixtyThreePublicPreparationsFinishAtExact759NodesWithoutPruning",
            "testScannerAndReservationUpperBoundsDoNotAssertOperationalReachability",
            "testUnknownInitialNamespaceBlocksBeforeJournalInitializationEffects",
            "testWorkspaceReservationAndLegacyCanonicalBoundsRemainIndependent"
        ]
        guard selected.contains(where: { name.hasSuffix(" " + $0 + "]") || name.hasSuffix("." + $0) }) else { return }
        enum MarkerSetup: Error { case invalidOwnedDirectory }
        do {
            let fixed = "/Users/gsuter/Repo/Screenpunk/Planning-Files/Native-Production-Recovery-2026-10-05/paired-evidence/pool-qualification-supervision"
            guard configured.utf8.count <= 4096, let physical = realpath(configured, nil) else { throw MarkerSetup.invalidOwnedDirectory }
            let canonical = String(cString: physical); free(physical)
            let directory = URL(fileURLWithPath: configured, isDirectory: true)
            let owner = directory.deletingLastPathComponent().lastPathComponent
            guard canonical.utf8.elementsEqual(configured.utf8), directory.lastPathComponent == "marker",
                directory.deletingLastPathComponent().deletingLastPathComponent().path.utf8.elementsEqual(fixed.utf8),
                owner.hasPrefix("supervisor-"), owner.utf8.count <= 100,
                owner.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
                try FileManager.default.contentsOfDirectory(atPath: configured).isEmpty else { throw MarkerSetup.invalidOwnedDirectory }
            let fd = open(directory.appendingPathComponent("first-assertion.marker").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw MarkerSetup.invalidOwnedDirectory }
            let observer = QualificationAssertionObserver(expected: self, marker: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
            qualificationObserver = observer // Strong lifetime until teardown, including all assertions.
            XCTestObservationCenter.shared.addTestObserver(observer)
        } catch {
            Self.markerUnsupported() // Unsupported setup must never look supervised.
            throw error
        }
    }
    override func tearDownWithError() throws {
        if let observer = qualificationObserver {
            XCTestObservationCenter.shared.removeTestObserver(observer)
            try? observer.marker.close()
            qualificationObserver = nil
        }
        try super.tearDownWithError()
    }
#endif
    private final class Backend: NativeEnrollmentStageBackend {
        var items: [NativeEnrollmentRawCredentialItem] = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("legacy".utf8), persistentReference: Data([0]), payload: Data(repeating: 7, count: 32))]
        var adds = 0
        func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem] { Array(items.prefix(limit)) }
        func generate48() throws -> Data { Data(repeating: 0xB7, count: 48) }
        func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult {
            adds += 1; let ref = Data([0, UInt8(adds)])
            items.append(.init(service: Data(NativeEnrollmentStageEnvelope.service.utf8), account: account, persistentReference: ref, payload: payload)); return .added(ref)
        }
        func readPersistentReference(_ ref: Data) throws -> NativeEnrollmentRawCredentialItem? { items.first { $0.persistentReference == ref } }
    }
    private struct Fixture {
        let parent: URL, root: URL, local: URL, rootID: UUID, preparation: NativeEnrollmentPreparation, bytes: Data
        func journal() -> NativeEnrollmentJournalStore { .init(root: root, cloudRootID: rootID, excludedLocalResetRoot: local) }
    }
    private func fixture() throws -> Fixture {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true); free(physical)
        let parent = base.appendingPathComponent("native-pair-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("cloud", isDirectory: true), local = parent.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        try Data("local-keep".utf8).write(to: local.appendingPathComponent("sentinel"))
        let old = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "legacy", format: .legacyLocal32)
        let h = try DeviceManagementFormatHistory(transitions: [.init(transitionID: old.transitionID, phase: .locallyFenced)], credentials: [old])
        let p = try preparation(index: 0, history: h, enrollment: .init(), retained: [], inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
        return .init(parent: parent, root: root, local: local, rootID: UUID(), preparation: p, bytes: try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p))
    }
    private func preparation(index: Int, history: DeviceManagementFormatHistory, enrollment: NativeEnrollmentEvidence,
        retained: [NativeEnrollmentPreparation], inventory: NativeEnrollmentPreparation.Inventory) throws -> NativeEnrollmentPreparation {
        let b = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "native-\(index)", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: b.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301} \(index)", profile: " iPad ")
        return try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage-\(index)", binding: b, claimInput: input, history: history, enrollment: enrollment, retained: retained, inventory: inventory)
    }
    private func start(_ f: Fixture, _ j: NativeEnrollmentJournalStore, _ b: Backend) throws {
        _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID())
        try stage(f.preparation, journal: j, backend: b)
    }
    private func stage(_ p: NativeEnrollmentPreparation, journal: NativeEnrollmentJournalStore, backend: Backend) throws {
        _ = try NativeEnrollmentStageBridge(journal: journal, backend: backend).stageOriginalExact(preparationID: p.preparationId, stageAttemptID: UUID(), ownershipAttemptID: UUID(), currentHistory: p.sourceHistory, currentEnrollment: p.sourceEnrollment)
    }
    private func latest(_ root: URL) throws -> UUID {
        let dir = root.appendingPathComponent("attempts")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        return try NativeJournalCodec.attempt(Data(contentsOf: dir.appendingPathComponent(XCTUnwrap(names.last)))).attemptID
    }
    private func assertPair(_ p: NativeEnrollmentPreparation, root: URL, target: Bool) throws {
        let history = target ? p.targetHistory : p.sourceHistory
        let payload = try NativePairFiles.Payload(history: nativeEnrollmentBytes(history), enrollment: NativeEnrollmentEvidenceCodec.encode(target ? p.targetEnrollment : p.sourceEnrollment, history: history))
        let dir = root.appendingPathComponent("evidence")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(NativePairFiles.historyName)), payload.history)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(NativePairFiles.enrollmentName)), payload.enrollment)
    }
    func testActualPairReceiptAndExactDuplicatePreserveBytesAndOnlyLocalMeaning() throws {
        let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
        var events: [NativeEnrollmentPairedEvidenceStore.Boundary] = []
        let store = NativeEnrollmentPairedEvidenceStore(journal: j) { events.append($0) }, original = try store.beginOriginal(preparationID: f.preparation.preparationId)
        let first = try store.continueExact(original), second = try store.continueExact(original)
        XCTAssertEqual(first.completionAttemptID, second.completionAttemptID); XCTAssertEqual(events.count, 12)
        try assertPair(f.preparation, root: f.root, target: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).count, 12)
        XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("local-keep".utf8)); XCTAssertEqual(b.adds, 1)
    }
    func testCommandPoolEscapedStagePairAndDiagnosticRetainExactInputs() throws {
        let f = try fixture(), j = f.journal(), backend = Backend(); try start(f, j, backend)
        let checkpoint = try j.captureBoundStage(preparationID: f.preparation.preparationId)
        let expected = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(f.bytes)
        XCTAssertEqual(Data(checkpoint.step.proposal.claimInput.name.utf8), Data(expected.claimInput.name.utf8))
        XCTAssertEqual(Data(checkpoint.step.proposal.claimInput.profile.utf8), Data(expected.claimInput.profile.utf8))
        XCTAssertEqual(Data(checkpoint.step.proposal.stageReference.utf8), Data(expected.stageReference.utf8))
        try j.verifyStageCheckpoint(checkpoint)
        let original = try j.capturePairOriginal(preparationID: f.preparation.preparationId)
        var escaped: NativeEnrollmentJournalStore.Diagnostic?
        try j.diagnose { value in
            escaped = value
            try f.journal().diagnose { _ in }
        }
        let retained = try XCTUnwrap(escaped)
        XCTAssertEqual(retained.attemptID, try latest(f.root))
        XCTAssertEqual(Data(retained.step.proposal.claimInput.name.utf8), Data(expected.claimInput.name.utf8))
        XCTAssertEqual(Data(retained.step.proposal.binding.credentialReference.utf8), Data(expected.binding.credentialReference.utf8))
        try j.verifyPairOriginal(original)
        while try j.advancePairOriginal(original) != nil { }
        let completion = try j.qualifyPairOriginal(original)
        XCTAssertEqual(completion, try latest(f.root))
        try assertPair(f.preparation, root: f.root, target: true)
        // Historical delivered fields remain owned after later commands drain.
        XCTAssertEqual(Data(retained.step.proposal.claimInput.name.utf8), Data("Cafe\u{301} 0".utf8))
        XCTAssertEqual(backend.adds, 1)
    }
    func testCommandPoolDiagnosticThrowAndMutationPreserveExitGuards() throws {
        let f = try fixture(), j = f.journal(), backend = Backend(); try start(f, j, backend)
        enum Stop: Error { case callback }
        XCTAssertThrowsError(try j.diagnose { _ in throw Stop.callback })
        try j.diagnose { _ in try f.journal().diagnose { _ in } }
        let original = try j.capturePairOriginal(preparationID: f.preparation.preparationId)
        XCTAssertThrowsError(try j.diagnose { _ in
            _ = try f.journal().recommitExactLatestTip(expectedAttemptID: self.latest(f.root))
        })
        XCTAssertThrowsError(try j.verifyPairOriginal(original))
        _ = try j.recommitExactLatestTip(expectedAttemptID: latest(f.root))
        let replacement = try j.capturePairOriginal(preparationID: f.preparation.preparationId)
        while try j.advancePairOriginal(replacement) != nil { }
        _ = try j.qualifyPairOriginal(replacement)
        try assertPair(f.preparation, root: f.root, target: true)
        XCTAssertEqual(backend.adds, 1)
    }
    func testCommandPoolOriginalFaultRecoveryAndTerminalNextRetainInputs() throws {
        let f = try fixture(), j = f.journal(), backend = Backend(); try start(f, j, backend)
        var armed = true
        let paired = NativeEnrollmentPairedEvidenceStore(journal: j) { boundary in
            if armed && boundary == .targetBound { armed = false; throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        let original = try paired.beginOriginal(preparationID: f.preparation.preparationId)
        XCTAssertThrowsError(try paired.continueExact(original)); XCTAssertFalse(armed)
        _ = try paired.continueExact(original)
        let completed = try completedModel(f.preparation, retained: [], backend: backend)
        for phase in [NativeEnrollmentPreparation.Phase.promotionAttempted, .promotionQualified, .complete] {
            XCTAssertTrue(try j.appendPhaseAssertion(preparationID: completed.preparationId, next: phase, attemptID: UUID()).qualifiesCurrentJournalTip)
        }
        let previous = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(f.bytes, phase: 6))
        let nextPreparation = try next(completed, retained: [completed], index: 1)
        let nextBytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(nextPreparation, retained: [previous])
        let nextAttempt = UUID(), receipt = try j.prepareIntent(nextBytes, attemptID: nextAttempt)
        XCTAssertEqual(receipt.journalAttemptID, nextAttempt); XCTAssertTrue(receipt.qualifiesCurrentJournalTip)
        let checkpoint = try j.captureStageIntent(preparationID: nextPreparation.preparationId)
        XCTAssertEqual(Data(checkpoint.step.proposal.claimInput.name.utf8), Data(nextPreparation.claimInput.name.utf8))
        XCTAssertEqual(try nativeEnrollmentBytes(checkpoint.step.proposal.sourceHistory), try nativeEnrollmentBytes(nextPreparation.sourceHistory))
        XCTAssertEqual(try nativeEnrollmentBytes(checkpoint.step.proposal.sourceEnrollment), try nativeEnrollmentBytes(nextPreparation.sourceEnrollment))
        try j.verifyStageCheckpoint(checkpoint)
        try assertPair(completed, root: f.root, target: true)
        XCTAssertEqual(backend.adds, 1)
        // Synthetic completed model/final inventory is consistency only, never
        // production immutable final-reference or promotion qualification.
    }
    func testMetadataStageAssertionCannotMintPairCursor() throws {
        let f = try fixture(), j = f.journal(); _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID())
        for phase in [NativeEnrollmentPreparation.Phase.stageAttempted, .stageQualified] { _ = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: phase, attemptID: UUID()) }
        XCTAssertThrowsError(try NativeEnrollmentPairedEvidenceStore(journal: j).beginOriginal(preparationID: f.preparation.preparationId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("evidence").path))
    }
    func testEveryOutsideLockBoundaryAllowsOriginalRetryWithoutNewStages() throws {
        let boundaries: [NativeEnrollmentPairedEvidenceStore.Boundary] = [.rootReserved, .rootCreated, .rootBound, .rootSynchronized, .sourceReserved, .sourceCreated, .sourceBound, .sourceSynchronized, .targetReserved, .targetCreated, .targetBound, .targetSynchronized]
        for point in boundaries {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b); var armed = true
            let store = NativeEnrollmentPairedEvidenceStore(journal: j) { if armed && $0 == point { armed = false; throw NativeEnrollmentJournalError.outcomeUncertain } }
            let original = try store.beginOriginal(preparationID: f.preparation.preparationId)
            XCTAssertThrowsError(try store.continueExact(original)); XCTAssertFalse(armed)
            _ = try store.continueExact(original); try assertPair(f.preparation, root: f.root, target: true); XCTAssertEqual(b.adds, 1)
        }
    }
    func testRestartBlocksUnboundRootAndCandidatesButResumesRecordedBindings() throws {
        for (point, recoverable) in [(NativeEnrollmentPairedEvidenceStore.Boundary.rootReserved, true), (.rootCreated, false), (.rootBound, true), (.sourceCreated, false), (.sourceBound, true), (.targetCreated, false), (.targetBound, true), (.targetSynchronized, true)] {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b); var armed = true
            let first = NativeEnrollmentPairedEvidenceStore(journal: j) { if armed && $0 == point { armed = false; throw NativeEnrollmentJournalError.outcomeUncertain } }
            XCTAssertThrowsError(try first.continueExact(first.beginOriginal(preparationID: f.preparation.preparationId)))
            let restarted = f.journal(), next = NativeEnrollmentPairedEvidenceStore(journal: restarted)
            XCTAssertThrowsError(try next.recoverRecorded(preparationID: f.preparation.preparationId))
            if recoverable {
                _ = try restarted.recommitExactLatestTip(expectedAttemptID: latest(f.root))
                _ = try next.continueExact(next.recoverRecorded(preparationID: f.preparation.preparationId)); try assertPair(f.preparation, root: f.root, target: true)
            } else { XCTAssertThrowsError(try restarted.recommitExactLatestTip(expectedAttemptID: latest(f.root))) }
            XCTAssertEqual(b.adds, 1)
        }
    }
    func testFourInterruptedSourceTargetCombinationsRequireExplicitExactRecommit() throws {
        for mask in 0..<4 {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b); var armed = true
            let store = NativeEnrollmentPairedEvidenceStore(journal: j) { if armed && $0 == .targetBound { armed = false; throw NativeEnrollmentJournalError.outcomeUncertain } }
            XCTAssertThrowsError(try store.continueExact(store.beginOriginal(preparationID: f.preparation.preparationId)))
            let dir = f.root.appendingPathComponent("evidence")
            try overwrite(dir.appendingPathComponent(NativePairFiles.targetHistory), bytes: nativeEnrollmentBytes(f.preparation.targetHistory))
            try overwrite(dir.appendingPathComponent(NativePairFiles.targetEnrollment), bytes: NativeEnrollmentEvidenceCodec.encode(f.preparation.targetEnrollment, history: f.preparation.targetHistory))
            for (bit, name, pending) in [(1, NativePairFiles.historyName, NativePairFiles.targetHistory), (2, NativePairFiles.enrollmentName, NativePairFiles.targetEnrollment)] where mask & bit != 0 {
                try FileManager.default.moveItem(at: dir.appendingPathComponent(name), to: f.parent.appendingPathComponent("old-" + name))
                try FileManager.default.moveItem(at: dir.appendingPathComponent(pending), to: dir.appendingPathComponent(name))
            }
            let restarted = f.journal(), recovered = NativeEnrollmentPairedEvidenceStore(journal: restarted)
            XCTAssertThrowsError(try recovered.recoverRecorded(preparationID: f.preparation.preparationId))
            _ = try restarted.recommitExactLatestTip(expectedAttemptID: latest(f.root))
            _ = try recovered.continueExact(recovered.recoverRecorded(preparationID: f.preparation.preparationId)); try assertPair(f.preparation, root: f.root, target: true)
        }
    }
    func testCompletedPairDeletionAndSameBytesReplacementBlockRestart() throws {
        for path in ["history.v3.json", "enrollment.v1.json", "pair-binding.json", "pair.lock"] {
            for replace in [false, true] {
                let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
                let store = NativeEnrollmentPairedEvidenceStore(journal: j); _ = try store.continueExact(store.beginOriginal(preparationID: f.preparation.preparationId))
                let url = f.root.appendingPathComponent("evidence/" + path), bytes = try Data(contentsOf: url)
                try FileManager.default.moveItem(at: url, to: f.parent.appendingPathComponent("retained-" + path))
                if replace { try bytes.write(to: url) }
                XCTAssertThrowsError(try f.journal().recommitExactLatestTip(expectedAttemptID: latest(f.root)))
            }
        }
    }
    func testRootReplacementUnknownNamesSymlinkAndMissingNamespaceNeverBecomeAbsence() throws {
        for variant in 0..<4 {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
            let store = NativeEnrollmentPairedEvidenceStore(journal: j), original = try store.beginOriginal(preparationID: f.preparation.preparationId)
            _ = try store.continueExact(original); let dir = f.root.appendingPathComponent("evidence")
            if variant == 0 { try Data().write(to: dir.appendingPathComponent("unknown")) }
            else {
                let retained = f.parent.appendingPathComponent("retained-evidence"); try FileManager.default.moveItem(at: dir, to: retained)
                if variant == 1 { try FileManager.default.copyItem(at: retained, to: dir) }
                if variant == 2 { try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: retained) }
            }
            XCTAssertThrowsError(try store.continueExact(original)); XCTAssertThrowsError(try f.journal().recommitExactLatestTip(expectedAttemptID: latest(f.root)))
        }
    }
    func testReadOnlyReentryOutsideLocksAndForeignRecommitInvalidateOriginal() throws {
        for mutate in [false, true] {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b); var delivered = false
            let store = NativeEnrollmentPairedEvidenceStore(journal: j) { event in
                if event == .sourceReserved {
                    try j.diagnose { _ in }; try f.journal().diagnose { _ in }; delivered = true
                    if mutate { _ = try f.journal().recommitExactLatestTip(expectedAttemptID: self.latest(f.root)) }
                }
            }
            let original = try store.beginOriginal(preparationID: f.preparation.preparationId)
            if mutate { XCTAssertThrowsError(try store.continueExact(original)); XCTAssertThrowsError(try store.continueExact(original)) }
            else { _ = try store.continueExact(original) }
            XCTAssertTrue(delivered)
        }
        // Each resumed outside-lock command must read the original physical
        // witnesses again, even when the management epoch has not changed.
        for variant in 0..<4 {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
            let directory = f.root.appendingPathComponent(variant == 1 || variant == 3 ? "attempts" : "frames")
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }.first)
            let bytes = try Data(contentsOf: file)
            var changed = false
            let store = NativeEnrollmentPairedEvidenceStore(journal: j) { event in
                if event == .sourceReserved && !changed {
                    changed = true
                    if variant == 2 { try bytes.write(to: file, options: .atomic) }
                    else {
                        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                        if variant == 3 {
                            let marker = try XCTUnwrap(bytes.range(of: Data("\"intentPayload\":\"".utf8)))
                            try handle.seek(toOffset: UInt64(marker.upperBound)); try handle.write(contentsOf: Data([0x3F]))
                        } else { try handle.seekToEnd(); try handle.write(contentsOf: Data([0x20])) }
                        try handle.synchronize()
                    }
                }
            }
            let original = try store.beginOriginal(preparationID: f.preparation.preparationId)
            XCTAssertThrowsError(try store.continueExact(original))
            XCTAssertTrue(changed)
            XCTAssertThrowsError(try store.continueExact(original))
            XCTAssertEqual(b.adds, 1)
        }
    }
    func testOldOperationCannotQualifyAChangedLatestTip() throws {
        let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
        let store = NativeEnrollmentPairedEvidenceStore(journal: j), original = try store.beginOriginal(preparationID: f.preparation.preparationId)
        _ = try store.continueExact(original)
        _ = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .promotionAttempted, attemptID: UUID())
        XCTAssertThrowsError(try store.continueExact(original))
    }
    func testWorkspaceReservationAndLegacyCanonicalBoundsRemainIndependent() throws {
        try NativeJournalCodec.pairedLayoutReservationProof()
        XCTAssertEqual(NativeJournalCodec.totalReservationLimit, 134217728)
        XCTAssertEqual(NativeJournalCodec.pairedCompletionReservation, 16629760)
        XCTAssertEqual(NativeJournalCodec.pairedReservationLimit, 33554432)
        XCTAssertEqual(NativeJournalCodec.combinedReservationLimit, 167772160)
        XCTAssertEqual(NativeJournalCodec.nodeLimit, 771); XCTAssertEqual(NativeJournalCodec.nameLimit, 1542)
        XCTAssertEqual(NativeJournalCodec.compactDeclarationLimit, 394752)
        let f = try fixture(), old = try NativeJournalCodec.reservation(intentBytes: f.bytes.count)
        XCTAssertEqual(old, ((f.bytes.count + 2) / 3) * 4 + 32768 + 7 * 8192 + 6 * 32768 + 8192)
        let id = UUID(), frame = NativeJournalFrame(schemaVersion: 1, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id, index: 449, phase: 3)
        XCTAssertThrowsError(try NativeJournalCodec.frame(NativeJournalCodec.encode(frame)))
        let extended = NativeJournalFrame(schemaVersion: 3, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id, index: 771, phase: 3)
        XCTAssertEqual(try NativeJournalCodec.frame(NativeJournalCodec.encode(extended)), extended)
        let over = NativeJournalFrame(schemaVersion: 3, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id, index: 772, phase: 3)
        XCTAssertThrowsError(try NativeJournalCodec.frame(NativeJournalCodec.encode(over)))
    }
    // Synthetic final inventory only. This fixture does not qualify a production
    // promotion or immutable final persistent-reference ownership.
    private func completedModel(_ p: NativeEnrollmentPreparation, retained: [NativeEnrollmentPreparation], backend: Backend) throws -> NativeEnrollmentPreparation {
        var finals: [String: NativeEnrollmentPreparation.FinalItem] = ["legacy": .legacy32]
        var stages: [String: NativeEnrollmentPreparation.StageItem] = [:]
        for item in retained + [p] {
            stages[item.stageReference] = .descriptor(.init(preparationId: item.preparationId, enrollmentId: item.enrollmentId, stageReference: item.stageReference, binding: item.binding, claimInput: item.claimInput))
            if item.preparationId != p.preparationId { finals[item.binding.credentialReference] = .native48 }
        }
        let staged = NativeEnrollmentPreparation.Inventory(finalItems: finals, stageItems: stages)
        var result = try p.proposingObservation(.stageAttempted, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: staged, retained: retained)
        result = try result.proposingObservation(.stageQualified, history: p.sourceHistory, enrollment: p.sourceEnrollment, inventory: staged, retained: retained)
        result = try result.proposingObservation(.pairedEvidenceQualified, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: staged, retained: retained)
        let envelope = try XCTUnwrap(backend.items.last { $0.account == Data(p.stageReference.utf8) })
        backend.items.append(.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data(p.binding.credentialReference.utf8), persistentReference: Data([1, UInt8(backend.adds)]), payload: Data(envelope.keychainPayload().suffix(48))))
        finals[p.binding.credentialReference] = .native48
        let full = NativeEnrollmentPreparation.Inventory(finalItems: finals, stageItems: stages)
        for phase in [NativeEnrollmentPreparation.Phase.promotionAttempted, .promotionQualified, .complete] {
            result = try result.proposingObservation(phase, history: p.targetHistory, enrollment: p.targetEnrollment, inventory: full, retained: retained)
        }
        return result
    }
    private func next(_ old: NativeEnrollmentPreparation, retained: [NativeEnrollmentPreparation], index: Int) throws -> NativeEnrollmentPreparation {
        let history = try DeviceManagementFormatHistory(transitions: old.targetHistory.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: old.targetHistory.credentials)
        var finals: [String: NativeEnrollmentPreparation.FinalItem] = ["legacy": .legacy32]
        var stages: [String: NativeEnrollmentPreparation.StageItem] = [:]
        for p in retained {
            finals[p.binding.credentialReference] = .native48
            stages[p.stageReference] = .descriptor(.init(preparationId: p.preparationId, enrollmentId: p.enrollmentId, stageReference: p.stageReference, binding: p.binding, claimInput: p.claimInput))
        }
        return try preparation(index: index, history: history, enrollment: old.targetEnrollment, retained: retained, inventory: .init(finalItems: finals, stageItems: stages))
    }
    func testNonemptyNextSourceImportRequiresActualPreviousPairNotHistoricalIntentAlone() throws {
        for tamper in [false, true] {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
            let first = NativeEnrollmentPairedEvidenceStore(journal: j); _ = try first.continueExact(first.beginOriginal(preparationID: f.preparation.preparationId))
            let old = try completedModel(f.preparation, retained: [], backend: b)
            for phase in [NativeEnrollmentPreparation.Phase.promotionAttempted, .promotionQualified, .complete] { _ = try j.appendPhaseAssertion(preparationID: old.preparationId, next: phase, attemptID: UUID()) }
            let previous = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(f.bytes, phase: 6))
            let p = try next(old, retained: [old], index: 1)
            let bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p, retained: [previous])
            _ = try j.prepareIntent(bytes, attemptID: UUID()); try stage(p, journal: j, backend: b)
            if tamper {
                let url = f.root.appendingPathComponent("evidence/history.v3.json"), saved = try Data(contentsOf: url)
                try FileManager.default.moveItem(at: url, to: f.parent.appendingPathComponent("old-history")); try saved.write(to: url)
                XCTAssertThrowsError(try first.beginOriginal(preparationID: p.preparationId))
            } else {
                let attempt = try first.beginOriginal(preparationID: p.preparationId); _ = try first.continueExact(attempt)
                try assertPair(p, root: f.root, target: true)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).count, 24)
            }
        }
    }
    // Explicitly invoked allocation experiment, NEVER capacity qualification.
    // The unchanged 64/771 method below remains the required capacity regression.
    func testBoundedCommandMemoryDiagnosticDarwin() throws {
        #if canImport(Darwin)
        enum DiagnosticStop: Error { case unsafeEvidenceRoot, counters(kern_return_t), resourceLimit, timeLimit }
        struct Counters: Encodable {
            let arm: String, checkpoint: String, preparation: Int, nodes: Int
            let elapsedNanoseconds: UInt64, footprint: UInt64, resident: UInt64
            let mallocBlocksInUse: UInt64, mallocSizeInUse: UInt64
            let mallocSizeAllocated: UInt64, mallocMaximumSizeInUse: UInt64
            // Live/peak zone statistics, NOT allocation-event counts.
        }
        guard let configured = ProcessInfo.processInfo.environment["SCREENPUNK_PAIRED_MEMORY_DIAGNOSTIC_ROOT"] else {
            throw XCTSkip("Explicit bounded memory diagnostic requires an owned evidence root")
        }
        let fixed = "/Users/gsuter/Repo/Screenpunk/Planning-Files/Native-Production-Recovery-2026-10-05/paired-evidence/memory-diagnostic"
        guard configured.utf8.elementsEqual(fixed.utf8), let physical = realpath(configured, nil) else { throw DiagnosticStop.unsafeEvidenceRoot }
        let physicalPath = String(cString: physical); free(physical)
        guard physicalPath.utf8.elementsEqual(configured.utf8) else { throw DiagnosticStop.unsafeEvidenceRoot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configured, isDirectory: &isDirectory), isDirectory.boolValue else { throw DiagnosticStop.unsafeEvidenceRoot }
        let evidence = URL(fileURLWithPath: configured, isDirectory: true).appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
        let logURL = evidence.appendingPathComponent("counters.jsonl")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw DiagnosticStop.unsafeEvidenceRoot }
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        print("PAIRED_MEMORY_DIAGNOSTIC_EVIDENCE " + evidence.path)
        // A durable fixed marker makes first-assertion detection independent
        // of XCTest/stdout buffering. Failure descriptions are never recorded.
        final class AssertionObserver: NSObject, XCTestObservation {
            weak var expected: XCTestCase?
            let marker: FileHandle
            private let lock = NSLock()
            private var recorded = false
            init(expected: XCTestCase, marker: FileHandle) { self.expected = expected; self.marker = marker }
            func testCase(_ testCase: XCTestCase, didFailWithDescription _: String, inFile _: String?, atLine _: Int) {
                guard let expected, testCase === expected else { return }
                lock.lock(); defer { lock.unlock() }
                guard !recorded else { return }; recorded = true
                do { try marker.write(contentsOf: Data("first-assertion-failure\n".utf8)); try marker.synchronize() }
                catch {
                    // A failed required observation cannot be called supported.
                    try? FileHandle.standardError.write(contentsOf: Data("PAIRED_DIAGNOSTIC_ASSERTION_MARKER_UNSUPPORTED\n".utf8))
                    _ = Darwin.kill(getpid(), SIGTERM) // Only this owned diagnostic process.
                }
            }
        }
        let markerURL = evidence.appendingPathComponent("first-assertion.marker")
        guard FileManager.default.createFile(atPath: markerURL.path, contents: nil) else { throw DiagnosticStop.unsafeEvidenceRoot }
        let marker = try FileHandle(forWritingTo: markerURL)
        let observer = AssertionObserver(expected: self, marker: marker)
        XCTestObservationCenter.shared.addTestObserver(observer)
        defer { XCTestObservationCenter.shared.removeTestObserver(observer); try? marker.close() }
        let start = DispatchTime.now().uptimeNanoseconds
        var startingFootprint: UInt64?
        func checkpoint(_ arm: String, _ label: String, index: Int, root: URL?) throws {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            guard result == KERN_SUCCESS else { throw DiagnosticStop.counters(result) }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            let footprint = UInt64(info.phys_footprint)
            if startingFootprint == nil { startingFootprint = footprint }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let nodes = try root.map { try FileManager.default.contentsOfDirectory(atPath: $0.appendingPathComponent("frames").path).count } ?? 0
            let values = Counters(arm: arm, checkpoint: label, preparation: index, nodes: nodes,
                elapsedNanoseconds: elapsed, footprint: footprint, resident: UInt64(info.resident_size),
                mallocBlocksInUse: UInt64(stats.blocks_in_use), mallocSizeInUse: UInt64(stats.size_in_use),
                mallocSizeAllocated: UInt64(stats.size_allocated), mallocMaximumSizeInUse: UInt64(stats.max_size_in_use))
            var line = try JSONEncoder().encode(values); line.append(10)
            try log.write(contentsOf: line); try log.synchronize()
            // Check after saving the measurement. An external owned-process
            // supervisor must also enforce these bounds DURING a long command.
            guard elapsed < 300_000_000_000 else { throw DiagnosticStop.timeLimit }
            let delta = footprint > (startingFootprint ?? footprint) ? footprint - (startingFootprint ?? footprint) : 0
            guard footprint < 4 * 1_073_741_824, delta < 2 * 1_073_741_824 else { throw DiagnosticStop.resourceLimit }
        }
        func arm(_ pooled: Bool) throws {
            let label = pooled ? "B-inner-command-pools" : "A-no-inner-pools"
            // This fresh fixture and synthetic backend use the SAME genuine
            // command path and retained typed inputs as the capacity regression.
            let f = try fixture(), j = f.journal(), b = Backend()
            try Data((f.parent.path + "\n").utf8).write(to: evidence.appendingPathComponent(pooled ? "fixture-B.txt" : "fixture-A.txt"))
            var index = 0
            var retained: [NativeEnrollmentPreparation] = []
            var declarations: [NativeEnrollmentPreparationReconstructionProposal] = []
            var current = f.preparation
            func command<T>(_ name: String, _ body: () throws -> T) throws -> T {
                // A and B have the same checkpoints. Escaping results have
                // strong Swift ownership before an inner pool is drained.
                try checkpoint(label, name + ".before", index: index, root: index == 0 && name == "initialize" ? nil : f.root)
                let value: T
                if pooled {
                    value = try autoreleasepool {
                        let result = try body()
                        try checkpoint(label, name + ".after-body-before-drain", index: index, root: f.root)
                        return result
                    }
                } else {
                    value = try body()
                    try checkpoint(label, name + ".after-body-before-drain", index: index, root: f.root)
                }
                try checkpoint(label, name + ".after-inner-boundary", index: index, root: f.root)
                return value
            }
            _ = try command("initialize") { try j.initializeExplicit() }
            for step in 0..<8 {
                index = step
                let bytes = try command("encode-intent") { try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(current, retained: declarations) }
                _ = try command("prepare-intent") { try j.prepareIntent(bytes, attemptID: UUID()) }
                try command("stage-original") { try stage(current, journal: j, backend: b) }
                // Match continueExact's fixed journal command sequence, while
                // ending each inner pool BEFORE the outside-lock next command.
                let original = try command("capture-pair") { try j.capturePairOriginal(preparationID: current.preparationId) }
                while true {
                    let event = try command("advance-pair") { try j.advancePairOriginal(original) }
                    guard let _ = event else { break }
                    try command("verify-pair") { try j.verifyPairOriginal(original) }
                }
                _ = try command("qualify-pair") { try j.qualifyPairOriginal(original) }
                let completed = try command("synthetic-completed-model") { try completedModel(current, retained: retained, backend: b) }
                for phase in [NativeEnrollmentPreparation.Phase.promotionAttempted, .promotionQualified, .complete] {
                    _ = try command("terminal-metadata-" + String(phase.rawValue)) { try j.appendPhaseAssertion(preparationID: current.preparationId, next: phase, attemptID: UUID()) }
                }
                let declaration = try command("decode-complete") { try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(bytes, phase: 6), retained: declarations) }
                declarations.append(declaration); retained.append(completed)
                if step < 7 { current = try command("next-model") { try next(completed, retained: retained, index: step + 1) } }
            }
            XCTAssertEqual(retained.count, 8); XCTAssertEqual(declarations.count, 8)
            XCTAssertEqual(b.adds, 8)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).count, 99)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("frames").path).count, 99)
            try assertPair(current, root: f.root, target: true)
            XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("local-keep".utf8))
            // Keep required arrays/backend descriptors alive until this final
            // within-arm measurement; no pruning or secret output.
            try withExtendedLifetime((retained, declarations, b, current)) {
                try checkpoint(label, "retained-inputs-live", index: index, root: f.root)
                try checkpoint(label, "before-outer-drain", index: index, root: f.root)
            }
        }
        do {
            try checkpoint("diagnostic", "start", index: -1, root: nil)
            for pooled in [false, true] {
                // The outer pool prevents A's transients contaminating B.
                // Only B receives additional per-command inner pools.
                try autoreleasepool { try arm(pooled) }
                try checkpoint(pooled ? "B" : "A", "after-outer-drain", index: 8, root: nil)
            }
            try log.synchronize()
            print("PAIRED_MEMORY_DIAGNOSTIC_COMPLETE NOT_CAPACITY_QUALIFICATION")
        } catch {
            // Preserve counters and explicit failure evidence. Never retry or
            // turn an early resource stop into a passing diagnostic.
            let category: String
            if let stop = error as? DiagnosticStop {
                switch stop {
                case .unsafeEvidenceRoot: category = "unsafe-evidence-root"
                case .counters(let code): category = "counter-read-failed-" + String(code)
                case .resourceLimit: category = "resource-limit"
                case .timeLimit: category = "time-limit"
                }
            } else { category = "command-error-type-" + String(reflecting: type(of: error)) }
            try? Data(("Diagnostic stopped: " + category + "\n").utf8).write(to: evidence.appendingPathComponent("failure.txt"))
            try? log.synchronize()
            throw error
        }
        #else
        throw XCTSkip("Darwin VM/malloc counters are required for this diagnostic")
        #endif
    }

    func testSixtyThreePublicPreparationsFinishAtExact759NodesWithoutPruning() throws {
        let f = try fixture(), j = f.journal(), b = Backend(); _ = try j.initializeExplicit()
        var retained: [NativeEnrollmentPreparation] = [], declarations: [NativeEnrollmentPreparationReconstructionProposal] = []
        var current = f.preparation
        for index in 0..<63 {
            let bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(current, retained: declarations)
            _ = try j.prepareIntent(bytes, attemptID: UUID()); try stage(current, journal: j, backend: b)
            let paired = NativeEnrollmentPairedEvidenceStore(journal: j)
            _ = try paired.continueExact(paired.beginOriginal(preparationID: current.preparationId))
            let completed = try completedModel(current, retained: retained, backend: b)
            for phase in [NativeEnrollmentPreparation.Phase.promotionAttempted, .promotionQualified, .complete] { _ = try j.appendPhaseAssertion(preparationID: current.preparationId, next: phase, attemptID: UUID()) }
            declarations.append(try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(bytes, phase: 6), retained: declarations))
            retained.append(completed)
            if index < 62 { current = try next(completed, retained: retained, index: index + 1) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).count, 759)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("frames").path).count, 759)
        var count = 0; try j.diagnose { _ in count += 1 }; XCTAssertEqual(count, 63)
        // A nonempty legacy source consumes one of the 64 retained transitions.
        // The next unique preparation would need transition65, so it is rejected
        // by history capacity before any journal/backend effect or authority exists.
        let retainedNames = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path)
        let retainedFrameNames = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("frames").path)
        let completed = try XCTUnwrap(retained.last)
        XCTAssertThrowsError(try next(completed, retained: retained, index: 63)) { error in
            XCTAssertEqual(error as? DeviceManagementTransitionStoreError, .capacityExceeded)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path), retainedNames)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("frames").path), retainedFrameNames)
        XCTAssertEqual(retainedFrameNames.count, 759)
        XCTAssertEqual(b.adds, 63); try assertPair(current, root: f.root, target: true)
        XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("local-keep".utf8))
    }
    func testScannerAndReservationUpperBoundsDoNotAssertOperationalReachability() throws {
        XCTAssertEqual(NativeJournalCodec.preparationLimit, 64)
        XCTAssertEqual(NativeJournalCodec.legacyNodeLimit, 64 * 7)
        XCTAssertEqual(NativeJournalCodec.nodeLimit, 3 + 64 * 12)
        XCTAssertEqual(NativeJournalCodec.nameLimit, 1542)
        XCTAssertEqual(NativeJournalCodec.compactDeclarationLimit, 771 * 512)
        XCTAssertEqual(NativeJournalCodec.pairedCompletionReservation, 16_629_760)
        XCTAssertLessThanOrEqual(NativeJournalCodec.pairedCompletionReservation, NativeJournalCodec.pairedReservationLimit)
        XCTAssertEqual(NativeJournalCodec.totalReservationLimit + NativeJournalCodec.pairedReservationLimit, NativeJournalCodec.combinedReservationLimit)
        // Arithmetic-only reservation/scanner bounds; no fabricated frame, receipt,
        // history or operational 64-preparation completion is constructed here.
    }
    func testBoundCandidateReplacementAndWrongPayloadCannotBeAdopted() throws {
        for replacement in [false, true] {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b); var armed = true
            let store = NativeEnrollmentPairedEvidenceStore(journal: j) { if armed && $0 == .targetBound { armed = false; throw NativeEnrollmentJournalError.outcomeUncertain } }
            let original = try store.beginOriginal(preparationID: f.preparation.preparationId); XCTAssertThrowsError(try store.continueExact(original))
            let url = f.root.appendingPathComponent("evidence/" + NativePairFiles.targetHistory)
            if replacement { try FileManager.default.moveItem(at: url, to: f.parent.appendingPathComponent("old-candidate")); try Data().write(to: url) }
            else { try overwrite(url, bytes: Data("wrong".utf8)) }
            XCTAssertThrowsError(try store.continueExact(original)); XCTAssertThrowsError(try f.journal().recommitExactLatestTip(expectedAttemptID: latest(f.root)))
        }
    }
    private func overwrite(_ url: URL, bytes: Data) throws {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw NativeEnrollmentJournalError.io(errno) }; defer { close(fd) }
        try NativePairFiles.write(fd, bytes: bytes); try NativePairFiles.sync(fd)
    }
    func testUnknownInitialNamespaceBlocksBeforeJournalInitializationEffects() throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("evidence"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.journal().initializeExplicit())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), ["evidence"])
    }

    func testExactUTF8EnrollmentReplacementCannotQualifyEquivalentString() throws {
        let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
        let store = NativeEnrollmentPairedEvidenceStore(journal: j)
        _ = try store.continueExact(store.beginOriginal(preparationID: f.preparation.preparationId))
        let path = f.root.appendingPathComponent("evidence/enrollment.v1.json"), original = try Data(contentsOf: path)
        let altered = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Cafe\u{301}", with: "Caf\u{e9}").utf8)
        XCTAssertNotEqual(original, altered)
        try overwrite(path, bytes: altered)
        XCTAssertThrowsError(try f.journal().recommitExactLatestTip(expectedAttemptID: latest(f.root)))
    }
    func testLocalPairedFrameStrictKeysAndVersionAreNotRawWireAuthority() throws {
        let id = UUID(), pair = NativeJournalPairAssertion(role: .initReserve, operationID: UUID(), projection: .init(intentAttemptID: id, kind: .source), root: nil, baseline: nil, candidates: nil, workspaceReservation: NativeJournalCodec.pairedReservationLimit)
        let frame = NativeJournalFrame(schemaVersion: 3, cloudRootID: UUID(), preparationID: UUID(), attemptID: UUID(), intentAttemptID: id, index: 444, phase: 2, pairedEvidence: pair)
        let bytes = try NativeJournalCodec.encode(frame)
        XCTAssertEqual(try NativeJournalCodec.frame(bytes), frame)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try NativeJournalCodec.frame(Data(("{\"unknown\":0," + String(text.dropFirst())).utf8)))
        XCTAssertThrowsError(try NativeJournalCodec.frame(Data(("{\"schemaVersion\":3," + text.dropFirst()).utf8)))
        XCTAssertThrowsError(try NativeJournalCodec.frame(Data(text.replacingOccurrences(of: "initReserve", with: "futureRole").utf8)))
        let legacy = NativeJournalFrame(schemaVersion: 1, cloudRootID: frame.cloudRootID, preparationID: frame.preparationID, attemptID: frame.attemptID, intentAttemptID: id, index: 444, phase: 2, pairedEvidence: pair)
        XCTAssertThrowsError(try NativeJournalCodec.frame(NativeJournalCodec.encode(legacy)))
    }

    func testFixedJournalFaultMatrixRetainsOnlyExactOriginalRecordedMethods() throws {
        let points: [(NativeEnrollmentJournalStore.Kind, NativeEnrollmentJournalStore.Point, Bool)] = [
            (.candidate, .created, false), (.attempt, .created, false),
            (.attempt, .written, true), (.attempt, .fileSynced, true), (.attempt, .beforePublish, true),
            (.attempt, .published, true), (.attempt, .directorySynced, true), (.candidate, .written, true),
            (.candidate, .fileSynced, true), (.candidate, .beforePublish, true), (.candidate, .published, true), (.candidate, .directorySynced, true)]
        for role in [NativeJournalPairAssertion.Role.sourceReserve, .sourceBind] {
            for (kind, point, recoverable) in points {
                let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
                let store = NativeEnrollmentPairedEvidenceStore(journal: j, fault: .init(role: role, boundary: .init(kind: kind, point: point)))
                let original = try store.beginOriginal(preparationID: f.preparation.preparationId)
                XCTAssertThrowsError(try store.continueExact(original))
                if recoverable { _ = try store.continueExact(original); try assertPair(f.preparation, root: f.root, target: true) }
                else { XCTAssertThrowsError(try store.continueExact(original)) }
                XCTAssertEqual(b.adds, 1)
            }
        }
    }

    func testPhysicalWitnessCanonicalEnvelopeAndIntentLengthMatchFullDecoder() throws {
        let id = UUID(), root = UUID(), identity = NativeJournalIdentity(device: 3, inode: 5)
        for version in [1, 2] {
            for intent in [Data(), Data([1]), Data([1,2]), Data([1,2,3]), Data(repeating: 0x41, count: 65536), Data(repeating: 0x41, count: 1048576)] {
                let frame = NativeJournalFrame(schemaVersion: version == 1 ? 1 : 3, cloudRootID: root, preparationID: id, attemptID: id, intentAttemptID: id, index: 1, phase: 0)
                let target = try NativeJournalCodec.encode(frame)
                let a = NativeJournalAttempt(schemaVersion: version, cloudRootID: root, preparationID: id, attemptID: id, index: 1, method: .prepareIntent,
                    rootBindingIdentity: identity, ownIdentity: identity, predecessor: nil, candidateIdentity: identity, targetPayload: target,
                    intentPayload: intent, reservation: try NativeJournalCodec.reservation(intentBytes: intent.count))
                let bytes = try NativeJournalCodec.encode(a), full = try NativeJournalCodec.attempt(bytes), witness = try NativeJournalCodec.attemptWitness(bytes)
                XCTAssertEqual(witness.decodedIntentBytes, full.intentPayload?.count)
                XCTAssertEqual(witness.targetPayload, full.targetPayload); XCTAssertEqual(witness.reservation, full.reservation)
                XCTAssertEqual(witness.ownIdentity, full.ownIdentity); XCTAssertEqual(witness.schemaVersion, full.schemaVersion)
                XCTAssertEqual(witness.predecessor, full.predecessor)
            }
        }
        let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
        for file in try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("attempts"), includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file), full = try NativeJournalCodec.attempt(bytes), witness = try NativeJournalCodec.attemptWitness(bytes)
            XCTAssertEqual(witness.decodedIntentBytes, full.intentPayload?.count)
            XCTAssertEqual(witness.targetPayload, full.targetPayload); XCTAssertEqual(witness.predecessor, full.predecessor)
            XCTAssertEqual(witness.attemptID, full.attemptID); XCTAssertEqual(witness.rootBindingIdentity, full.rootBindingIdentity)
        }
    }
    func testPhysicalWitnessRejectsMalformedCanonicalKeysBase64AndBounds() throws {
        let id = UUID(), identity = NativeJournalIdentity(device: 3, inode: 5)
        let frame = NativeJournalFrame(schemaVersion: 1, cloudRootID: id, preparationID: id, attemptID: id, intentAttemptID: id, index: 1, phase: 0)
        let a = NativeJournalAttempt(schemaVersion: 1, cloudRootID: id, preparationID: id, attemptID: id, index: 1, method: .prepareIntent,
            rootBindingIdentity: identity, ownIdentity: identity, predecessor: nil, candidateIdentity: identity,
            targetPayload: try NativeJournalCodec.encode(frame), intentPayload: Data([1]), reservation: try NativeJournalCodec.reservation(intentBytes: 1))
        let bytes = try NativeJournalCodec.encode(a), text = String(decoding: bytes, as: UTF8.self)
        let field = "\"intentPayload\":\"AQ==\""
        XCTAssertTrue(text.contains(field)); _ = try NativeJournalCodec.attemptWitness(bytes)
        for body in ["AR==", "AQ=", "A===", "AQ==AA==", "AQ== ", "AQ\\u003d\\u003d", "AQ\\/="] {
            XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(Data(text.replacingOccurrences(of: field, with: "\"intentPayload\":\"" + body + "\"").utf8)), body)
        }
        for replacement in ["\"intentPayload\":null", "\"intentPayload\":\"AQ==\",\"intentPayload\":\"AQ==\"", "\"intent\\u0050ayload\":\"AQ==\"", "\"intentPayload\":\"AQ==\",\"intent\\u0050ayload\":\"AQ==\""] {
            XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(Data(text.replacingOccurrences(of: field, with: replacement).utf8)))
        }
        for mutation in [text + " ", " " + text, String(text.dropLast()), text.replacingOccurrences(of: "\"index\":1", with: "\"index\":1.0"), text.replacingOccurrences(of: "\"reservation\":" + String(a.reservation), with: "\"reservation\":0"), "{\"unknown\":0," + String(text.dropFirst())] {
            XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(Data(mutation.utf8)))
        }
        for surrogate in ["\\uD800", "\\uDC00", "\\uD800\\u0041"] {
            let malformed = text.replacingOccurrences(of: "\"method\":\"prepareIntent\"", with: "\"method\":\"" + surrogate + "\"")
            XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(Data(malformed.utf8)))
        }
        var invalidUTF8 = bytes
        let range = try XCTUnwrap(invalidUTF8.range(of: Data("AQ==".utf8)))
        invalidUTF8[range.lowerBound] = 0xFF
        XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(invalidUTF8))
        XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(Data(repeating: 0, count: NativeJournalCodec.attemptLimit + 1)))
        let nested = text.replacingOccurrences(of: field, with: "\"unknown\":" + String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17))
        XCTAssertThrowsError(try NativeJournalCodec.attemptWitness(Data(nested.utf8)))
    }

    func testCurrentPrefixReconstructionKeepsOriginalTypedInputsAndHistoricalFence() throws {
        // Genuine bridge-owned stage plus unchanged current checkpoint. Legal
        // paired suffixes are exercised by the real fixed pair command; the old
        // ordinary stage checkpoint never becomes a new authority afterward.
        do {
            let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
            let checkpoint = try j.captureBoundStage(preparationID: f.preparation.preparationId)
            try j.verifyStageCheckpoint(checkpoint)
            let store = NativeEnrollmentPairedEvidenceStore(journal: j)
            _ = try store.continueExact(store.beginOriginal(preparationID: f.preparation.preparationId))
            XCTAssertThrowsError(try j.verifyStageCheckpoint(checkpoint))
            XCTAssertEqual(b.adds, 1)
        }
        // This phase1 checkpoint certifies journal metadata only. Replacing an
        // earlier intent in place with a different, independently valid proposal
        // leaves its frame/phase1 proof unchanged but MUST fail exact typed-prefix
        // comparison; it grants neither inventory nor stage-secret proof.
        for variant in 0..<2 {
            let f = try fixture(), j = f.journal(), p = f.preparation
            _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID())
            let stageID = UUID()
            _ = try j.appendPhaseAssertion(preparationID: p.preparationId, next: .stageAttempted, attemptID: stageID)
            let checkpoint = try j.captureStageAttempt(preparationID: p.preparationId, stageAttemptID: stageID)
            try j.verifyStageCheckpoint(checkpoint)
            let input = try NativeClaimInput(requestId: p.claimInput.requestId, transitionId: p.claimInput.transitionId,
                accountId: p.claimInput.accountId, locationId: p.claimInput.locationId,
                name: variant == 0 ? "Caf\u{e9} 0" : p.claimInput.name, profile: p.claimInput.profile)
            let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: p.binding.credentialGenerationID,
                transitionID: p.binding.transitionID, credentialReference: variant == 1 ? "native-altered" : p.binding.credentialReference, format: .nativeInstallationV1)
            let changed = try NativeEnrollmentPreparation.proposing(preparationId: p.preparationId, enrollmentId: p.enrollmentId,
                stageReference: p.stageReference, binding: binding, claimInput: input, history: p.sourceHistory,
                enrollment: p.sourceEnrollment, retained: [], inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
            let newIntent = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(changed)
            let directory = f.root.appendingPathComponent("attempts")
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }.first)
            let a = try NativeJournalCodec.attempt(Data(contentsOf: file))
            let replacement = NativeJournalAttempt(schemaVersion: a.schemaVersion, cloudRootID: a.cloudRootID,
                preparationID: a.preparationID, attemptID: a.attemptID, index: a.index, method: a.method,
                rootBindingIdentity: a.rootBindingIdentity, ownIdentity: a.ownIdentity, predecessor: a.predecessor,
                candidateIdentity: a.candidateIdentity, targetPayload: a.targetPayload, intentPayload: newIntent,
                reservation: try NativeJournalCodec.reservation(intentBytes: newIntent.count))
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: NativeJournalCodec.encode(replacement)); try handle.synchronize()
            XCTAssertThrowsError(try j.verifyStageCheckpoint(checkpoint))
        }
    }

    func testOrdinaryNonterminalAppendChecksCapturedProofAtEveryPublicationBoundary() throws {
        let points: [(NativeEnrollmentJournalStore.Kind, NativeEnrollmentJournalStore.Point)] = [
            (.candidate, .created), (.attempt, .written), (.attempt, .directorySynced),
            (.candidate, .written), (.candidate, .published), (.candidate, .directorySynced)]
        for (kind, point) in points {
            let f = try fixture(); var armed = false, mutated = false
            let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
                guard armed, !mutated, boundary == .init(kind: kind, point: point) else { return }
                mutated = true
                let dir = f.root.appendingPathComponent("attempts")
                let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasSuffix(".pending") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first)
                let bytes = try Data(contentsOf: original)
                // Independently valid same bytes, different inode: cannot renew the captured proof.
                try FileManager.default.moveItem(at: original, to: f.parent.appendingPathComponent("retained-proof"))
                try bytes.write(to: original)
            }
            _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID()); armed = true
            XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()))
            XCTAssertTrue(mutated)
            XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID()))
            XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("local-keep".utf8))
        }
    }
    func testOrdinaryAppendRetainsPairedNamespaceChecksAndNeverAcknowledgesCallbackFailure() throws {
        for replacement in [false, true] {
            let f = try fixture(), b = Backend(); var armed = false, injected = false
            let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
                guard armed, !injected, boundary == .init(kind: .candidate, point: .directorySynced) else { return }
                injected = true
                if replacement {
                    let url = f.root.appendingPathComponent("evidence/history.v3.json"), bytes = try Data(contentsOf: url)
                    try FileManager.default.moveItem(at: url, to: f.parent.appendingPathComponent("retained-history")); try bytes.write(to: url)
                } else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
            try start(f, j, b)
            let paired = NativeEnrollmentPairedEvidenceStore(journal: j)
            _ = try paired.continueExact(paired.beginOriginal(preparationID: f.preparation.preparationId))
            armed = true; let id = UUID()
            XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .promotionAttempted, attemptID: id))
            XCTAssertTrue(injected)
            // Failed scoped publication never leaves this instance's tip qualified.
            XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .promotionQualified, attemptID: UUID()))
            if !replacement {
                // A fully bound exact duplicate takes ordinary generic recommit, not refreshed scoped evidence.
                let receipt = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .promotionAttempted, attemptID: id)
                XCTAssertTrue(receipt.qualifiesCurrentJournalTip)
            }
            XCTAssertEqual(b.adds, 1)
        }
    }
    func testOrdinaryNonterminalDuplicateAndTerminalMetadataKeepGenericCompatibility() throws {
        let f = try fixture(), j = f.journal(); _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID())
        for phase in [NativeEnrollmentPreparation.Phase.stageAttempted, .stageQualified, .pairedEvidenceQualified, .promotionAttempted, .promotionQualified, .complete] {
            let id = UUID(), receipt = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: phase, attemptID: id)
            XCTAssertTrue(receipt.qualifiesCurrentJournalTip)
            let duplicate = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: phase, attemptID: id)
            XCTAssertTrue(duplicate.qualifiesCurrentJournalTip)
        }
        var observations = 0; try j.diagnose { _ in observations += 1 }
        XCTAssertEqual(observations, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("evidence").path))
    }

    func testOrdinaryScopeRejectsDifferentValidOwnSuffixAndUnknownPending() throws {
        for changedMethod in [false, true] {
            let f = try fixture(); var armed = false, injected = false
            let point: NativeEnrollmentJournalStore.Point = changedMethod ? .written : .created
            let kind: NativeEnrollmentJournalStore.Kind = changedMethod ? .attempt : .candidate
            let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
                guard armed, !injected, boundary == .init(kind: kind, point: point) else { return }
                injected = true
                if changedMethod {
                    let dir = f.root.appendingPathComponent("attempts")
                    let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix(".pending") })
                    let a = try NativeJournalCodec.attempt(Data(contentsOf: url)), frame = try NativeJournalCodec.frame(a.targetPayload)
                    let changedFrame = NativeJournalFrame(schemaVersion: frame.schemaVersion, cloudRootID: frame.cloudRootID,
                        preparationID: frame.preparationID, attemptID: frame.attemptID, intentAttemptID: frame.intentAttemptID,
                        index: frame.index, phase: 2, stageOwnership: nil, pairedEvidence: nil)
                    let changed = NativeJournalAttempt(schemaVersion: a.schemaVersion, cloudRootID: a.cloudRootID,
                        preparationID: a.preparationID, attemptID: a.attemptID, index: a.index, method: a.method,
                        rootBindingIdentity: a.rootBindingIdentity, ownIdentity: a.ownIdentity, predecessor: a.predecessor,
                        candidateIdentity: a.candidateIdentity, targetPayload: try NativeJournalCodec.encode(changedFrame), intentPayload: nil, reservation: 0)
                    let bytes = try NativeJournalCodec.encode(changed)
                    _ = try NativeJournalCodec.attempt(bytes) // Independently valid, but not this issued phase1 command.
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.synchronize()
                } else {
                    try Data().write(to: f.root.appendingPathComponent("frames/foreign.pending"))
                }
            }
            _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID()); armed = true
            XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()))
            XCTAssertTrue(injected)
        }
    }

    func testScopedFreshPreparationRequiresQualifiedInitializedEmptyRootAndBoundsBeforeEffects() throws {
        let f = try fixture(); var armed = false, effects = 0
        let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
            if armed, boundary.kind == .candidate { effects += 1 }
        }
        XCTAssertThrowsError(try j.prepareIntent(f.bytes, attemptID: UUID()))
        _ = try j.initializeExplicit(); armed = true
        XCTAssertThrowsError(try j.prepareIntent(Data(repeating: 0, count: NativeEnrollmentPreparationCodec.maximumBytes + 1), attemptID: UUID()))
        XCTAssertEqual(effects, 0)
        let id = UUID(), receipt = try j.prepareIntent(f.bytes, attemptID: id)
        XCTAssertTrue(receipt.qualifiesCurrentJournalTip)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path)
        XCTAssertEqual(files.count, 1)
        let duplicate = try j.prepareIntent(f.bytes, attemptID: id)
        XCTAssertTrue(duplicate.qualifiesCurrentJournalTip)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path), files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("evidence").path))
    }
    func testScopedPreparationRejectsDifferentValidIssuedInputAtSameInode() throws {
        let f = try fixture(), p = f.preparation; var armed = false, injected = false
        let input = try NativeClaimInput(requestId: p.claimInput.requestId, transitionId: p.claimInput.transitionId,
            accountId: p.claimInput.accountId, locationId: p.claimInput.locationId, name: "Caf\u{e9} 0", profile: p.claimInput.profile)
        let changed = try NativeEnrollmentPreparation.proposing(preparationId: p.preparationId, enrollmentId: p.enrollmentId,
            stageReference: p.stageReference, binding: p.binding, claimInput: input, history: p.sourceHistory,
            enrollment: p.sourceEnrollment, retained: [], inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
        let changedInput = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(changed)
        let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
            guard armed, !injected, boundary == .init(kind: .attempt, point: .written) else { return }; injected = true
            let dir = f.root.appendingPathComponent("attempts")
            let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix(".pending") })
            let a = try NativeJournalCodec.attempt(Data(contentsOf: url))
            let changedMethod = NativeJournalAttempt(schemaVersion: a.schemaVersion, cloudRootID: a.cloudRootID,
                preparationID: a.preparationID, attemptID: a.attemptID, index: a.index, method: a.method,
                rootBindingIdentity: a.rootBindingIdentity, ownIdentity: a.ownIdentity, predecessor: a.predecessor,
                candidateIdentity: a.candidateIdentity, targetPayload: a.targetPayload, intentPayload: changedInput,
                reservation: try NativeJournalCodec.reservation(intentBytes: changedInput.count))
            let bytes = try NativeJournalCodec.encode(changedMethod); _ = try NativeJournalCodec.attempt(bytes)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.synchronize()
        }
        _ = try j.initializeExplicit(); armed = true
        XCTAssertThrowsError(try j.prepareIntent(f.bytes, attemptID: UUID())); XCTAssertTrue(injected)
        XCTAssertThrowsError(try j.captureStageAttempt(preparationID: p.preparationId, stageAttemptID: UUID()))
    }
    func testScopedTerminalContinuationPreservesExactPriorClaimsAndNextSource() throws {
        let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
        let paired = NativeEnrollmentPairedEvidenceStore(journal: j)
        _ = try paired.continueExact(paired.beginOriginal(preparationID: f.preparation.preparationId))
        let old = try completedModel(f.preparation, retained: [], backend: b)
        for phase in [NativeEnrollmentPreparation.Phase.promotionAttempted, .promotionQualified, .complete] {
            XCTAssertTrue(try j.appendPhaseAssertion(preparationID: old.preparationId, next: phase, attemptID: UUID()).qualifiesCurrentJournalTip)
        }
        let previous = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(f.bytes, phase: 6))
        let p = try next(old, retained: [old], index: 1), bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p, retained: [previous])
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path)
        for changeName in [false, true] {
            _ = try j.recommitExactLatestTip(expectedAttemptID: latest(f.root))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var enrollment = try XCTUnwrap(object["sourceEnrollment"] as? [String: Any])
            var records = try XCTUnwrap(enrollment["enrollments"] as? [[String: Any]])
            if changeName {
                var first = try XCTUnwrap(records.first), input = try XCTUnwrap(first["claimInput"] as? [String: Any])
                input["name"] = "Caf\u{e9} 0"; first["claimInput"] = input; records[0] = first
            } else { records = [] }
            enrollment["enrollments"] = records; object["sourceEnrollment"] = enrollment
            let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertThrowsError(try j.prepareIntent(invalid, attemptID: UUID()))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path), before)
        }
        // Read-only rejection does not invent a new continuation or consume capacity.
        _ = try j.recommitExactLatestTip(expectedAttemptID: latest(f.root))
        let receipt = try j.prepareIntent(bytes, attemptID: UUID()); XCTAssertTrue(receipt.qualifiesCurrentJournalTip)
        try assertPair(old, root: f.root, target: true)
    }
    func testScopedTerminalCannotAdoptWrongValidPhaseOrQualifyAfterCallbackThrow() throws {
        for changePhase in [false, true] {
            let f = try fixture(); var armed = false, injected = false
            let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
                guard armed, !injected, boundary == .init(kind: .attempt, point: .written) else { return }; injected = true
                if !changePhase { throw NativeEnrollmentJournalError.outcomeUncertain }
                let dir = f.root.appendingPathComponent("attempts")
                let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix(".pending") })
                let a = try NativeJournalCodec.attempt(Data(contentsOf: url)), f = try NativeJournalCodec.frame(a.targetPayload)
                let wrong = NativeJournalFrame(schemaVersion: f.schemaVersion, cloudRootID: f.cloudRootID,
                    preparationID: f.preparationID, attemptID: f.attemptID, intentAttemptID: f.intentAttemptID,
                    index: f.index, phase: 5, stageOwnership: nil, pairedEvidence: nil)
                let method = NativeJournalAttempt(schemaVersion: a.schemaVersion, cloudRootID: a.cloudRootID,
                    preparationID: a.preparationID, attemptID: a.attemptID, index: a.index, method: a.method,
                    rootBindingIdentity: a.rootBindingIdentity, ownIdentity: a.ownIdentity, predecessor: a.predecessor,
                    candidateIdentity: a.candidateIdentity, targetPayload: try NativeJournalCodec.encode(wrong), intentPayload: nil, reservation: 0)
                let bytes = try NativeJournalCodec.encode(method); _ = try NativeJournalCodec.attempt(bytes)
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.synchronize()
            }
            _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID())
            for phase in [NativeEnrollmentPreparation.Phase.stageAttempted, .stageQualified, .pairedEvidenceQualified, .promotionAttempted, .promotionQualified] {
                _ = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: phase, attemptID: UUID())
            }
            armed = true
            XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .complete, attemptID: UUID()))
            XCTAssertTrue(injected)
            // Neither failed phase6 publication nor its cached typed proposal can prepare another operation.
            XCTAssertThrowsError(try j.prepareIntent(f.bytes, attemptID: UUID()))
        }
    }

    func testScopedEmptyPreparationAnchorRejectsRootBindingReplacementAndForeignCandidate() throws {
        for replaceBinding in [false, true] {
            let f = try fixture(); var armed = false, injected = false
            let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
                guard armed, !injected, boundary == .init(kind: .candidate, point: .created) else { return }; injected = true
                if replaceBinding {
                    let url = f.root.appendingPathComponent("root-binding.json"), data = try Data(contentsOf: url)
                    try FileManager.default.moveItem(at: url, to: f.parent.appendingPathComponent("original-binding")); try data.write(to: url)
                } else { try Data().write(to: f.root.appendingPathComponent("frames/unknown.pending")) }
            }
            _ = try j.initializeExplicit(); armed = true
            XCTAssertThrowsError(try j.prepareIntent(f.bytes, attemptID: UUID())); XCTAssertTrue(injected)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("evidence").path))
        }
    }

    private final class PromotionBackend: NativeEnrollmentStageBackend, NativeEnrollmentPromotionBackend {
        var items: [NativeEnrollmentRawCredentialItem] = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("legacy".utf8), persistentReference: Data("legacy-ref".utf8), payload: Data(repeating: 7, count: 32))]
        var finalAdds = 0
        var onAdd: (() throws -> Void)?
        func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem] { Array(items.prefix(limit)) }
        func generate48() throws -> Data { Data(repeating: 42, count: 48) }
        func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult {
            let ref = Data("original-stage-ref".utf8)
            items.append(.init(service: Data(NativeEnrollmentStageEnvelope.service.utf8), account: account, persistentReference: ref, payload: payload))
            return .added(ref)
        }
        func readPersistentReference(_ ref: Data) throws -> NativeEnrollmentRawCredentialItem? { items.first { $0.persistentReference == ref } }
        func addFinalOnce(account: Data, raw48: Data) throws -> NativeEnrollmentPromotionAddResult {
            finalAdds += 1; try onAdd?()
            let ref = Data("original-final-ref".utf8)
            items.append(.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: account, persistentReference: ref, payload: raw48))
            return .added(ref)
        }
    }
    func testExplicitPromotionUsesGenuinePairAndDurablePhaseFourBeforeAdd() async throws {
        let f = try fixture(), j = f.journal(), b = PromotionBackend()
        _ = try j.initializeExplicit(); _ = try j.preparePromotionIntent(f.bytes, attemptID: UUID())
        _ = try NativeEnrollmentStageBridge(journal: j, backend: b).stageOriginalExact(preparationID: f.preparation.preparationId,
            stageAttemptID: UUID(), ownershipAttemptID: UUID(), currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment)
        let pair = NativeEnrollmentPairedEvidenceStore(journal: j)
        _ = try pair.continueExact(pair.beginOriginal(preparationID: f.preparation.preparationId))
        let bridge = NativeEnrollmentPromotionBridge(journal: j, backend: b)
        let attempt = try bridge.beginOriginal(preparationID: f.preparation.preparationId, promotionAttemptID: UUID(), ownershipAttemptID: UUID(),
            currentHistory: f.preparation.targetHistory, currentEnrollment: f.preparation.targetEnrollment)
        let http = PromotionHTTPFixture(input: f.preparation.claimInput); addTeardownBlock { http.close() }
        try await http.prepare(bridge, attempt)
        b.onAdd = {
            let names = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).sorted()
            let method = try NativeJournalCodec.attempt(Data(contentsOf: f.root.appendingPathComponent("attempts").appendingPathComponent(XCTUnwrap(names.last))))
            let frame = try NativeJournalCodec.frame(method.targetPayload)
            XCTAssertEqual(method.schemaVersion, 3); XCTAssertEqual(frame.schemaVersion, 4)
            XCTAssertEqual(frame.phase, 4); XCTAssertEqual(frame.promotionProtocolVersion, 1)
            XCTAssertEqual(frame.activationProposal?.activationInput.requestId, http.activationRequestID)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("frames").appendingPathComponent(XCTUnwrap(names.last))), method.targetPayload)
        }
        _ = try bridge.continueExact(attempt); _ = try bridge.continueExact(attempt)
        XCTAssertEqual(b.finalAdds, 1)
        XCTAssertEqual(b.items.last?.keychainPayload(), Data(repeating: 42, count: 48))
        let lastID = try latest(f.root)
        var phase: Int?
        try j.diagnose { if $0.attemptID == lastID { phase = $0.step.proposal.phase.rawValue } }
        XCTAssertEqual(phase, 5)
        XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("local-keep".utf8))
    }
    func testOldPreparationCannotBeAutomaticallyPromoted() throws {
        let f = try fixture(), j = f.journal(), b = Backend(); try start(f, j, b)
        let pair = NativeEnrollmentPairedEvidenceStore(journal: j)
        _ = try pair.continueExact(pair.beginOriginal(preparationID: f.preparation.preparationId))
        XCTAssertThrowsError(try j.capturePromotionOriginal(preparationID: f.preparation.preparationId, promotionAttemptID: UUID(), ownershipAttemptID: UUID(),
            currentHistory: f.preparation.targetHistory, currentEnrollment: f.preparation.targetEnrollment))
    }

    private func promotionMarker(_ stage: String) {
        fputs("PROMOTION_LOCALIZATION " + stage + "\n", stderr)
        fflush(stderr)
    }
    private func preparePromotion(_ f: Fixture, journal j: NativeEnrollmentJournalStore, backend b: PromotionBackend, prepareProposal: Bool = true) async throws -> (NativeEnrollmentPromotionBridge, NativeEnrollmentPromotionBridge.Attempt, PromotionHTTPFixture) {
        promotionMarker("prepare.init.before")
        _ = try j.initializeExplicit(); promotionMarker("prepare.init.after")
        _ = try j.preparePromotionIntent(f.bytes, attemptID: UUID()); promotionMarker("prepare.intent.after")
        _ = try NativeEnrollmentStageBridge(journal: j, backend: b).stageOriginalExact(preparationID: f.preparation.preparationId,
            stageAttemptID: UUID(), ownershipAttemptID: UUID(), currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment)
        promotionMarker("prepare.stage.after")
        let pair = NativeEnrollmentPairedEvidenceStore(journal: j)
        _ = try pair.continueExact(pair.beginOriginal(preparationID: f.preparation.preparationId))
        promotionMarker("prepare.pair.after")
        let bridge = NativeEnrollmentPromotionBridge(journal: j, backend: b)
        let original = try bridge.beginOriginal(preparationID: f.preparation.preparationId, promotionAttemptID: UUID(), ownershipAttemptID: UUID(),
            currentHistory: f.preparation.targetHistory, currentEnrollment: f.preparation.targetEnrollment)
        promotionMarker("prepare.capture.after")
        let http = PromotionHTTPFixture(input: f.preparation.claimInput); addTeardownBlock { http.close() }
        if prepareProposal { promotionMarker("prepare.claim.before"); try await http.prepare(bridge, original); promotionMarker("prepare.claim.after") }
        return (bridge, original, http)
    }
    func testPromotionFinalAcknowledgmentLossRecommitsWithoutSecondAdd() async throws {
        let f = try fixture(), b = PromotionBackend()
        var fired = false
        let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
            if b.finalAdds == 1, !fired, boundary == .init(kind: .candidate, point: .directorySynced) {
                fired = true; throw NativeEnrollmentJournalError.io(EIO)
            }
        }
        let (bridge, original, _) = try await preparePromotion(f, journal: j, backend: b)
        XCTAssertThrowsError(try bridge.continueExact(original))
        XCTAssertTrue(fired); XCTAssertEqual(b.finalAdds, 1)
        _ = try bridge.continueExact(original)
        XCTAssertEqual(b.finalAdds, 1)
    }
    func testPromotionAmbiguousAddNeverRepeatsAndReentryDoesNotDeadlock() async throws {
        let f = try fixture(), j = f.journal(), b = PromotionBackend()
        promotionMarker("ambiguous.prepare.before")
        let (bridge, original, _) = try await preparePromotion(f, journal: j, backend: b)
        promotionMarker("ambiguous.prepare.after")
        b.onAdd = {
            self.promotionMarker("ambiguous.add.enter")
            self.promotionMarker("ambiguous.continue.before")
            XCTAssertThrowsError(try bridge.continueExact(original))
            self.promotionMarker("ambiguous.continue.after")
            self.promotionMarker("ambiguous.reentry.return")
            throw NativeEnrollmentPromotionError.outcomeUncertain
        }
        promotionMarker("ambiguous.continue.before")
        XCTAssertThrowsError(try bridge.continueExact(original))
        promotionMarker("ambiguous.continue.after")
        promotionMarker("ambiguous.continue.before")
        XCTAssertThrowsError(try bridge.continueExact(original))
        promotionMarker("ambiguous.continue.after")
        XCTAssertEqual(b.finalAdds, 1)
    }

    func testOrdinarySuccessorDoesNotInheritCompletedPromotionCapability() async throws {
        let f = try fixture(), j = f.journal(), b = PromotionBackend()
        promotionMarker("successor.prepare.before")
        let (bridge, original, http) = try await preparePromotion(f, journal: j, backend: b)
        promotionMarker("successor.prepare.after")
        _ = try bridge.continueExact(original); promotionMarker("successor.promote.after")
        XCTAssertThrowsError(try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .complete, attemptID: UUID()))
        promotionMarker("successor.activate.before")
        _ = try await http.activate(bridge, original); promotionMarker("successor.activate.after")
        let modelBackend = Backend(); modelBackend.items = b.items
        promotionMarker("successor.model.before")
        let completed = try completedModel(f.preparation, retained: [], backend: modelBackend)
        promotionMarker("successor.model.after")
        let prior = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(f.bytes, phase: 6))
        promotionMarker("successor.prior.after")
        let successor = try next(completed, retained: [completed], index: 1)
        promotionMarker("successor.next.after")
        let bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(successor, retained: [prior]), id = UUID()
        promotionMarker("successor.write.before")
        _ = try j.prepareIntent(bytes, attemptID: id)
        promotionMarker("successor.write.after")
        promotionMarker("successor.write.before")
        _ = try j.prepareIntent(bytes, attemptID: id)
        promotionMarker("successor.write.after")
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).sorted()
        let method = try NativeJournalCodec.attempt(Data(contentsOf: f.root.appendingPathComponent("attempts").appendingPathComponent(XCTUnwrap(names.last))))
        let frame = try NativeJournalCodec.frame(method.targetPayload)
        XCTAssertEqual(frame.phase, 0); XCTAssertNil(frame.promotionProtocolVersion)
        XCTAssertEqual(frame.schemaVersion, 3) // Paired workspace exists; promotion remains explicit.
        XCTAssertEqual(method.schemaVersion, 2)
    }

    func testActivationAssociationLostAcknowledgmentRepairsWithoutSecondHTTP() async throws {
        let f = try fixture(), b = PromotionBackend()
        var armed = false, fired = false
        let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
            if armed, !fired, boundary == .init(kind: .candidate, point: .directorySynced) {
                fired = true; throw NativeEnrollmentJournalError.io(EIO)
            }
        }
        let (bridge, original, http) = try await preparePromotion(f, journal: j, backend: b)
        _ = try bridge.continueExact(original); armed = true
        do { _ = try await http.activate(bridge, original); XCTFail("Expected completion acknowledgment loss") } catch { XCTAssertTrue(fired) }
        XCTAssertEqual(http.activations, 1)
        _ = try await http.activate(bridge, original)
        XCTAssertEqual(http.activations, 1); XCTAssertEqual(b.finalAdds, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).sorted()
        let method = try NativeJournalCodec.attempt(Data(contentsOf: f.root.appendingPathComponent("attempts").appendingPathComponent(XCTUnwrap(names.last))))
        let frame = try NativeJournalCodec.frame(method.targetPayload)
        XCTAssertEqual(method.method, .bindActivationAssociation); XCTAssertEqual(frame.phase, 6)
        XCTAssertEqual(frame.activationAssociation?.activation.requestId, http.activationRequestID)
        XCTAssertNotEqual(frame.activationAssociation?.activation.initialGeneration.generationId, f.preparation.binding.credentialGenerationID)
    }
    func testReplacedPromotionCandidateCannotPublishPendingMethod() async throws {
        let f = try fixture(), b = PromotionBackend()
        var armed = false, boundaries = 0
        let j = NativeEnrollmentJournalStore(root: f.root, cloudRootID: f.rootID, excludedLocalResetRoot: f.local) { boundary in
            boundaries += 1
            if armed, boundary == .init(kind: .attempt, point: .created) { armed = false; throw NativeEnrollmentJournalError.io(EIO) }
        }
        let (bridge, original, http) = try await preparePromotion(f, journal: j, backend: b, prepareProposal: false)
        armed = true
        do { try await http.prepare(bridge, original); XCTFail("Expected pending method fault") } catch { XCTAssertFalse(armed) }
        let checkpoint = original.checkpoint // Genuine original capture plus private fixed-HTTP observation.
        let methods = f.root.appendingPathComponent("attempts"), frames = f.root.appendingPathComponent("frames")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: methods.path).first { $0.hasSuffix(".pending") })
        let method = methods.appendingPathComponent(name), candidate = frames.appendingPathComponent(name)
        let bytes = try Data(contentsOf: method), inode = try FileManager.default.attributesOfItem(atPath: method.path)[.systemFileNumber] as? NSNumber
        try FileManager.default.moveItem(at: candidate, to: f.parent.appendingPathComponent("retained-original-candidate"))
        try Data().write(to: candidate, options: .withoutOverwriting)
        let before = boundaries
        XCTAssertThrowsError(try j.commitPromotionAttempt(checkpoint))
        XCTAssertEqual(try Data(contentsOf: method), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: method.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: methods.appendingPathComponent(String(name.dropLast(8))).path))
        XCTAssertEqual(boundaries, before); XCTAssertEqual(b.finalAdds, 0)
    }

}
