import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeEnrollmentJournalStoreTests: XCTestCase {
    private struct Fixture {
        let parent: URL, root: URL, local: URL, rootID: UUID
        let preparation: NativeEnrollmentPreparation, bytes: Data
        func store(boundary: @escaping (NativeEnrollmentJournalStore.Boundary) throws -> Void = { _ in }) -> NativeEnrollmentJournalStore {
            .init(root: root, cloudRootID: rootID, excludedLocalResetRoot: local, boundary: boundary)
        }
    }
    private func fixture() throws -> Fixture {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        let parent = temporary.appendingPathComponent("native-journal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let root = parent.appendingPathComponent("cloud", isDirectory: true), local = parent.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        try Data("keep local".utf8).write(to: local.appendingPathComponent("sentinel"))
        try Data("keep sibling".utf8).write(to: parent.appendingPathComponent("sibling"))
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let old = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "legacy", format: .legacyLocal32)
        let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: old.transitionID, phase: .locallyFenced)], credentials: [old])
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "native", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301}", profile: " iPad ")
        let preparation = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage", binding: binding, claimInput: input,
            history: history, enrollment: .init(), retained: [], inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
        return .init(parent: parent, root: root, local: local, rootID: UUID(), preparation: preparation,
            bytes: try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(preparation))
    }
    private func filename(_ index: Int, _ id: UUID) -> String { String(format: "%04d", index) + "-" + id.uuidString.lowercased() + ".json" }
    private func phases(_ store: NativeEnrollmentJournalStore, prep: UUID) throws -> [UUID] {
        var ids: [UUID] = []
        for value in 1...6 {
            let id = UUID(); ids.append(id)
            let receipt = try store.appendPhaseAssertion(preparationID: prep, next: try XCTUnwrap(.init(rawValue: value)), attemptID: id)
            XCTAssertTrue(receipt.qualifiesCurrentJournalTip)
        }
        return ids
    }
    func testIntentOrderedPhasesDiagnosticsAndNoExternalQualification() throws {
        let f = try fixture(), store = f.store(), attempt = UUID()
        XCTAssertTrue(try store.initializeExplicit().qualifiesCurrentJournalTip)
        XCTAssertTrue(try store.prepareIntent(f.bytes, attemptID: attempt).qualifiesCurrentJournalTip)
        var observations: [NativeEnrollmentJournalStore.Diagnostic] = []
        try store.diagnose { observations.append($0) }
        XCTAssertEqual(observations.count, 1); XCTAssertEqual(observations[0].step.proposal.phase, .intent)
        XCTAssertTrue(observations[0].step.proposal.claimInput.name.utf8.elementsEqual(f.preparation.claimInput.name.utf8))
        XCTAssertThrowsError(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID()))
        let ids = try phases(store, prep: f.preparation.preparationId)
        observations = []; try store.diagnose { observations.append($0) }
        XCTAssertEqual(observations[0].attemptID, ids.last); XCTAssertEqual(observations[0].step.proposal.phase, .complete)
        let result = NativeEnrollmentPreparation.assessingReconstruction(observations[0].step,
            currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment,
            inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
        XCTAssertEqual(result.recovery, .blocked)
        XCTAssertTrue(result.requiresJournalDurabilityQualification)
        XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("keep local".utf8))
        XCTAssertEqual(try Data(contentsOf: f.parent.appendingPathComponent("sibling")), Data("keep sibling".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path).count, 7)
    }
    func testNoEffectPhaseRejectionKeepsExactOriginalQualification() throws {
        let f = try fixture(), store = f.store()
        _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: UUID())
        let frames = f.root.appendingPathComponent("frames"), attempts = f.root.appendingPathComponent("attempts")
        let beforeFrames = try FileManager.default.contentsOfDirectory(atPath: frames.path).sorted()
        let beforeAttempts = try FileManager.default.contentsOfDirectory(atPath: attempts.path).sorted()
        XCTAssertThrowsError(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: frames.path).sorted(), beforeFrames)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attempts.path).sorted(), beforeAttempts)
        XCTAssertTrue(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()).qualifiesCurrentJournalTip)
    }
    func testEffectFailureStillRevokesPriorQualification() throws {
        let f = try fixture()
        var armed = false
        enum Injected: Error { case afterEffect }
        let store = f.store { boundary in
            if armed && boundary.kind == .candidate && boundary.point == .published { throw Injected.afterEffect }
        }
        _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: UUID())
        armed = true
        XCTAssertThrowsError(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()))
        armed = false
        XCTAssertThrowsError(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID()))
    }
    func testRestartAndSharedInstancesRequireExactLatestRecommit() throws {
        let f = try fixture(), first = f.store(), initial = UUID()
        _ = try first.initializeExplicit(); _ = try first.prepareIntent(f.bytes, attemptID: initial)
        let restarted = f.store()
        XCTAssertThrowsError(try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()))
        try restarted.diagnose { XCTAssertEqual($0.step.proposal.phase, .intent) }
        XCTAssertThrowsError(try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()))
        _ = try restarted.recommitExactLatestTip(expectedAttemptID: initial)
        let next = UUID(); _ = try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: next)
        XCTAssertThrowsError(try first.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID()))
        XCTAssertThrowsError(try first.recommitExactLatestTip(expectedAttemptID: initial))
        let old = try first.recommitExactAttempt(initial)
        XCTAssertFalse(old.qualifiesCurrentJournalTip)
        XCTAssertThrowsError(try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID()))
        _ = try first.recommitExactLatestTip(expectedAttemptID: next)
        _ = try first.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID())
    }
    func testExactDuplicatesAndConflictingMethodsNeverAcknowledgeReadback() throws {
        let f = try fixture(), store = f.store(), initial = UUID()
        _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: initial)
        XCTAssertTrue(try f.store().prepareIntent(f.bytes, attemptID: initial).qualifiesCurrentJournalTip)
        var changed = f.bytes; changed.append(32)
        XCTAssertThrowsError(try store.prepareIntent(changed, attemptID: initial))
        let restarted = f.store(); _ = try restarted.recommitExactLatestTip(expectedAttemptID: initial)
        let next = UUID(); _ = try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: next)
        XCTAssertTrue(try f.store().appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: next).qualifiesCurrentJournalTip)
        XCTAssertThrowsError(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: next))
        XCTAssertThrowsError(try store.prepareIntent(f.bytes, attemptID: next))
        XCTAssertThrowsError(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .intent, attemptID: initial))
    }
    func testPrepareFaultMatrixRestartRecoveryAndOrphanQuarantine() throws {
        typealias Store = NativeEnrollmentJournalStore
        let points: [Store.Point] = [.created, .written, .fileSynced, .beforePublish, .published, .directorySynced]
        for kind in [Store.Kind.attempt, .candidate] {
            for point in points {
                let f = try fixture(), id = UUID(), target = Store.Boundary(kind: kind, point: point)
                let broken = f.store { if $0 == target { throw NativeEnrollmentJournalError.io(EIO) } }
                _ = try broken.initializeExplicit()
                XCTAssertThrowsError(try broken.prepareIntent(f.bytes, attemptID: id))
                let restarted = f.store()
                let recoverable = kind == .attempt ? (point == .published || point == .directorySynced) : point != .created
                if recoverable {
                    var installed = false
                    try restarted.diagnose { installed = $0.candidateInstalled; XCTAssertEqual($0.attemptID, id) }
                    XCTAssertEqual(installed, kind == .candidate && (point == .published || point == .directorySynced))
                    XCTAssertThrowsError(try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()))
                    XCTAssertTrue(try restarted.recommitExactLatestTip(expectedAttemptID: id).qualifiesCurrentJournalTip)
                    _ = try restarted.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID())
                } else {
                    let before = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("frames").path)
                    XCTAssertThrowsError(try restarted.diagnose { _ in XCTFail("Unknown artifacts adopted") })
                    XCTAssertThrowsError(try restarted.recommitExactAttempt(id))
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("frames").path), before)
                }
            }
        }
    }
    func testPhaseFaultMatrixUsesPersistedExactMethodTargetAndCandidateInode() throws {
        typealias Store = NativeEnrollmentJournalStore
        for kind in [Store.Kind.attempt, .candidate] {
            for point in [Store.Point.created, .written, .fileSynced, .beforePublish, .published, .directorySynced] {
                let f = try fixture(), initial = UUID(), id = UUID(), target = Store.Boundary(kind: kind, point: point)
                let good = f.store(); _ = try good.initializeExplicit(); _ = try good.prepareIntent(f.bytes, attemptID: initial)
                var armed = false
                let broken = f.store { if armed && $0 == target { throw NativeEnrollmentJournalError.io(EIO) } }
                _ = try broken.recommitExactLatestTip(expectedAttemptID: initial)
                armed = true
                XCTAssertThrowsError(try broken.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: id))
                let recoverable = kind == .attempt ? (point == .published || point == .directorySynced) : point != .created
                let restarted = f.store()
                if recoverable {
                    XCTAssertTrue(try restarted.recommitExactLatestTip(expectedAttemptID: id).qualifiesCurrentJournalTip)
                    try restarted.diagnose { XCTAssertEqual($0.step.proposal.phase, .stageAttempted) }
                } else { XCTAssertThrowsError(try restarted.recommitExactLatestTip(expectedAttemptID: initial)) }
            }
        }
    }
    func testRootBindingInitialPublicationWindowsAndPersistentCloudIdentity() throws {
        typealias Store = NativeEnrollmentJournalStore
        for point in [Store.Point.created, .written, .fileSynced, .beforePublish, .published, .directorySynced] {
            let f = try fixture(), boundary = Store.Boundary(kind: .binding, point: point)
            let broken = f.store { if $0 == boundary { throw NativeEnrollmentJournalError.io(EIO) } }
            XCTAssertThrowsError(try broken.initializeExplicit())
            if point == .published || point == .directorySynced {
                XCTAssertTrue(try f.store().initializeExplicit().qualifiesCurrentJournalTip)
            } else { XCTAssertThrowsError(try f.store().initializeExplicit()) }
        }
        let f = try fixture(), store = f.store(); _ = try store.initializeExplicit()
        try FileManager.default.removeItem(at: f.local)
        try FileManager.default.createDirectory(at: f.local, withIntermediateDirectories: true)
        XCTAssertTrue(try f.store().recommitExactLatestTip(expectedAttemptID: nil).qualifiesCurrentJournalTip)
        let wrong = NativeEnrollmentJournalStore(root: f.root, cloudRootID: UUID(), excludedLocalResetRoot: f.local)
        XCTAssertThrowsError(try wrong.initializeExplicit())
        let overlapping = NativeEnrollmentJournalStore(root: f.local, cloudRootID: UUID(), excludedLocalResetRoot: f.local)
        XCTAssertThrowsError(try overlapping.initializeExplicit())
    }
    func testIndependentAttemptChainDetectsInstalledTipDeletionAndSameByteReplacement() throws {
        for replace in [false, true] {
            let f = try fixture(), store = f.store(), id = UUID()
            _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
            let path = f.root.appendingPathComponent("frames/" + filename(1, id)), bytes = try Data(contentsOf: path)
            // Retain original inode elsewhere so the replacement cannot reuse it.
            let saved = f.parent.appendingPathComponent("saved-frame")
            try FileManager.default.moveItem(at: path, to: saved)
            if replace { try bytes.write(to: path) }
            XCTAssertThrowsError(try f.store().diagnose { _ in })
            XCTAssertThrowsError(try f.store().recommitExactLatestTip(expectedAttemptID: id))
            XCTAssertEqual(try Data(contentsOf: saved), bytes)
        }
        let f = try fixture(), store = f.store(), id = UUID(); _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
        let saved = f.parent.appendingPathComponent("old-cloud"); try FileManager.default.moveItem(at: f.root, to: saved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        for name in ["root-binding.json", "journal.lock"] { try FileManager.default.copyItem(at: saved.appendingPathComponent(name), to: f.root.appendingPathComponent(name)) }
        for name in ["attempts", "frames"] { try FileManager.default.copyItem(at: saved.appendingPathComponent(name), to: f.root.appendingPathComponent(name)) }
        XCTAssertThrowsError(try f.store().diagnose { _ in })
        XCTAssertThrowsError(try f.store().initializeExplicit())
    }
    func testUnknownSelfConsistentCandidateMissingBoundInodeAndCapacityPreserveArtifacts() throws {
        let f = try fixture(), store = f.store(); _ = try store.initializeExplicit()
        let id = UUID(), name = filename(1, id)
        let fake = NativeJournalFrame(schemaVersion: 1, cloudRootID: f.rootID, preparationID: f.preparation.preparationId, attemptID: id, intentAttemptID: id, index: 1, phase: 0)
        let path = f.root.appendingPathComponent("frames/" + name + ".pending"), bytes = try NativeJournalCodec.encode(fake)
        try bytes.write(to: path)
        XCTAssertThrowsError(try f.store().recommitExactAttempt(id))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        let second = try fixture(), target = NativeEnrollmentJournalStore.Boundary(kind: .attempt, point: .published), attempt = UUID()
        let broken = second.store { if $0 == target { throw NativeEnrollmentJournalError.io(EIO) } }
        _ = try broken.initializeExplicit(); XCTAssertThrowsError(try broken.prepareIntent(second.bytes, attemptID: attempt))
        let candidate = second.root.appendingPathComponent("frames/" + filename(1, attempt) + ".pending")
        try FileManager.default.moveItem(at: candidate, to: second.parent.appendingPathComponent("saved-inode"))
        XCTAssertThrowsError(try second.store().recommitExactAttempt(attempt))
        let third = try fixture(), clean = third.store(); _ = try clean.initializeExplicit()
        let before = try FileManager.default.contentsOfDirectory(atPath: third.root.appendingPathComponent("attempts").path)
        XCTAssertThrowsError(try clean.prepareIntent(Data(repeating: 32, count: NativeJournalCodec.attemptLimit + 1), attemptID: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: third.root.appendingPathComponent("attempts").path), before)
        XCTAssertThrowsError(try NativeJournalCodec.reservation(intentBytes: NativeJournalCodec.attemptLimit))
        for n in 0...NativeJournalCodec.nameLimit { try Data().write(to: third.root.appendingPathComponent("frames/unknown-\(n)")) }
        XCTAssertThrowsError(try third.store().diagnose { _ in })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: third.root.appendingPathComponent("frames").path).count, NativeJournalCodec.nameLimit + 1)
    }
    func testStreamedSecondPreparationAndOldReplayCannotQualifyItsTip() throws {
        let f = try fixture(), store = f.store(), first = UUID()
        _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: first)
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path)
        XCTAssertThrowsError(try store.prepareIntent(f.bytes, attemptID: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("attempts").path), before)
        _ = try phases(store, prep: f.preparation.preparationId)
        var old = f.preparation
        let stage = NativeEnrollmentPreparation.StageDescriptor(preparationId: old.preparationId, enrollmentId: old.enrollmentId,
            stageReference: old.stageReference, binding: old.binding, claimInput: old.claimInput)
        for value in 1...6 {
            let phase = try XCTUnwrap(NativeEnrollmentPreparation.Phase(rawValue: value))
            old = try old.proposingObservation(phase, history: value >= 3 ? old.targetHistory : old.sourceHistory,
                enrollment: value >= 3 ? old.targetEnrollment : old.sourceEnrollment,
                inventory: .init(finalItems: value >= 5 ? ["legacy": .legacy32, "native": .native48] : ["legacy": .legacy32], stageItems: value >= 2 ? ["stage": .descriptor(stage)] : [:]), retained: [])
        }
        let history = try DeviceManagementFormatHistory(transitions: old.targetHistory.transitions.map { .init(transitionID: $0.transitionID, phase: .locallyFenced) }, credentials: old.targetHistory.credentials)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "next-native", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: old.claimInput.accountId,
            locationId: old.claimInput.locationId, name: "Next", profile: "iPhone")
        let next = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "next-stage", binding: binding,
            claimInput: input, history: history, enrollment: old.targetEnrollment, retained: [old],
            inventory: .init(finalItems: ["legacy": .legacy32, "native": .native48], stageItems: ["stage": .descriptor(stage)]))
        let previous = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeEnrollmentPreparationCodec.encodeReconstructionProposal(old))
        let bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(next, retained: [previous]), second = UUID()
        _ = try store.prepareIntent(bytes, attemptID: second)
        var ids: [UUID] = [], phases: [Int] = []
        try store.diagnose { ids.append($0.step.proposal.preparationId); phases.append($0.step.proposal.phase.rawValue) }
        XCTAssertEqual(ids, [old.preparationId, next.preparationId]); XCTAssertEqual(phases, [6, 0])
        var delivered = 0
        XCTAssertThrowsError(try store.diagnose { _ in
            delivered += 1
            XCTAssertTrue(try store.recommitExactAttempt(second).qualifiesCurrentJournalTip)
        }) { XCTAssertEqual($0 as? NativeEnrollmentJournalError, .outcomeUncertain) }
        XCTAssertEqual(delivered, 1) // No next delivery after the callback changed the epoch.
        let restart = f.store(); XCTAssertFalse(try restart.recommitExactAttempt(first).qualifiesCurrentJournalTip)
        XCTAssertThrowsError(try restart.appendPhaseAssertion(preparationID: next.preparationId, next: .stageAttempted, attemptID: UUID()))
        _ = try restart.recommitExactLatestTip(expectedAttemptID: second)
        _ = try restart.appendPhaseAssertion(preparationID: next.preparationId, next: .stageAttempted, attemptID: UUID())
    }
    func testAttemptProofAndBindingDeletionReplacementAndStrictWrappersBlock() throws {
        for component in ["attempts", "binding"] {
            let f = try fixture(), store = f.store(), id = UUID()
            _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
            let relative = component == "attempts" ? "attempts/" + filename(1, id) : "root-binding.json"
            let path = f.root.appendingPathComponent(relative), original = try Data(contentsOf: path)
            let saved = f.parent.appendingPathComponent("saved-" + component)
            try FileManager.default.moveItem(at: path, to: saved)
            XCTAssertThrowsError(try f.store().diagnose { _ in })
            try original.write(to: path)
            XCTAssertThrowsError(try f.store().recommitExactLatestTip(expectedAttemptID: id))
            XCTAssertEqual(try Data(contentsOf: saved), original)
        }
        let f = try fixture(), store = f.store(), id = UUID(); _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
        let attempt = try Data(contentsOf: f.root.appendingPathComponent("attempts/" + filename(1, id)))
        let text = String(decoding: attempt, as: UTF8.self)
        let duplicate = Data(("{\"schemaVersion\":1," + text.dropFirst()).utf8)
        XCTAssertThrowsError(try NativeJournalCodec.attempt(duplicate))
        XCTAssertThrowsError(try NativeJournalCodec.attempt(Data(text.replacingOccurrences(of: "prepareIntent", with: "unknownMethod").utf8)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: attempt) as? [String: Any]); object["unknown"] = 1
        XCTAssertThrowsError(try NativeJournalCodec.attempt(JSONSerialization.data(withJSONObject: object)))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: attempt) as? [String: Any]); object["reservation"] = 1
        XCTAssertThrowsError(try NativeJournalCodec.attempt(JSONSerialization.data(withJSONObject: object)))
    }
    func testBoundCandidateReplacementDuringPublishCannotBeAdopted() throws {
        let f = try fixture(), id = UUID(), staged = f.root.appendingPathComponent("frames/" + filename(1, id) + ".pending")
        let saved = f.parent.appendingPathComponent("captured-inode")
        let broken = f.store { event in
            if event == .init(kind: .candidate, point: .beforePublish) {
                let bytes = try Data(contentsOf: staged)
                try FileManager.default.moveItem(at: staged, to: saved)
                try bytes.write(to: staged)
            }
        }
        _ = try broken.initializeExplicit(); XCTAssertThrowsError(try broken.prepareIntent(f.bytes, attemptID: id))
        XCTAssertThrowsError(try f.store().recommitExactLatestTip(expectedAttemptID: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testDiagnosticReadOnlyReentryOutsideLocksPreservesLatestQualification() throws {
        let f = try fixture(), store = f.store(), id = UUID(), other = f.store()
        _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
        var nested = 0
        try store.diagnose { _ in
            try store.diagnose { _ in nested += 1 }
            try other.diagnose { _ in nested += 1 }
        }
        XCTAssertEqual(nested, 2)
        XCTAssertTrue(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()).qualifiesCurrentJournalTip)
    }
    func testDiagnosticCallbackMutationSucceedsButInvalidatesOuterStream() throws {
        for anotherInstance in [false, true] {
            let f = try fixture(), store = f.store(), id = UUID(), other = f.store()
            _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
            var delivered = 0
            XCTAssertThrowsError(try store.diagnose { _ in
                delivered += 1
                XCTAssertTrue(try (anotherInstance ? other : store).recommitExactAttempt(id).qualifiesCurrentJournalTip)
            }) { XCTAssertEqual($0 as? NativeEnrollmentJournalError, .outcomeUncertain) }
            XCTAssertEqual(delivered, 1)
        }
    }
    func testThrowingDiagnosticCallbackLeavesLocksReleasedAndQualificationIntact() throws {
        enum Failure: Error { case injected }
        let f = try fixture(), store = f.store(), id = UUID()
        _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
        XCTAssertThrowsError(try store.diagnose { _ in throw Failure.injected }) { XCTAssertTrue($0 is Failure) }
        try f.store().diagnose { _ in }
        XCTAssertTrue(try store.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID()).qualifiesCurrentJournalTip)
    }

    func testDiagnosticPhysicalWitnessRejectsFinalCallbackMutation() throws {
        for mutation in 0..<7 {
            let f = try fixture(), store = f.store(), id = UUID()
            _ = try store.initializeExplicit(); _ = try store.prepareIntent(f.bytes, attemptID: id)
            let candidate = f.root.appendingPathComponent("frames").appendingPathComponent(filename(1, id))
            var delivered = 0
            XCTAssertThrowsError(try store.diagnose { _ in
                delivered += 1
                let original = try Data(contentsOf: candidate)
                switch mutation {
                case 0: // Same inode and same size, different content.
                    let handle = try FileHandle(forWritingTo: candidate); defer { try? handle.close() }
                    var changed = original; changed[0] ^= 1; try handle.write(contentsOf: changed)
                case 1: // Append to the original inode.
                    let handle = try FileHandle(forWritingTo: candidate); defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: Data([0]))
                case 2: // Identical bytes, replacement inode.
                    try original.write(to: candidate, options: .atomic)
                case 3:
                    try FileManager.default.removeItem(at: candidate)
                    try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: f.local.appendingPathComponent("sentinel"))
                case 4:
                    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: candidate.path)
                case 5:
                    try Data([0]).write(to: f.root.appendingPathComponent("frames/unknown"))
                default:
                    let binding = f.root.appendingPathComponent("root-binding.json")
                    let handle = try FileHandle(forWritingTo: binding); defer { try? handle.close() }
                    try handle.write(contentsOf: Data([0]))
                }
            }) { XCTAssertEqual($0 as? NativeEnrollmentJournalError, .outcomeUncertain) }
            XCTAssertEqual(delivered, 1)
            XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("keep local".utf8))
        }
    }

}
