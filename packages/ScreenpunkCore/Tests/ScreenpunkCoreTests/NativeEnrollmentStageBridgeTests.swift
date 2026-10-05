import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeEnrollmentStageBridgeTests: XCTestCase {
    private final class Backend: NativeEnrollmentStageBackend {
        var items: [NativeEnrollmentRawCredentialItem] = []
        var generations = 0, adds = 0, reads = 0
        var afterAdd: (() throws -> Void)?, onRead: (() throws -> Void)?, onInventory: (() throws -> Void)?
        var duplicate = false, throwAfterAdd = false
        func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem] { try onInventory?(); return Array(items.prefix(limit)) }
        func generate48() throws -> Data { generations += 1; return Data(repeating: 0xAD, count: 48) }
        func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult {
            adds += 1
            if duplicate { return .duplicate }
            let ref = Data([0x11, 0x22, UInt8(adds)])
            items.append(.init(service: Data(NativeEnrollmentStageEnvelope.service.utf8), account: account, persistentReference: ref, payload: payload))
            try afterAdd?(); if throwAfterAdd { throw NativeEnrollmentStageError.outcomeUncertain }; return .added(ref)
        }
        func readPersistentReference(_ reference: Data) throws -> NativeEnrollmentRawCredentialItem? {
            reads += 1; try onRead?(); return items.first { $0.persistentReference == reference }
        }
    }
    private struct Fixture {
        let root: URL, local: URL, rootID: UUID, preparation: NativeEnrollmentPreparation, bytes: Data
        func journal(boundary: @escaping (NativeEnrollmentJournalStore.Boundary) throws -> Void = { _ in }) -> NativeEnrollmentJournalStore {
            .init(root: root, cloudRootID: rootID, excludedLocalResetRoot: local, boundary: boundary)
        }
    }
    private func fixture() throws -> Fixture {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        let base = URL(fileURLWithPath: String(cString: physical), isDirectory: true); free(physical)
        let parent = base.appendingPathComponent("native-stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("cloud", isDirectory: true), local = parent.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: local.appendingPathComponent("sentinel"))
        let old = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "legacy", format: .legacyLocal32)
        let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: old.transitionID, phase: .locallyFenced)], credentials: [old])
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "native", format: .nativeInstallationV1)
        let input = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301}", profile: " iPad ")
        let p = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stageK", binding: binding, claimInput: input,
            history: history, enrollment: .init(), retained: [], inventory: .init(finalItems: ["legacy": .legacy32], stageItems: [:]))
        return .init(root: root, local: local, rootID: UUID(), preparation: p, bytes: try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(p))
    }
    private func backend() -> Backend {
        let b = Backend(); b.items = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("legacy".utf8), persistentReference: Data([1]), payload: Data(repeating: 0xCD, count: 32))]; return b
    }
    private func start(_ f: Fixture, _ j: NativeEnrollmentJournalStore) throws { _ = try j.initializeExplicit(); _ = try j.prepareIntent(f.bytes, attemptID: UUID()) }
    private func stage(_ f: Fixture, _ bridge: NativeEnrollmentStageBridge, ids: (UUID, UUID)) throws -> NativeEnrollmentStageBridge.Result {
        try bridge.stageOriginalExact(preparationID: f.preparation.preparationId, stageAttemptID: ids.0, ownershipAttemptID: ids.1,
            currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment)
    }
    func testImmutableStageAndExactRetryRetainReferenceAndOnlyNonsecretJournal() throws {
        let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
        let bridge = NativeEnrollmentStageBridge(journal: j, backend: b), ids = (UUID(), UUID())
        let first = try stage(f, bridge, ids: ids), again = try stage(f, bridge, ids: ids)
        XCTAssertEqual(first.persistentReference, again.persistentReference); XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
        var phase: NativeEnrollmentPreparation.Phase?
        try j.diagnose { phase = $0.step.proposal.phase }; XCTAssertEqual(phase, .stageQualified)
        for folder in ["attempts", "frames"] {
            for file in try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent(folder), includingPropertiesForKeys: nil) {
                let data = try Data(contentsOf: file)
                XCTAssertFalse(data.range(of: Data(repeating: 0xAD, count: 48)) != nil)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Data(repeating: 0xAD, count: 48).base64EncodedString()))
            }
        }
        XCTAssertEqual(try Data(contentsOf: f.local.appendingPathComponent("sentinel")), Data("keep".utf8))
    }
    func testEnvelopeExactUTF8BindingAndRedaction() throws {
        let f = try fixture(), step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(f.bytes, context: .empty())
        let binding = try NativeEnrollmentStageBinding(cloudRootID: f.rootID, proposal: step.proposal), secret = Data(repeating: 0xAB, count: 48)
        let envelope = try NativeEnrollmentStageEnvelope.original(binding: binding, secret: secret)
        XCTAssertTrue(try NativeEnrollmentStageEnvelope.qualify(envelope.keychainPayload(), expected: binding).exactEnvelope(envelope))
        XCTAssertThrowsError(try NativeEnrollmentStageEnvelope.qualify(envelope.keychainPayload() + Data([0]), expected: binding))
        XCTAssertThrowsError(try NativeEnrollmentStageEnvelope.original(binding: binding, secret: Data(repeating: 0, count: 32)))
        let different = try NativeEnrollmentStageBinding(cloudRootID: UUID(), proposal: step.proposal)
        XCTAssertThrowsError(try NativeEnrollmentStageEnvelope.qualify(envelope.keychainPayload(), expected: different))
        var altered = envelope.keychainPayload(); altered[0] ^= 1
        XCTAssertThrowsError(try NativeEnrollmentStageEnvelope.qualify(altered, expected: binding))
        XCTAssertTrue(Mirror(reflecting: envelope).children.isEmpty); XCTAssertFalse(String(describing: envelope).contains(secret.base64EncodedString()))
        try NativeJournalCodec.stageOwnershipReservationProof(binding)
    }
    func testCompleteRawInventoryRejectsAliasesDuplicatesUnknownMissingAndOversizeBeforeAdd() throws {
        for variant in 0..<7 {
            let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
            switch variant {
            case 0: b.items = []
            case 1: b.items.append(b.items[0])
            case 2: b.items = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("legac\u{212A}".utf8), persistentReference: Data([1]), payload: Data(repeating: 0, count: 32))]
            case 3: b.items.append(.init(service: Data("unknown".utf8), account: Data("orphan".utf8), persistentReference: Data([2]), payload: Data()))
            case 4: b.items = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("legacy".utf8), persistentReference: Data([1]), payload: Data(repeating: 0, count: 48))]
            case 5: b.items = Array(repeating: b.items[0], count: 193)
            default: b.items = [.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8), account: Data("legacy".utf8), persistentReference: Data([1]), payload: Data(repeating: 0, count: 32), accessible: false)]
            }
            XCTAssertThrowsError(try stage(f, .init(journal: j, backend: b), ids: (UUID(), UUID())))
            XCTAssertEqual(b.generations, 0); XCTAssertEqual(b.adds, 0)
        }
    }
    func testDuplicateOrLostAddAcknowledgmentNeverRegeneratesOrAdoptsOrphan() throws {
        for duplicate in [true, false] {
            let f = try fixture(), j = f.journal(), b = backend(); try start(f, j); b.duplicate = duplicate; b.throwAfterAdd = !duplicate
            let bridge = NativeEnrollmentStageBridge(journal: j, backend: b), ids = (UUID(), UUID())
            XCTAssertThrowsError(try stage(f, bridge, ids: ids)); XCTAssertThrowsError(try stage(f, bridge, ids: ids))
            XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
            let restarted = f.journal(); _ = try restarted.recommitExactLatestTip(expectedAttemptID: ids.0)
            XCTAssertThrowsError(try stage(f, .init(journal: restarted, backend: b), ids: ids))
            XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
        }
    }
    func testBackendReadReentryOutsideJournalLocksAndMutationInvalidatesOriginal() throws {
        let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
        b.afterAdd = { try j.diagnose { _ in } }
        _ = try stage(f, .init(journal: j, backend: b), ids: (UUID(), UUID()))
        let g = try fixture(), other = g.journal(), backend = self.backend(); try start(g, other)
        let ids = (UUID(), UUID()); backend.afterAdd = { _ = try other.recommitExactLatestTip(expectedAttemptID: ids.0) }
        let bridge = NativeEnrollmentStageBridge(journal: other, backend: backend)
        XCTAssertThrowsError(try stage(g, bridge, ids: ids)); backend.afterAdd = nil
        XCTAssertThrowsError(try stage(g, bridge, ids: ids)); XCTAssertEqual(backend.adds, 1)
    }
    func testExactOriginalOwnershipWriteRecommitAfterLostPublishAcknowledgment() throws {
        let f = try fixture(), b = backend(); var fail = true
        let j = f.journal { point in
            if fail, b.adds == 1, point.kind == .candidate, point.point == .beforePublish { fail = false; throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        try start(f, j); let bridge = NativeEnrollmentStageBridge(journal: j, backend: b), ids = (UUID(), UUID())
        XCTAssertThrowsError(try stage(f, bridge, ids: ids))
        let recovered = try stage(f, bridge, ids: ids)
        XCTAssertEqual(recovered.journalAttemptID, ids.1); XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
    }
    func testBoundReferenceRestartRequiresExplicitLatestRecommitAndRealInventory() throws {
        let f = try fixture(), j = f.journal(), b = backend(); try start(f, j); let ids = (UUID(), UUID())
        let result = try stage(f, .init(journal: j, backend: b), ids: ids)
        let restarted = f.journal(), bridge = NativeEnrollmentStageBridge(journal: restarted, backend: b)
        XCTAssertThrowsError(try bridge.recoverBoundStage(preparationID: f.preparation.preparationId, currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment))
        _ = try restarted.recommitExactLatestTip(expectedAttemptID: ids.1)
        let read = try bridge.recoverBoundStage(preparationID: f.preparation.preparationId, currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment)
        XCTAssertEqual(read.persistentReference, result.persistentReference); XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
        b.items.removeLast()
        XCTAssertThrowsError(try bridge.recoverBoundStage(preparationID: f.preparation.preparationId, currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment))
        XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
    }
    func testReturnedReferenceReplacementAndScopeExitMutationFailClosed() throws {
        for variant in 0..<3 {
            let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
            let ids = (UUID(), UUID()), bridge = NativeEnrollmentStageBridge(journal: j, backend: b)
            if variant < 2 {
                b.afterAdd = {
                    let item = b.items.removeLast()
                    var payload = item.keychainPayload()
                    if variant == 0 { payload[payload.count - 1] ^= 1 }
                    b.items.append(.init(service: item.service, account: item.account,
                        persistentReference: variant == 1 ? Data([9]) : item.persistentReference, payload: payload))
                }
            } else {
                b.onRead = {
                    if b.reads == 2 { _ = try f.journal().recommitExactLatestTip(expectedAttemptID: ids.1) }
                }
            }
            XCTAssertThrowsError(try stage(f, bridge, ids: ids))
            b.afterAdd = nil; b.onRead = nil
            XCTAssertThrowsError(try stage(f, bridge, ids: ids))
            XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
        }
    }
    func testRetryMustRetainExactCurrentInputsAndDistinctOperationIDs() throws {
        let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
        let bridge = NativeEnrollmentStageBridge(journal: j, backend: b), ids = (UUID(), UUID())
        XCTAssertThrowsError(try stage(f, bridge, ids: (f.preparation.preparationId, UUID())))
        XCTAssertEqual(b.generations, 0); XCTAssertEqual(b.adds, 0)
        // Explicit local journal recommit is required after the rejected call.
        var latest: UUID?
        try j.diagnose { latest = $0.attemptID }
        _ = try j.recommitExactLatestTip(expectedAttemptID: try XCTUnwrap(latest))
        _ = try stage(f, bridge, ids: ids)
        XCTAssertThrowsError(try bridge.stageOriginalExact(preparationID: f.preparation.preparationId,
            stageAttemptID: ids.0, ownershipAttemptID: ids.1,
            currentHistory: f.preparation.targetHistory, currentEnrollment: f.preparation.sourceEnrollment))
        XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
    }
    // Historical fixture only: genuine bridge-recorded stage ownership, followed
    // by metadata assertions and a synthetic final item. This does not execute
    // or qualify production promotion or paired history/enrollment writes.
    private func nextAfterHistoricalNative(_ f: Fixture, _ j: NativeEnrollmentJournalStore, _ b: Backend) throws -> Fixture {
        _ = try stage(f, .init(journal: j, backend: b), ids: (UUID(), UUID()))
        let descriptor = NativeEnrollmentPreparation.StageDescriptor(preparationId: f.preparation.preparationId,
            enrollmentId: f.preparation.enrollmentId, stageReference: f.preparation.stageReference,
            binding: f.preparation.binding, claimInput: f.preparation.claimInput)
        let staged = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32],
            stageItems: [f.preparation.stageReference: .descriptor(descriptor)])
        var old = try f.preparation.proposingObservation(.stageAttempted, history: f.preparation.sourceHistory,
            enrollment: f.preparation.sourceEnrollment, inventory: staged, retained: [])
        old = try old.proposingObservation(.stageQualified, history: old.sourceHistory, enrollment: old.sourceEnrollment, inventory: staged, retained: [])
        let full = NativeEnrollmentPreparation.Inventory(finalItems: ["legacy": .legacy32, old.binding.credentialReference: .native48],
            stageItems: [old.stageReference: .descriptor(descriptor)])
        for phase in [NativeEnrollmentPreparation.Phase.pairedEvidenceQualified, .promotionAttempted, .promotionQualified, .complete] {
            old = try old.proposingObservation(phase, history: old.targetHistory, enrollment: old.targetEnrollment,
                inventory: phase == .pairedEvidenceQualified ? staged : full, retained: [])
            _ = try j.appendPhaseAssertion(preparationID: old.preparationId, next: phase, attemptID: UUID())
        }
        let stageItem = try XCTUnwrap(b.items.last)
        b.items.append(.init(service: Data(NativeEnrollmentStageEnvelope.finalService.utf8),
            account: Data(old.binding.credentialReference.utf8), persistentReference: Data([0x70]),
            payload: Data(stageItem.keychainPayload().suffix(48))))
        let history = try DeviceManagementFormatHistory(transitions: old.targetHistory.transitions.map {
            .init(transitionID: $0.transitionID, phase: .locallyFenced)
        }, credentials: old.targetHistory.credentials)
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: UUID(), credentialReference: "nextNative", format: .nativeInstallationV1)
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: binding.transitionID, accountId: UUID(), locationId: UUID(), name: "Next", profile: "iPad")
        let next = try NativeEnrollmentPreparation.proposing(preparationId: UUID(), enrollmentId: UUID(), stageReference: "nextStage",
            binding: binding, claimInput: claim, history: history, enrollment: old.targetEnrollment, retained: [old], inventory: full)
        let bytes = try NativeEnrollmentPreparationCodec.encodeReconstructionProposal(next,
            retained: [NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(f.bytes, phase: 6))])
        _ = try j.prepareIntent(bytes, attemptID: UUID())
        return .init(root: f.root, local: f.local, rootID: f.rootID, preparation: next, bytes: bytes)
    }
    func testCompletePriorNativeInventoryIsPreservedAndEveryMissingOrChangedItemBlocks() throws {
        for variant in 0..<6 {
            let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
            let next = try nextAfterHistoricalNative(f, j, b)
            let prior = b.items, generations = b.generations, adds = b.adds
            if variant != 0 {
                let index = variant <= 3 ? 1 : 2
                let item = b.items[index]
                if variant == 1 || variant == 4 { b.items.remove(at: index) }
                else {
                    var payload = item.keychainPayload()
                    if variant == 3 || variant == 5 { payload[payload.count - 1] ^= 1 }
                    b.items[index] = .init(service: item.service, account: item.account,
                        persistentReference: variant == 2 ? Data([0x71]) : item.persistentReference, payload: payload)
                }
            }
            let bridge = NativeEnrollmentStageBridge(journal: j, backend: b)
            if variant == 0 {
                _ = try stage(next, bridge, ids: (UUID(), UUID()))
                XCTAssertEqual(Array(b.items.prefix(prior.count)), prior)
                XCTAssertEqual(b.generations, generations + 1); XCTAssertEqual(b.adds, adds + 1)
            } else {
                XCTAssertThrowsError(try stage(next, bridge, ids: (UUID(), UUID())))
                XCTAssertEqual(b.generations, generations); XCTAssertEqual(b.adds, adds)
            }
        }
    }
    func testOwnershipWriteBoundaryMatrixPreservesExactAttemptOrBlocksPreRecordOrphan() throws {
        // Generic restart scanning still blocks every unpublished attempt. Only
        // the retained original can recommit fully written exact pending bytes;
        // empty/pre-record candidates remain preserved and blocked.
        let cases: [(NativeEnrollmentJournalStore.Kind, NativeEnrollmentJournalStore.Point, Bool)] = [
            (.candidate, .created, false), (.attempt, .created, false),
            (.attempt, .written, true), (.attempt, .fileSynced, true),
            (.attempt, .beforePublish, true), (.attempt, .published, true), (.attempt, .directorySynced, true),
            (.candidate, .written, true), (.candidate, .fileSynced, true),
            (.candidate, .beforePublish, true), (.candidate, .published, true), (.candidate, .directorySynced, true)]
        for (kind, point, recoverable) in cases {
            let f = try fixture(), b = backend(); var armed = true
            let j = f.journal { event in
                if armed, b.adds == 1, event.kind == kind, event.point == point {
                    armed = false; throw NativeEnrollmentJournalError.outcomeUncertain
                }
            }
            try start(f, j); let bridge = NativeEnrollmentStageBridge(journal: j, backend: b), ids = (UUID(), UUID())
            XCTAssertThrowsError(try stage(f, bridge, ids: ids))
            XCTAssertFalse(armed)
            if recoverable { XCTAssertEqual(try stage(f, bridge, ids: ids).journalAttemptID, ids.1, "boundary \(kind) \(point)") }
            else { XCTAssertThrowsError(try stage(f, bridge, ids: ids)) }
            XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
            // A fresh bridge never reconstructs the private original write attempt.
            XCTAssertThrowsError(try stage(f, .init(journal: f.journal(), backend: b), ids: ids))
            XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
        }
    }
    private func pendingOriginal() throws -> (Fixture, NativeEnrollmentJournalStore, Backend, NativeEnrollmentStageBridge, (UUID, UUID)) {
        let f = try fixture(), b = backend(); var armed = true
        let j = f.journal { event in
            if armed, b.adds == 1, event.kind == .attempt, event.point == .written {
                armed = false; throw NativeEnrollmentJournalError.outcomeUncertain
            }
        }
        try start(f, j)
        let bridge = NativeEnrollmentStageBridge(journal: j, backend: b), ids = (UUID(), UUID())
        XCTAssertThrowsError(try stage(f, bridge, ids: ids)); XCTAssertFalse(armed)
        return (f, j, b, bridge, ids)
    }
    private func pendingFile(_ root: URL, folder: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix(".pending") })
    }
    func testPendingOriginalRejectsPartialReplacementExtraNodesAndRetainedNodeReplacement() throws {
        for variant in 0..<10 {
            let (f, _, b, bridge, ids) = try pendingOriginal()
            let attempt = try pendingFile(f.root, folder: "attempts"), candidate = try pendingFile(f.root, folder: "frames")
            let original = try Data(contentsOf: attempt)
            switch variant {
            case 0: try original.dropLast().write(to: attempt)
            case 1: try original.write(to: attempt, options: .atomic)
            case 2: try Data().write(to: candidate, options: .atomic)
            case 3: try Data([1]).write(to: candidate)
            case 4: try Data().write(to: f.root.appendingPathComponent("attempts/unknown.pending"))
            case 5: try Data().write(to: f.root.appendingPathComponent("frames/unknown.pending"))
            case 6, 7:
                let folder = variant == 6 ? "attempts" : "frames"
                let prior = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }.first { !$0.lastPathComponent.hasSuffix(".pending") })
                try Data(contentsOf: prior).write(to: prior, options: .atomic)
            case 8:
                let binding = f.root.appendingPathComponent("root-binding.json")
                try Data(contentsOf: binding).write(to: binding, options: .atomic)
            default:
                let retained = f.root.deletingLastPathComponent().appendingPathComponent("retained-original-root")
                try FileManager.default.moveItem(at: f.root, to: retained)
                try FileManager.default.copyItem(at: retained, to: f.root)
            }
            let reads = b.reads
            XCTAssertThrowsError(try stage(f, bridge, ids: ids), "variant " + String(variant))
            XCTAssertEqual(b.reads, reads); XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attempt.path))
            // Neither a diagnostic nor a fresh issuer can exempt these names.
            XCTAssertThrowsError(try f.journal().diagnose { _ in })
            XCTAssertThrowsError(try stage(f, .init(journal: f.journal(), backend: b), ids: ids))
        }
    }
    func testPendingOriginalCannotRefreshForeignEpochAndBackendReentryRemainsOutsideLocks() throws {
        let (f, _, b, bridge, ids) = try pendingOriginal()
        _ = try f.journal().initializeExplicit()
        XCTAssertThrowsError(try stage(f, bridge, ids: ids))
        XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)

        let (g, j, backend, original, originalIDs) = try pendingOriginal()
        var callbacks = 0
        backend.onRead = {
            callbacks += 1
            // Generic diagnosis rejects the pending assertion while the original
            // is privately retryable; completion diagnosis succeeds after commit.
            if callbacks == 1 { XCTAssertThrowsError(try j.diagnose { _ in }) }
            else { try j.diagnose { _ in } }
        }
        XCTAssertEqual(try stage(g, original, ids: originalIDs).journalAttemptID, originalIDs.1)
        XCTAssertEqual(callbacks, 2); XCTAssertEqual(backend.generations, 1); XCTAssertEqual(backend.adds, 1)

        let (h, _, changed, captured, changedIDs) = try pendingOriginal()
        changed.onRead = { _ = try h.journal().initializeExplicit() }
        XCTAssertThrowsError(try stage(h, captured, ids: changedIDs))
        changed.onRead = nil
        XCTAssertThrowsError(try stage(h, captured, ids: changedIDs))
        XCTAssertEqual(changed.generations, 1); XCTAssertEqual(changed.adds, 1)
    }
    func testPendingOriginalScopeExitMutationInvalidatesAllInstances() throws {
        let (f, _, b, bridge, ids) = try pendingOriginal()
        let readsBeforeRetry = b.reads; var mutated = false
        b.onRead = {
            if b.reads == readsBeforeRetry + 2 {
                _ = try f.journal().recommitExactLatestTip(expectedAttemptID: ids.1); mutated = true
            }
        }
        XCTAssertThrowsError(try stage(f, bridge, ids: ids))
        XCTAssertTrue(mutated)
        b.onRead = nil
        XCTAssertThrowsError(try stage(f, bridge, ids: ids))
        let restarted = f.journal()
        XCTAssertThrowsError(try NativeEnrollmentStageBridge(journal: restarted, backend: b).recoverBoundStage(
            preparationID: f.preparation.preparationId, currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment))
        XCTAssertEqual(b.generations, 1); XCTAssertEqual(b.adds, 1)
    }
    func testMetadataOnlyStageQualifiedCannotManufacturePersistentReferenceOwnership() throws {
        let f = try fixture(), j = f.journal(), b = backend(); try start(f, j)
        _ = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageAttempted, attemptID: UUID())
        _ = try j.appendPhaseAssertion(preparationID: f.preparation.preparationId, next: .stageQualified, attemptID: UUID())
        XCTAssertThrowsError(try NativeEnrollmentStageBridge(journal: j, backend: b).recoverBoundStage(preparationID: f.preparation.preparationId,
            currentHistory: f.preparation.sourceHistory, currentEnrollment: f.preparation.sourceEnrollment))
        XCTAssertEqual(b.generations, 0); XCTAssertEqual(b.adds, 0)
    }
}
