import Foundation

/// Synthetic-backend contract only. No production Keychain adapter is mounted.
/// enumerateRaw must enforce limit before result allocation, include both service
/// namespaces, and retain all inaccessible/unknown items. No update/delete API.
protocol NativeEnrollmentStageBackend: AnyObject {
    func enumerateRaw(limit: Int) throws -> [NativeEnrollmentRawCredentialItem]
    func generate48() throws -> Data
    func addStageOnce(account: Data, payload: Data) throws -> NativeEnrollmentStageAddResult
    func readPersistentReference(_ reference: Data) throws -> NativeEnrollmentRawCredentialItem?
}
enum NativeEnrollmentStageAddResult { case added(Data), duplicate }

/// Fixed stage-only operation. Journal callbacks never execute backend effects.
/// No promotion, paired file writes, HTTP, remote authority or production caller.
final class NativeEnrollmentStageBridge {
    static let maximumFinalItems = 128, maximumStageItems = 64, maximumRawItems = 192
    private let journal: NativeEnrollmentJournalStore
    private let backend: any NativeEnrollmentStageBackend
    private let mutex = NSLock()
    private var driving = false
    private var attempted = false
    private var attempt: Attempt?
    init(journal: NativeEnrollmentJournalStore, backend: any NativeEnrollmentStageBackend) { self.journal = journal; self.backend = backend }

    /// A bridge-issued in-process original only; cannot be constructed from a
    /// descriptor, metadata receipt, diagnostic or restart inventory.
    final class Attempt: CustomReflectable, CustomStringConvertible {
        let checkpoint: NativeEnrollmentJournalStore.StageCheckpoint
        let envelope: NativeEnrollmentStageEnvelope
        let ownershipAttemptID: UUID
        private(set) var persistentReference: Data?
        fileprivate let baseline: [NativeEnrollmentRawCredentialItem]
        fileprivate init(checkpoint: NativeEnrollmentJournalStore.StageCheckpoint, envelope: NativeEnrollmentStageEnvelope,
            ownershipAttemptID: UUID, baseline: [NativeEnrollmentRawCredentialItem]) {
            self.checkpoint = checkpoint; self.envelope = envelope; self.ownershipAttemptID = ownershipAttemptID; self.baseline = baseline
        }
        fileprivate func capture(_ reference: Data) throws {
            guard persistentReference == nil, (1...1024).contains(reference.count) else { throw NativeEnrollmentStageError.conflict }
            persistentReference = reference
        }
        var description: String { "NativeEnrollmentStageAttempt(redacted)" }
        var customMirror: Mirror { Mirror(self, children: [] as [(label: String?, value: Any)]) }
        func ownership() throws -> NativeJournalStageOwnership {
            guard let reference = persistentReference else { throw NativeEnrollmentStageError.outcomeUncertain }
            return NativeJournalStageOwnership(envelope.binding, persistentReference: reference, stageAttemptID: checkpoint.stageAttemptID)
        }
    }
    /// Local immutable stage ownership only; does not qualify paired files or
    /// current installation authority. No secret is returned to a caller.
    struct Result { let preparationID: UUID; let persistentReference: Data; let journalAttemptID: UUID }
    private func reserveDriver() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !driving else { throw NativeEnrollmentStageError.outcomeUncertain }; driving = true
    }
    private func releaseDriver() { mutex.lock(); driving = false; mutex.unlock() }
    func stageFirstNativeOriginalExact(preparationID: UUID, stageAttemptID: UUID, ownershipAttemptID: UUID) throws -> Result {
        try reserveDriver(); defer { releaseDriver() }
        do { return try stageFixed(preparationID: preparationID, stageAttemptID: stageAttemptID, ownershipAttemptID: ownershipAttemptID,
            source: .firstNativeGenesis, currentEnrollment: .init()) }
        catch { journal.invalidateStageQualification(original: attempt); throw error }
    }
    func stageOriginalExact(preparationID: UUID, stageAttemptID: UUID, ownershipAttemptID: UUID,
        currentHistory: DeviceManagementFormatHistory, currentEnrollment: NativeEnrollmentEvidence) throws -> Result {
        try reserveDriver(); defer { releaseDriver() }
        do { return try stageFixed(preparationID: preparationID, stageAttemptID: stageAttemptID, ownershipAttemptID: ownershipAttemptID,
            source: .existingHistory(currentHistory), currentEnrollment: currentEnrollment) }
        catch { journal.invalidateStageQualification(original: attempt); throw error }
    }
    private func stageFixed(preparationID: UUID, stageAttemptID: UUID, ownershipAttemptID: UUID,
        source: NativeEnrollmentPreparationSource, currentEnrollment: NativeEnrollmentEvidence) throws -> Result {
        if let attempt {
            guard attempt.envelope.binding.preparationID == preparationID,
                attempt.checkpoint.stageAttemptID == stageAttemptID, attempt.ownershipAttemptID == ownershipAttemptID,
                try nativeEnrollmentBytes(source) == nativeEnrollmentBytes(attempt.checkpoint.step.proposal.source),
                try nativeEnrollmentBytes(currentEnrollment) == nativeEnrollmentBytes(attempt.checkpoint.step.proposal.sourceEnrollment) else { throw NativeEnrollmentStageError.conflict }
            return try finishOriginal(attempt)
        }
        // No replay may generate after a failed/ambiguous original call.
        guard !attempted else { throw NativeEnrollmentStageError.outcomeUncertain }
        let original = try journal.captureStageIntent(preparationID: preparationID)
        let p = original.step.proposal
        let reserved = [p.preparationId, p.enrollmentId, p.binding.credentialGenerationID, p.binding.transitionID, p.claimInput.requestId]
            + p.source.transitions.map(\.transitionID)
            + p.source.credentials.flatMap { [$0.credentialGenerationID, $0.transitionID] }
            + p.sourceEnrollment.enrollments.flatMap { [$0.localEnrollmentId, $0.binding.credentialGenerationID, $0.binding.transitionID, $0.claimInput.requestId] }
            + original.step.priorDeclarations.flatMap { [$0.preparationId, $0.enrollmentId, $0.binding.credentialGenerationID, $0.binding.transitionID, $0.claimInput.requestId] }
        guard stageAttemptID != ownershipAttemptID, !reserved.contains(stageAttemptID), !reserved.contains(ownershipAttemptID) else { throw NativeEnrollmentStageError.conflict }
        guard try nativeEnrollmentBytes(source) == nativeEnrollmentBytes(p.source),
            try nativeEnrollmentBytes(currentEnrollment) == nativeEnrollmentBytes(p.sourceEnrollment) else { throw NativeEnrollmentStageError.conflict }
        let baseline = try rawInventory(original, current: nil)
        if source.isFirstNative { guard baseline.isEmpty, p.source.isFirstNative else { throw NativeEnrollmentStageError.inventoryBlocked } }
        try journal.verifyStageCheckpoint(original)
        // Reserve IDs and durable original stage intent BEFORE key generation/add.
        attempted = true
        _ = try journal.appendPhaseAssertion(preparationID: preparationID, next: .stageAttempted, attemptID: stageAttemptID)
        let captured = try journal.captureStageAttempt(preparationID: preparationID, stageAttemptID: stageAttemptID)
        let binding = try NativeEnrollmentStageBinding(cloudRootID: journal.cloudRootID, proposal: captured.step.proposal)
        let secret = try backend.generate48()
        try journal.verifyStageCheckpoint(captured)
        let envelope = try NativeEnrollmentStageEnvelope.original(binding: binding, secret: secret)
        let attempt = Attempt(checkpoint: captured, envelope: envelope, ownershipAttemptID: ownershipAttemptID, baseline: baseline)
        self.attempt = attempt
        // Fixed backend dispatch is OUTSIDE journal mutex/flock. Any callback
        // changing journal epoch/root/tip invalidates original qualification.
        try journal.verifyStageCheckpoint(captured)
        guard sameRawItems(baseline, try rawInventory(captured, current: nil)) else { throw NativeEnrollmentStageError.inventoryBlocked }
        try journal.verifyStageCheckpoint(captured)
        let result = try backend.addStageOnce(account: binding.stage, payload: envelope.keychainPayload())
        switch result { case .duplicate: throw NativeEnrollmentStageError.outcomeUncertain; case .added(let ref): try attempt.capture(ref) }
        return try finishOriginal(attempt)
    }
    /// Explicit restart read recovery requires real latest-tip recommit FIRST.
    /// Bound reference ownership only; never rebuilds an in-process write attempt.
    func recoverBoundStage(preparationID: UUID, currentHistory: DeviceManagementFormatHistory, currentEnrollment: NativeEnrollmentEvidence) throws -> Result {
        try reserveDriver(); defer { releaseDriver() }
        do {
            let c = try journal.captureBoundStage(preparationID: preparationID), p = c.step.proposal
            guard try nativeEnrollmentBytes(currentHistory) == nativeEnrollmentBytes(p.source),
                try nativeEnrollmentBytes(currentEnrollment) == nativeEnrollmentBytes(p.sourceEnrollment) else { throw NativeEnrollmentStageError.conflict }
            let binding = try NativeEnrollmentStageBinding(cloudRootID: journal.cloudRootID, proposal: p)
            let owners = c.retainedOwnerships.filter { $0.matches(binding) }
            guard owners.count == 1, let owner = owners.first else { throw NativeEnrollmentStageError.outcomeUncertain }
            let before = try rawInventory(c, current: nil)
            guard let item = try backend.readPersistentReference(owner.persistentReference), before.contains(item),
                item.service == Data(NativeEnrollmentStageEnvelope.service.utf8), item.account == binding.stage,
                item.persistentReference == owner.persistentReference, item.accessible else { throw NativeEnrollmentStageError.outcomeUncertain }
            _ = try NativeEnrollmentStageEnvelope.qualify(item.keychainPayload(), expected: binding)
            try journal.verifyStageCheckpoint(c)
            guard sameRawItems(before, try rawInventory(c, current: nil)) else { throw NativeEnrollmentStageError.inventoryBlocked }
            try journal.verifyStageCheckpoint(c)
            return .init(preparationID: preparationID, persistentReference: owner.persistentReference, journalAttemptID: c.stageAttemptID)
        } catch { journal.invalidateStageQualification(); throw error }
    }
    private func finishOriginal(_ attempt: Attempt) throws -> Result {
        guard let reference = attempt.persistentReference else { throw NativeEnrollmentStageError.outcomeUncertain }
        // No new checkpoint is acquired. The original predecessor is retained,
        // including when an exact ownership journal write must be recommitted.
        try journal.verifyStageAttemptOrOriginalOwnership(attempt)
        guard let item = try backend.readPersistentReference(reference), item.persistentReference == reference,
            item.service == Data(NativeEnrollmentStageEnvelope.service.utf8), item.account == attempt.envelope.binding.stage,
            item.accessible, try NativeEnrollmentStageEnvelope.qualify(item.keychainPayload(), expected: attempt.envelope.binding).exactEnvelope(attempt.envelope) else {
            throw NativeEnrollmentStageError.outcomeUncertain
        }
        let observed = try rawInventory(attempt.checkpoint, current: attempt)
        let expected = attempt.baseline + [item]
        guard sameRawItems(observed, expected) else { throw NativeEnrollmentStageError.inventoryBlocked }
        try journal.verifyStageAttemptOrOriginalOwnership(attempt)
        _ = try journal.commitOriginalStageOwnership(attempt)
        // Scope-exit backend mutation or journal reentry must not return success.
        let final = try backend.readPersistentReference(reference)
        guard final == item else { journal.invalidateStageQualification(original: attempt); throw NativeEnrollmentStageError.outcomeUncertain }
        let after = try rawInventory(attempt.checkpoint, current: attempt)
        guard sameRawItems(after, expected) else { journal.invalidateStageQualification(original: attempt); throw NativeEnrollmentStageError.outcomeUncertain }
        try journal.verifyCommittedOriginalStageOwnership(attempt)
        return .init(preparationID: attempt.envelope.binding.preparationID, persistentReference: reference, journalAttemptID: attempt.ownershipAttemptID)
    }
    private func sameRawItems(_ a: [NativeEnrollmentRawCredentialItem], _ b: [NativeEnrollmentRawCredentialItem]) -> Bool {
        a.count == b.count && a.allSatisfy { item in b.filter { $0.persistentReference == item.persistentReference } == [item] }
    }
    private func rawInventory(_ checkpoint: NativeEnrollmentJournalStore.StageCheckpoint, current: Attempt?) throws -> [NativeEnrollmentRawCredentialItem] {
        let raw = try backend.enumerateRaw(limit: Self.maximumRawItems + 1)
        guard raw.count <= Self.maximumRawItems else { throw NativeEnrollmentStageError.capacity }
        let proposal = checkpoint.step.proposal
        var expected: [Data: DeviceManagementFormatHistory.Binding] = [:]
        for b in proposal.source.credentials {
            let ref = try NativeEnrollmentStageBinding.reference(Data(b.credentialReference.utf8))
            guard expected.updateValue(b, forKey: ref) == nil else { throw NativeEnrollmentStageError.inventoryBlocked }
        }
        var stages: [Data: NativeEnrollmentStageBinding] = [:]
        for declaration in checkpoint.step.priorDeclarations {
            let b = try NativeEnrollmentStageBinding(cloudRootID: journal.cloudRootID, declaration: declaration)
            guard stages.updateValue(b, forKey: b.stage) == nil else { throw NativeEnrollmentStageError.inventoryBlocked }
        }
        if current == nil, proposal.phase == .stageQualified {
            let bound = try NativeEnrollmentStageBinding(cloudRootID: journal.cloudRootID, proposal: proposal)
            guard checkpoint.retainedOwnerships.filter({ $0.matches(bound) }).count == 1,
                stages.updateValue(bound, forKey: bound.stage) == nil else { throw NativeEnrollmentStageError.inventoryBlocked }
        }
        if let current {
            guard stages.updateValue(current.envelope.binding, forKey: current.envelope.binding.stage) == nil else { throw NativeEnrollmentStageError.inventoryBlocked }
        }
        var refs = Set<Data>(), finalAccounts = Set<Data>(), stageAccounts = Set<Data>(), qualified: [Data: NativeEnrollmentStageEnvelope] = [:]
        for item in raw {
            guard item.accessible, (1...1024).contains(item.persistentReference.count), refs.insert(item.persistentReference).inserted else { throw NativeEnrollmentStageError.inventoryBlocked }
            let account = try NativeEnrollmentStageBinding.reference(item.account)
            if item.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8) {
                guard finalAccounts.insert(account).inserted, finalAccounts.count <= Self.maximumFinalItems,
                    let binding = expected[account], item.keychainPayload().count == (binding.format == .legacyLocal32 ? 32 : 48) else { throw NativeEnrollmentStageError.inventoryBlocked }
            } else if item.service == Data(NativeEnrollmentStageEnvelope.service.utf8) {
                guard stageAccounts.insert(account).inserted, stageAccounts.count <= Self.maximumStageItems, let binding = stages[account] else { throw NativeEnrollmentStageError.inventoryBlocked }
                if current == nil || account != current?.envelope.binding.stage {
                    guard checkpoint.retainedOwnerships.filter({ $0.matches(binding) && $0.persistentReference == item.persistentReference }).count == 1 else { throw NativeEnrollmentStageError.inventoryBlocked }
                }
                qualified[account] = try NativeEnrollmentStageEnvelope.qualify(item.keychainPayload(), expected: binding)
                if let current, account == current.envelope.binding.stage {
                    guard item.persistentReference == current.persistentReference, qualified[account]?.exactEnvelope(current.envelope) == true else { throw NativeEnrollmentStageError.inventoryBlocked }
                }
            } else { throw NativeEnrollmentStageError.inventoryBlocked }
        }
        guard finalAccounts == Set(expected.keys), stageAccounts == Set(stages.keys) else { throw NativeEnrollmentStageError.inventoryBlocked }
        for b in expected.values where b.format == .nativeInstallationV1 {
            let matches = stages.values.filter { $0.final == Data(b.credentialReference.utf8) && $0.binding == b }
            guard matches.count == 1, let matched = matches.first, let stage = qualified[matched.stage],
                let final = raw.first(where: { $0.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8) && $0.account == matched.final }),
                stage.exactMaterial(final.keychainPayload()) else { throw NativeEnrollmentStageError.inventoryBlocked }
        }
        return raw
    }
}
