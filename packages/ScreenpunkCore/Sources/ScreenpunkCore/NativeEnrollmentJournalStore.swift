import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Unmounted journal mechanics only. The owned Cloud root is disjoint from the
/// caller's destructive Local-reset root. No defaults, migration or production caller.
/// Immutable attempts independently retain installed-tip identities/bytes. Unknown
/// pending attempts and unbound candidates are quarantined, never adopted. Initial
/// publication orphan windows block; no external effects have been admitted there.
/// Inode binding guards cooperating replacement, not hostile same-UID rollback.
final class NativeEnrollmentJournalStore {
    enum Kind: Equatable { case binding, attempt, candidate }
    enum Point: Equatable { case created, written, fileSynced, beforePublish, published, directorySynced }
    struct Boundary: Equatable { let kind: Kind; let point: Point }
    struct LocalDurabilityReceipt {
        let journalAttemptID: UUID?
        /// Only this instance/current epoch can use a matching latest journal tip.
        /// This flag never qualifies secret inventory or history/enrollment IO.
        let qualifiesCurrentJournalTip: Bool
    }
    struct Diagnostic {
        let attemptID: UUID
        let candidateInstalled: Bool
        let step: NativePreparationReconstructionStep
        // No durability field, receipt or operational preparation handle.
    }
    fileprivate struct Ref: Equatable {
        let name: String, attemptID: UUID, preparationID: UUID
        let index: Int, phase: Int
        let identity: NativeJournalIdentity
    }
    fileprivate struct StageNodeDeclaration: Equatable {
        let ref: Ref
        let frameIdentity: NativeJournalIdentity
    }
    fileprivate struct Scan {
        let refs: [Ref]
        let tip: NativeJournalNode?
        let latestInstalled: Bool
        let preparationCount: Int, reservedBytes: Int
        let context: NativePreparationReconstructionContext
        let firstNativePreparationIDs: Set<UUID>
        let unfinishedIntent: Data?
        let stageOwnerships: [NativeJournalStageOwnership]
        let paired: NativePairReplay
    }
    // Scoped to one mutex/flock command; never survives an outside-lock callback.
    private struct PairPendingWitness {
        let name: String, candidateIdentity: NativeJournalIdentity
        var method: NativeJournalNode?
    }
    private struct OrdinaryPhaseCommand {
        let preparationID: UUID, attemptID: UUID
        let phase: Int
        let intent: Data?
        let reservation: Int
        let step: NativePreparationReconstructionStep?
        init(preparationID: UUID, attemptID: UUID, phase: Int, intent: Data? = nil,
            reservation: Int = 0, step: NativePreparationReconstructionStep? = nil) {
            self.preparationID = preparationID; self.attemptID = attemptID; self.phase = phase
            self.intent = intent; self.reservation = reservation; self.step = step
        }
    }
    private struct OrdinaryPreparationRequest { let bytes: Data, attemptID: UUID }
    private struct OrdinaryPhaseAnchor {
        let binding: NativeJournalNode, nodes: [StageNodeDeclaration]
        let tip: NativeJournalNode?, proof: NativeJournalNode?
        let originalEpoch: UInt64
        var expectedEpoch: UInt64
        var issuedMethod: NativeJournalNode?
        var issuedAttempt: NativeJournalAttempt?
    }
    // Only fixed new prepareIntent/appendPhaseAssertion selects this mode.
    // A preparation command is issued only after strict input qualification.
    private var ordinaryPreparationRequest: OrdinaryPreparationRequest?
    private var ordinaryAdmissionStep: NativePreparationReconstructionStep?
    private var ordinaryScopeActive: Bool { ordinaryPhaseCommand != nil || ordinaryPreparationRequest != nil }
    private var ordinaryPhaseCommand: OrdinaryPhaseCommand?
    private var ordinaryPhaseAnchor: OrdinaryPhaseAnchor?
    private var pairScanView: Scan?
    private var pairFrameIdentities: [NativeJournalIdentity] = []
    private var pairPendingWitness: PairPendingWitness?
    private struct Disk {
        let root: Int32, lock: Int32, attempts: Int32, frames: Int32
        let directory: NativeJournalIdentity, lockIdentity: NativeJournalIdentity
        let attemptsIdentity: NativeJournalIdentity, framesIdentity: NativeJournalIdentity
        let binding: NativeJournalNode?
        let diagnosticWitness: DiagnosticPhysicalWitness?
    }
    fileprivate struct Qualification {
        let epoch: UInt64
        let binding: NativeJournalNode
        let tip: NativeJournalNode?
        let proof: NativeJournalNode?
    }
    private static let epochLock = NSLock()
    private static var epochs: [String: UInt64] = [:]
    private let mutex = NSLock()
    private let boundary: (Boundary) throws -> Void
    private var qualification: Qualification?
    private var promotionInstalling: PromotionCheckpoint?
    private var livePromotionCommits: [UUID: NativeJournalNode] = [:]
    private var liveStageCommits: [UUID: NativeJournalNode] = [:]
    private var liveStageEpochs: [UUID: UInt64] = [:]
    private var pairCommandScope = false
    private var pairPrivateAttempt: PairAttempt?
    private var pairInstallingRole: NativeJournalPairAssertion.Role?
    private var pairPrivateRoot: NativeJournalPairRoot?
    private var pairPrivateFiles: NativeJournalPairFiles?
    private var livePairCommits: [UUID: NativeJournalNode] = [:]
    private var originalStageReplayEpochs: [ObjectIdentifier: UInt64] = [:]
    let root: URL, cloudRootID: UUID, excludedLocalResetRoot: URL
    init(root: URL, cloudRootID: UUID, excludedLocalResetRoot: URL,
         boundary: @escaping (Boundary) throws -> Void = { _ in }) {
        self.root = root.standardizedFileURL; self.cloudRootID = cloudRootID
        self.excludedLocalResetRoot = excludedLocalResetRoot.standardizedFileURL; self.boundary = boundary
    }
    private func epoch(invalidate: Bool = false) -> UInt64 {
        Self.epochLock.lock(); defer { Self.epochLock.unlock() }
        let key = root.path + "|" + cloudRootID.uuidString
        let current = Self.epochs[key] ?? 0
        let value = invalidate ? current &+ 1 : current
        Self.epochs[key] = value; return value
    }
    private func beginAttempt() -> UInt64 { qualification = nil; return epoch(invalidate: true) }

    /// A first-native root is explicitly owned, not inferred from absent history.
    /// This read-only preflight precedes root metadata initialization.
    func initializeFirstNativeExplicit() throws -> LocalDurabilityReceipt {
        guard root.path.utf8.elementsEqual(root.resolvingSymlinksInPath().path.utf8) else { throw NativeEnrollmentJournalError.unsafeRoot }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        let rootIdentity = try identity(fd, directory: true)
        let children = Set(try names(fd))
        guard children.isSubset(of: ["journal.lock", "attempts", "frames", "root-binding.json"]) else { throw NativeEnrollmentJournalError.conflict }
        for name in ["attempts", "frames"] where children.contains(name) {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard child >= 0 else { throw failure() }; defer { close(child) }
            _ = try identity(child, directory: true)
            guard try names(child).isEmpty else { throw NativeEnrollmentJournalError.conflict }
        }
        let receipt = try initializeExplicit()
        let reopened = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard reopened >= 0 else { throw failure() }; defer { close(reopened) }
        guard try identity(reopened, directory: true) == rootIdentity else { qualification = nil; throw NativeEnrollmentJournalError.unsafeRoot }
        return receipt
    }
    func initializeExplicit() throws -> LocalDurabilityReceipt {
        try disk(create: true) { d in
            let generation = beginAttempt()
            let attemptNames = try names(d.attempts), frameNames = try names(d.frames)
            let binding: NativeJournalNode
            if let old = d.binding {
                try syncExisting(d.root, "root-binding.json", expected: old, limit: NativeJournalCodec.frameLimit)
                binding = old
            } else {
                guard attemptNames.isEmpty, frameNames.isEmpty else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let fd = try create(d.root, "root-binding.json.pending"); defer { close(fd) }
                let identity = try identity(fd, directory: false)
                let value = NativeJournalBinding(schemaVersion: 1, cloudRootID: cloudRootID, canonicalPath: root.path,
                    directory: d.directory, lock: d.lockIdentity, attempts: d.attemptsIdentity, frames: d.framesIdentity, ownIdentity: identity)
                let bytes = try NativeJournalCodec.encode(value)
                try event(.binding, .created); try writeExact(fd, bytes); try event(.binding, .written)
                try sync(fd); try event(.binding, .fileSynced)
                try publish(d, parent: d.root, temporary: "root-binding.json.pending", name: "root-binding.json", kind: .binding, expected: identity)
                binding = .init(identity: identity, bytes: bytes)
            }
            try sync(d.lock); try sync(d.attempts); try sync(d.frames); try sync(d.root); try check(d, expectedBinding: binding)
            let empty = attemptNames.isEmpty && frameNames.isEmpty
            if empty { qualification = .init(epoch: generation, binding: binding, tip: nil, proof: nil) }
            return .init(journalAttemptID: nil, qualifiesCurrentJournalTip: empty)
        }
    }

    /// Only intent metadata is admitted. The exact completed-path reservation is
    /// checked before candidate creation or any journal write effects.
    func prepareIntent(_ encodedRecord: Data, attemptID: UUID) throws -> LocalDurabilityReceipt {
        try prepareInitialIntent(encodedRecord, attemptID: attemptID, promotionProtocolVersion: nil, firstNative: false)
    }
    /// Explicit initial capability. Existing preparations cannot be upgraded.
    func preparePromotionIntent(_ encodedRecord: Data, attemptID: UUID) throws -> LocalDurabilityReceipt {
        _ = try NativeJournalCodec.promotionLayoutReservationProof()
        return try prepareInitialIntent(encodedRecord, attemptID: attemptID, promotionProtocolVersion: 1, firstNative: false)
    }
    /// Explicit fresh-source initialization, never inferred from missing persisted history.
    func prepareFirstNativePromotionIntent(_ encodedRecord: Data, attemptID: UUID) throws -> LocalDurabilityReceipt {
        _ = try NativeJournalCodec.firstNativeLayoutReservationProof()
        return try prepareInitialIntent(encodedRecord, attemptID: attemptID, promotionProtocolVersion: 1, firstNative: true)
    }
    private func prepareInitialIntent(_ encodedRecord: Data, attemptID: UUID, promotionProtocolVersion: Int?, firstNative: Bool) throws -> LocalDurabilityReceipt {
        guard encodedRecord.count <= NativeEnrollmentPreparationCodec.maximumBytes else { throw NativeEnrollmentJournalError.capacity }
        return try disk(ordinaryPreparation: .init(bytes: encodedRecord, attemptID: attemptID)) { d in
            let state = try scan(d)
            // Existing attempts are exact replay, never existence acknowledgments.
            if let ref = state.refs.first(where: { $0.attemptID == attemptID }) {
                disableOrdinaryPhaseScope()
                let a = try loadAttempt(d, ref).value
                guard a.method == .prepareIntent, a.intentPayload == encodedRecord,
                    try NativeJournalCodec.frame(a.targetPayload).promotionProtocolVersion == promotionProtocolVersion,
                    state.firstNativePreparationIDs.contains(ref.preparationID) == firstNative else { throw NativeEnrollmentJournalError.conflict }
                return try recommit(d, state: state, ref: ref)
            }
            guard state.unfinishedIntent == nil, state.preparationCount < NativeJournalCodec.preparationLimit else { throw NativeEnrollmentJournalError.capacity }
            try requireQualification(d, state)
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encodedRecord, context: state.context)
            guard step.proposal.phase == .intent, !state.refs.contains(where: { $0.preparationID == step.proposal.preparationId }) else { throw NativeEnrollmentJournalError.conflict }
            guard step.proposal.source.isFirstNative == firstNative else { throw NativeEnrollmentJournalError.conflict }
            if firstNative {
                guard state.refs.isEmpty, state.context.retainedDeclarationCount == 0,
                    state.paired.initialization == nil, try readPairDirectoryIdentity(d.root) == nil else { throw NativeEnrollmentJournalError.conflict }
            }
            let intent = encodedRecord
            let reservation = try NativeJournalCodec.reservation(intentBytes: intent.count)
            guard state.reservedBytes + reservation <= NativeJournalCodec.totalReservationLimit else { throw NativeEnrollmentJournalError.capacity }
            guard ordinaryPreparationRequest?.bytes == encodedRecord, ordinaryPreparationRequest?.attemptID == attemptID else { throw NativeEnrollmentJournalError.outcomeUncertain }
            ordinaryPhaseCommand = .init(preparationID: step.proposal.preparationId, attemptID: attemptID, phase: 0,
                intent: encodedRecord, reservation: reservation, step: step)
            return try install(d, state: state, attemptID: attemptID, preparationID: step.proposal.preparationId,
                phase: 0, intentAttemptID: attemptID, intent: intent, reservation: reservation, promotionProtocolVersion: promotionProtocolVersion)
        }
    }
    func appendPhaseAssertion(preparationID: UUID, next: NativeEnrollmentPreparation.Phase,
                              attemptID: UUID) throws -> LocalDurabilityReceipt {
        let command = (1...6).contains(next.rawValue) ? OrdinaryPhaseCommand(preparationID: preparationID, attemptID: attemptID, phase: next.rawValue) : nil
        return try disk(ordinaryPhase: command) { d in
            let state = try scan(d)
            if let existing = state.refs.first(where: { $0.attemptID == attemptID }) {
                // Exact replay retains the existing generic recovery path.
                disableOrdinaryPhaseScope()
                let existingFrame = try NativeJournalCodec.frame(loadAttempt(d, existing).value.targetPayload)
                guard existing.preparationID == preparationID, existing.phase == next.rawValue,
                    next != .intent, existingFrame.promotionProtocolVersion == nil || ![4, 5, 6].contains(next.rawValue) else { throw NativeEnrollmentJournalError.conflict }
                return try recommit(d, state: state, ref: existing)
            }
            guard let previous = state.refs.last, previous.preparationID == preparationID,
                previous.phase + 1 == next.rawValue, state.unfinishedIntent != nil else { throw NativeEnrollmentJournalError.conflict }
            try requireQualification(d, state)
            guard !(state.paired.initialization != nil && next.rawValue == 3) else { throw NativeEnrollmentJournalError.conflict }
            let prior = try NativeJournalCodec.frame(try loadAttempt(d, previous).value.targetPayload)
            guard prior.promotionProtocolVersion == nil || ![4, 5, 6].contains(next.rawValue) else { throw NativeEnrollmentJournalError.conflict }
            if next == .complete {
                guard let initial = state.unfinishedIntent, let admitted = ordinaryAdmissionStep,
                    admitted.proposal.phase == .promotionQualified else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let completed = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 6), context: state.context)
                guard completed.proposal.phase == .complete, completed.continuation != nil else { throw NativeEnrollmentJournalError.invalidRecord }
                try requireOrdinaryImmutableProjection(completed, admitted)
                ordinaryPhaseCommand = .init(preparationID: preparationID, attemptID: attemptID, phase: 6, step: completed)
            }
            return try install(d, state: state, attemptID: attemptID, preparationID: preparationID,
                phase: next.rawValue, intentAttemptID: prior.intentAttemptID, intent: nil, reservation: 0)
        }
    }
    private struct DiagnosticSnapshot {
        let refs: [Ref] // At most 771 compact declarations, never proposal snapshots.
        let binding: NativeJournalNode?
        let tip: NativeJournalNode?
        let installed: Bool
        let epoch: UInt64
        let count: Int
        let physical: DiagnosticPhysicalWitness
    }
    /// Delivers one historical, nonqualifying proposal at a time outside all locks.
    /// Each replay validates the captured chain; callback mutations invalidate the
    /// remaining stream, including a mutation after its final delivery. No inventory
    /// is manufactured, and read-only diagnosis does not alter tip qualification.
    func diagnose(_ visit: (Diagnostic) throws -> Void) throws {
        let captured = try disk { d in
            let generation = epoch(), physical = try diagnosticPhysicalWitness(d)
            let state = try scan(d)
            guard try diagnosticPhysicalWitness(d) == physical, epoch() == generation else { throw NativeEnrollmentJournalError.outcomeUncertain }
            return DiagnosticSnapshot(refs: state.refs, binding: d.binding, tip: state.tip,
                installed: state.latestInstalled, epoch: generation, count: state.preparationCount, physical: physical)
        }
        for selected in 0..<captured.count {
            guard let value = try diagnosticReplay(captured, selected: selected) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            try visit(value) // disk has returned: mutex and root flock are released.
        }
        _ = try diagnosticReplay(captured, selected: nil)
    }
    private func diagnosticReplay(_ captured: DiagnosticSnapshot, selected: Int?) throws -> Diagnostic? {
        do {
            return try disk(diagnosticWitness: captured.physical) { d in
                guard epoch() == captured.epoch, d.binding == captured.binding else { throw NativeEnrollmentJournalError.outcomeUncertain }
                guard let selected else { return nil }
                // The original complete semantic admission is bound to unchanged bytes.
                // Stop the selected prefix so later proposals never
                // coexist with the retained delivery value.
                enum Selected: Error { case found }
                var index = 0, result: Diagnostic?
                do {
                    _ = try scan(d) { value in
                        if index == selected { result = value; throw Selected.found }
                        index += 1
                    }
                } catch Selected.found { }
                try check(d)
                guard epoch() == captured.epoch, result != nil else { throw NativeEnrollmentJournalError.outcomeUncertain }
                return result
            }
        } catch { throw NativeEnrollmentJournalError.outcomeUncertain }
    }
    func recommitExactAttempt(_ attemptID: UUID) throws -> LocalDurabilityReceipt {
        try disk { d in
            let state = try scan(d)
            guard let ref = state.refs.first(where: { $0.attemptID == attemptID }) else { throw NativeEnrollmentJournalError.conflict }
            return try recommit(d, state: state, ref: ref)
        }
    }
    func recommitExactLatestTip(expectedAttemptID: UUID?) throws -> LocalDurabilityReceipt {
        try disk { d in
            let state = try scan(d)
            guard state.refs.last?.attemptID == expectedAttemptID else { throw NativeEnrollmentJournalError.conflict }
            if let ref = state.refs.last { return try recommit(d, state: state, ref: ref) }
            let generation = beginAttempt(); guard let binding = d.binding else { throw NativeEnrollmentJournalError.unsafeRoot }
            try syncExisting(d.root, "root-binding.json", expected: binding, limit: NativeJournalCodec.frameLimit)
            try sync(d.lock); try sync(d.attempts); try sync(d.frames); try sync(d.root); try check(d)
            qualification = .init(epoch: generation, binding: binding, tip: nil, proof: nil)
            return .init(journalAttemptID: nil, qualifiesCurrentJournalTip: true)
        }
    }
    /// Original phase3 capture, private construction only. Never remote/current authority.
    final class PromotionCheckpoint {
        let binding: NativeEnrollmentStageBinding, stagePersistentReference: Data
        fileprivate let issuer: ObjectIdentifier, journalBinding: NativeJournalNode
        fileprivate let originalNodes: [StageNodeDeclaration], originalTip: NativeJournalNode, originalProof: NativeJournalNode
        fileprivate let stageOwnership: NativeJournalStageOwnership, initialAttemptID: UUID, pairCompletionID: UUID
        fileprivate let promotionID: UUID, ownershipID: UUID, pairRoot: NativeJournalPairRoot, pairFiles: NativeJournalPairFiles
        fileprivate let payload: NativePairFiles.Payload
        fileprivate let priorBindings: [DeviceManagementFormatHistory.Binding]
        fileprivate let preparation: NativeEnrollmentPreparationReconstructionProposal
        fileprivate var activationProposal: NativeJournalActivationProposal?
        fileprivate var activationAssociation: NativeJournalActivationAssociation?
        fileprivate var associationID: UUID?
        fileprivate var generation: UInt64
        fileprivate init(store: NativeEnrollmentJournalStore, binding: NativeEnrollmentStageBinding, qualified: Qualification,
            nodes: [StageNodeDeclaration], tip: NativeJournalNode, proof: NativeJournalNode, owned: NativeJournalStageOwnership,
            initialID: UUID, pairID: UUID, promotionID: UUID, ownershipID: UUID, pairRoot: NativeJournalPairRoot,
            pairFiles: NativeJournalPairFiles, payload: NativePairFiles.Payload, priorBindings: [DeviceManagementFormatHistory.Binding], preparation: NativeEnrollmentPreparationReconstructionProposal) {
            self.binding = binding; stagePersistentReference = owned.persistentReference; issuer = ObjectIdentifier(store)
            journalBinding = qualified.binding; generation = qualified.epoch; originalNodes = nodes; originalTip = tip; originalProof = proof
            stageOwnership = owned; initialAttemptID = initialID; pairCompletionID = pairID
            self.promotionID = promotionID; self.ownershipID = ownershipID; self.pairRoot = pairRoot; self.pairFiles = pairFiles; self.payload = payload; self.priorBindings = priorBindings; self.preparation = preparation
        }
        fileprivate func ownership(_ ref: Data) -> NativeJournalFinalOwnership {
            .init(cloudRootID: binding.cloudRootID, preparationID: binding.preparationID, enrollmentID: binding.enrollmentID,
                localBindingID: binding.binding.credentialGenerationID, transitionID: binding.binding.transitionID, claimRequestID: binding.input.requestId,
                originalIntentAttemptID: initialAttemptID, promotionAttemptID: promotionID, stageOwnershipAttemptID: originalNodes.first(where: { $0.ref.phase == 2 && $0.ref.preparationID == binding.preparationID })!.ref.attemptID,
                pairedCompletionAttemptID: pairCompletionID, stageService: stageOwnership.stageService, stageAccount: stageOwnership.stageAccount,
                stagePersistentReference: stagePersistentReference, finalService: NativeEnrollmentStageEnvelope.finalService,
                finalAccount: String(decoding: binding.final, as: UTF8.self), finalPersistentReference: ref)
        }
    }
    final class FinalOwnershipQualification {
        fileprivate let original: PromotionCheckpoint, generation: UInt64, tip: NativeJournalNode, proof: NativeJournalNode
        fileprivate let ownership: NativeJournalFinalOwnership
        fileprivate init(_ c: PromotionCheckpoint, generation: UInt64, tip: NativeJournalNode, proof: NativeJournalNode, ownership: NativeJournalFinalOwnership) {
            original = c; self.generation = generation; self.tip = tip; self.proof = proof; self.ownership = ownership
        }
    }
    func capturePromotionOriginal(preparationID: UUID, promotionAttemptID: UUID, ownershipAttemptID: UUID,
        currentHistory: DeviceManagementFormatHistory, currentEnrollment: NativeEnrollmentEvidence) throws -> PromotionCheckpoint {
        _ = try NativeJournalCodec.promotionLayoutReservationProof()
        return try disk { d in
            let state = try scan(d); try requireQualification(d, state)
            guard let last = state.refs.last, last.preparationID == preparationID, last.phase == 3,
                state.paired.current?.role == .targetComplete, let latest = state.paired.latest,
                latest.completionAttemptID == last.attemptID, let pairRoot = state.paired.initialization?.root,
                let tip = state.tip, let initial = state.unfinishedIntent, let q = qualification,
                let owned = state.stageOwnerships.first(where: { $0.preparationID == preparationID }) else { throw NativeEnrollmentJournalError.conflict }
            let frame = try NativeJournalCodec.frame(tip.bytes)
            guard frame.schemaVersion == 4, frame.promotionProtocolVersion == 1 else { throw NativeEnrollmentJournalError.conflict }
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 3), context: state.context)
            let binding = try NativeEnrollmentStageBinding(cloudRootID: cloudRootID, proposal: step.proposal)
            let used = Set(state.refs.flatMap { [$0.attemptID, $0.preparationID] }).union(state.paired.retainedOperationIDs)
                .union([cloudRootID, binding.enrollmentID, binding.binding.transitionID, binding.binding.credentialGenerationID,
                    binding.input.requestId, binding.input.accountId, binding.input.locationId])
            guard promotionAttemptID != ownershipAttemptID, !used.contains(promotionAttemptID), !used.contains(ownershipAttemptID), owned.matches(binding) else { throw NativeEnrollmentJournalError.conflict }
            let payload = try pairPayload(d, projection: latest.projection)
            guard payload.history == (try nativeEnrollmentBytes(currentHistory)),
                payload.enrollment == (try NativeEnrollmentEvidenceCodec.encode(currentEnrollment, history: currentHistory)) else { throw NativeEnrollmentJournalError.conflict }
            try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: q.binding.identity) { fd in
                try NativePairFiles.current(fd, files: latest.files, payload: payload)
            }
            return .init(store: self, binding: binding, qualified: q, nodes: try stageNodes(d, refs: state.refs), tip: tip,
                proof: try loadAttempt(d, last).node, owned: owned, initialID: frame.intentAttemptID, pairID: last.attemptID,
                promotionID: promotionAttemptID, ownershipID: ownershipAttemptID, pairRoot: pairRoot, pairFiles: latest.files, payload: payload, priorBindings: step.proposal.source.credentials, preparation: step.proposal)
        }
    }
    /// Reuse accepted pure enrollment replay for role/relationship validation; no paired files are reassigned.
    private func validateActivationProjection(_ proposal: NativeJournalActivationProposal, preparation: NativeEnrollmentPreparationReconstructionProposal,
        activation: NativeActivationReceipt? = nil) throws {
        let history = preparation.targetHistory
        var value = try NativeEnrollmentRecovery.proposingClaimObservation(in: preparation.targetEnrollment, history: history,
            enrollmentId: preparation.enrollmentId, result: .claim(proposal.pendingClaim.receipt()))
        value = try NativeEnrollmentRecovery.proposingActivation(in: value, history: history, enrollmentId: preparation.enrollmentId,
            requestId: proposal.activationInput.requestId)
        guard let event = value.enrollments.last?.events.last,
            try nativeEnrollmentBytes(event) == nativeEnrollmentBytes(NativeEnrollmentEvidence.Event.activationProposed(proposal.activationInput.value)) else { throw NativeEnrollmentJournalError.conflict }
        if let activation {
            value = try NativeEnrollmentRecovery.proposingActivationObservation(in: value, history: history,
                enrollmentId: preparation.enrollmentId, receipt: activation)
        }
        _ = try NativeEnrollmentEvidenceCodec.encode(value, history: history)
    }
    private func stateIDsForProposal(_ binding: NativeEnrollmentStageBinding) -> Set<UUID> {
        [cloudRootID, binding.enrollmentID, binding.binding.transitionID, binding.binding.credentialGenerationID,
            binding.input.requestId, binding.input.accountId, binding.input.locationId]
    }
    private func promotionOriginal(_ c: PromotionCheckpoint, d: Disk, state: Scan) throws {
        guard c.issuer == ObjectIdentifier(self), c.generation == epoch(), c.journalBinding == d.binding,
            state.refs.count >= c.originalNodes.count, Array(state.refs.prefix(c.originalNodes.count)) == c.originalNodes.map({ $0.ref }),
            try stageNodes(d, refs: Array(state.refs.prefix(c.originalNodes.count))) == c.originalNodes,
            let base = state.refs.dropFirst(c.originalNodes.count - 1).first,
            try loadAttempt(d, base).node == c.originalProof else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let suffix = state.refs.dropFirst(c.originalNodes.count)
        guard suffix.count <= 3 else { throw NativeEnrollmentJournalError.conflict }
        for (offset, ref) in suffix.enumerated() {
            let loaded = try loadAttempt(d, ref), frame = try NativeJournalCodec.frame(loaded.value.targetPayload)
            guard ref.attemptID == (offset == 0 ? c.promotionID : (offset == 1 ? c.ownershipID : c.associationID)), ref.phase == offset + 4,
                loaded.node == livePromotionCommits[ref.attemptID], frame.promotionProtocolVersion == 1,
                (offset != 0 || frame.activationProposal == c.activationProposal),
                (offset != 1 || frame.finalOwnership?.promotionAttemptID == c.promotionID),
                (offset != 2 || frame.activationAssociation == c.activationAssociation) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        if suffix.isEmpty { guard state.tip == c.originalTip else { throw NativeEnrollmentJournalError.conflict } }
        try NativePairFiles.withRoot(d.root, root: c.pairRoot, cloudRootID: cloudRootID, journalBinding: c.journalBinding.identity) { fd in
            try NativePairFiles.current(fd, files: c.pairFiles, payload: c.payload)
        }
    }
    func verifyPromotionOriginal(_ c: PromotionCheckpoint) throws {
        try disk { d in
            if livePromotionCommits[c.promotionID] != nil { try retryPromotionMethod(c, d: d, id: c.promotionID) }
            let state = try scan(d); try promotionOriginal(c, d: d, state: state)
            // Original read-only preflight can retain its own uncertain phase4;
            // commitPromotionAttempt must durably recommit before any Add.
            if state.refs.last?.attemptID != c.promotionID { try requireQualification(d, state) }
        }
    }
    func verifyPromotionOriginalOrOwnFinalOwnership(_ c: PromotionCheckpoint) throws {
        try disk { d in
            if livePromotionCommits[c.ownershipID] != nil { try retryPromotionMethod(c, d: d, id: c.ownershipID) }
            let state = try scan(d); try promotionOriginal(c, d: d, state: state)
            if state.refs.last?.attemptID != c.ownershipID { try requireQualification(d, state) }
        }
    }
    func verifyPromotionInventory(_ c: PromotionCheckpoint, inventory: [NativeEnrollmentRawCredentialItem]) throws {
        try disk { d in
            let state = try scan(d); try requireQualification(d, state); try promotionOriginal(c, d: d, state: state)
            try NativeEnrollmentPromotionBridge.validateInventory(inventory)
            let stages = inventory.filter { $0.service == Data(NativeEnrollmentStageEnvelope.service.utf8) }
            let finals = inventory.filter { $0.service == Data(NativeEnrollmentStageEnvelope.finalService.utf8) }
            guard stages.count == state.stageOwnerships.count, state.stageOwnerships.allSatisfy({ owned in
                stages.contains { $0.account == Data(owned.stageAccount.utf8) && $0.persistentReference == owned.persistentReference }
            }), finals.count == c.priorBindings.count else { throw NativeEnrollmentJournalError.conflict }
            for binding in c.priorBindings {
                guard let final = finals.first(where: { $0.account == Data(binding.credentialReference.utf8) }),
                    final.keychainPayload().count == (binding.format == .legacyLocal32 ? 32 : 48) else { throw NativeEnrollmentJournalError.conflict }
                if binding.format == .nativeInstallationV1 {
                    var found = false
                    for ref in state.refs {
                        if let owned = try NativeJournalCodec.frame(loadAttempt(d, ref).value.targetPayload).finalOwnership,
                            owned.localBindingID == binding.credentialGenerationID, owned.finalPersistentReference == final.persistentReference { found = true }
                    }
                    guard found else { throw NativeEnrollmentJournalError.conflict }
                }
            }
        }
    }
    private func retryPromotionMethod(_ c: PromotionCheckpoint, d: Disk, id: UUID) throws {
        guard let captured = livePromotionCommits[id] else { return }
        guard c.issuer == ObjectIdentifier(self), c.generation == epoch(), c.journalBinding == d.binding else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let attempt = try NativeJournalCodec.attempt(captured.bytes), name = filename(attempt.index, id)
        let published = try readFile(d.attempts, name, limit: NativeJournalCodec.phaseAttemptLimit)
        let pending = try readFile(d.attempts, name + ".pending", limit: NativeJournalCodec.phaseAttemptLimit)
        guard (published == nil) != (pending == nil) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if let pending {
            guard pending.identity == captured.identity, captured.bytes.starts(with: pending.bytes),
                let candidate = try readFile(d.frames, name + ".pending", limit: NativeJournalCodec.frameLimit),
                candidate.identity == attempt.candidateIdentity, attempt.targetPayload.starts(with: candidate.bytes),
                try readFile(d.frames, name, limit: NativeJournalCodec.frameLimit) == nil else { throw NativeEnrollmentJournalError.outcomeUncertain }
            // Exact in-process issued method only. Unknown/restart scratch is never adopted.
            let baseline = c.originalNodes.map { $0.ref.name }
            let predecessorName = filename(c.originalNodes.count + 1, c.promotionID)
            let expected = Set(baseline + (id == c.promotionID ? [] : [predecessorName])
                + (id == c.associationID ? [filename(c.originalNodes.count + 2, c.ownershipID)] : []))
            guard Set(try names(d.attempts)) == expected.union([name + ".pending"]),
                Set(try names(d.frames)) == expected.union([name + ".pending"]) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            let prefix = try scanPublished(d, attemptNames: expected.sorted(), frameNames: expected)
            try promotionOriginal(c, d: d, state: prefix)
            guard attempt.predecessor == prefix.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
            let fd = openat(d.attempts, name + ".pending", O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            guard try identity(fd, directory: false) == captured.identity else { throw NativeEnrollmentJournalError.conflict }
            try writeExact(fd, captured.bytes); try sync(fd)
            try publish(d, parent: d.attempts, temporary: name + ".pending", name: name, kind: .attempt, expected: captured.identity)
        } else { guard published == captured else { throw NativeEnrollmentJournalError.outcomeUncertain } }
    }
    private func promotionCommit(_ c: PromotionCheckpoint, final: NativeJournalFinalOwnership?) throws {
        try disk { d in
            let id = final == nil ? c.promotionID : c.ownershipID, phase = final == nil ? 4 : 5
            try retryPromotionMethod(c, d: d, id: id)
            let state = try scan(d); try promotionOriginal(c, d: d, state: state)
            if state.refs.last?.attemptID == c.associationID, let association = c.activationAssociation {
                try requireQualification(d, state)
                guard let tip = state.tip, try NativeJournalCodec.frame(tip.bytes).activationAssociation == association else { throw NativeEnrollmentJournalError.conflict }
                return
            }
            if let ref = state.refs.last, ref.attemptID == id {
                let frame = try NativeJournalCodec.frame(loadAttempt(d, ref).value.targetPayload)
                guard frame.finalOwnership == final, phase != 4 || frame.activationProposal == c.activationProposal else { throw NativeEnrollmentJournalError.conflict }
                promotionInstalling = c; defer { promotionInstalling = nil }
                _ = try recommit(d, state: state, ref: ref); c.generation = epoch(); return
            }
            try requireQualification(d, state)
            guard state.refs.last?.phase == phase - 1 else { throw NativeEnrollmentJournalError.conflict }
            promotionInstalling = c; defer { promotionInstalling = nil }
            _ = try install(d, state: state, attemptID: id, preparationID: c.binding.preparationID, phase: phase,
                intentAttemptID: c.initialAttemptID, intent: nil, reservation: 0, promotionProtocolVersion: 1, finalOwnership: final, activationProposal: phase == 4 ? c.activationProposal : nil)
            c.generation = epoch()
        }
    }
    /// A genuine fixed claim request is the only issuer. Retain exact proposal before any journal effect.
    func commitPromotionActivationProposal(_ c: PromotionCheckpoint, observation: NativeOriginalClaimObservation) throws {
        guard observation.belongs(to: c), observation.proposal.matches(c.binding) else { throw NativeEnrollmentJournalError.conflict }
        try disk { d in
            let state = try scan(d); try promotionOriginal(c, d: d, state: state)
            try validateActivationProjection(observation.proposal, preparation: c.preparation)
            if let prior = c.activationProposal {
                guard prior == observation.proposal, c.associationID == observation.associationAttemptID else { throw NativeEnrollmentJournalError.conflict }
            } else {
                let used = Set(state.refs.flatMap { [$0.attemptID, $0.preparationID] }).union(state.paired.retainedOperationIDs)
                    .union([cloudRootID, c.binding.enrollmentID, c.binding.binding.transitionID, c.binding.binding.credentialGenerationID,
                        c.binding.input.requestId, c.binding.input.accountId, c.binding.input.locationId, c.promotionID, c.ownershipID])
                let remote = observation.proposal.activationInput.requestId, association = observation.associationAttemptID
                guard !used.contains(remote), !used.contains(association), remote != association,
                    ![observation.proposal.pendingClaim.installationId, observation.proposal.pendingClaim.challengeId].contains(remote),
                    ![observation.proposal.pendingClaim.installationId, observation.proposal.pendingClaim.challengeId].contains(association) else { throw NativeEnrollmentJournalError.conflict }
                c.activationProposal = observation.proposal; c.associationID = association
            }
        }
        try commitPromotionAttempt(c)
    }
    func commitPromotionAttempt(_ c: PromotionCheckpoint) throws {
        guard c.activationProposal != nil else { throw NativeEnrollmentJournalError.conflict }
        // Own phase5 is already stronger; never rewrite phase4 behind it.
        let alreadyFinal = try disk { d -> Bool in
            if livePromotionCommits[c.ownershipID] == nil { return false }
            try retryPromotionMethod(c, d: d, id: c.ownershipID)
            let state = try scan(d); try promotionOriginal(c, d: d, state: state)
            guard state.refs.last?.attemptID == c.ownershipID || (c.associationID != nil && state.refs.last?.attemptID == c.associationID) else { return false }
            return true
        }
        if !alreadyFinal { try promotionCommit(c, final: nil) }
    }
    func commitOriginalFinalOwnership(_ c: PromotionCheckpoint, finalPersistentReference: Data, ownershipAttemptID: UUID) throws {
        guard ownershipAttemptID == c.ownershipID else { throw NativeEnrollmentJournalError.conflict }
        let owned = c.ownership(finalPersistentReference); try owned.validate(); try promotionCommit(c, final: owned)
    }
    func qualifyOriginalFinalOwnership(_ c: PromotionCheckpoint, finalPersistentReference: Data, ownershipAttemptID: UUID) throws -> FinalOwnershipQualification {
        try disk { d in
            let state = try scan(d); try requireQualification(d, state); try promotionOriginal(c, d: d, state: state)
            guard ownershipAttemptID == c.ownershipID, let last = state.refs.last,
                let ownedRef = state.refs.first(where: { $0.attemptID == ownershipAttemptID }),
                let tip = state.tip, try NativeJournalCodec.frame(loadAttempt(d, ownedRef).value.targetPayload).finalOwnership == c.ownership(finalPersistentReference) else { throw NativeEnrollmentJournalError.conflict }
            return .init(c, generation: epoch(), tip: tip, proof: try loadAttempt(d, last).node, ownership: c.ownership(finalPersistentReference))
        }
    }
    func commitOriginalActivationAssociation(_ c: PromotionCheckpoint, observation: NativeOriginalActivationObservation) throws {
        guard observation.belongs(to: c), let proposal = c.activationProposal, let id = c.associationID else { throw NativeEnrollmentJournalError.conflict }
        let association = try NativeJournalActivationAssociation(proposal: proposal, receipt: observation.receipt, finalOwnershipAttemptID: c.ownershipID)
        try validateActivationProjection(proposal, preparation: c.preparation, activation: observation.receipt)
        try disk { d in
            if let prior = c.activationAssociation { guard prior == association else { throw NativeEnrollmentJournalError.conflict } }
            else { c.activationAssociation = association }
            try retryPromotionMethod(c, d: d, id: id)
            let state = try scan(d); try promotionOriginal(c, d: d, state: state)
            promotionInstalling = c; defer { promotionInstalling = nil }
            if let ref = state.refs.last, ref.attemptID == id {
                guard try NativeJournalCodec.frame(loadAttempt(d, ref).value.targetPayload).activationAssociation == association else { throw NativeEnrollmentJournalError.conflict }
                _ = try recommit(d, state: state, ref: ref)
            } else {
                try requireQualification(d, state)
                guard state.refs.last?.attemptID == c.ownershipID else { throw NativeEnrollmentJournalError.conflict }
                _ = try install(d, state: state, attemptID: id, preparationID: c.binding.preparationID, phase: 6,
                    intentAttemptID: c.initialAttemptID, intent: nil, reservation: 0, promotionProtocolVersion: 1, activationAssociation: association)
            }
            c.generation = epoch()
        }
    }
    func acceptedOriginalActivation(_ c: PromotionCheckpoint) throws -> NativeActivationReceipt {
        guard let association = c.activationAssociation else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let receipt = try association.activation.receipt()
        try qualifyOriginalActivationAssociation(c, activation: receipt)
        return receipt
    }
    func qualifyOriginalActivationAssociation(_ c: PromotionCheckpoint, activation: NativeActivationReceipt) throws {
        try disk { d in
            let state = try scan(d); try requireQualification(d, state); try promotionOriginal(c, d: d, state: state)
            guard let id = c.associationID, state.refs.last?.attemptID == id, let association = c.activationAssociation,
                let tip = state.tip, try NativeJournalCodec.frame(tip.bytes).activationAssociation == association,
                try nativeEnrollmentBytes(association.activation.receipt()) == nativeEnrollmentBytes(activation) else { throw NativeEnrollmentJournalError.conflict }
        }
    }
    final class StageCheckpoint {
        let step: NativePreparationReconstructionStep
        let stageAttemptID: UUID
        let retainedOwnerships: [NativeJournalStageOwnership]
        fileprivate let issuer: ObjectIdentifier, generation: UInt64, binding: NativeJournalNode, tip: NativeJournalNode, proof: NativeJournalNode
        fileprivate let count: Int
        fileprivate let nodes: [StageNodeDeclaration]
        fileprivate init(store: NativeEnrollmentJournalStore, state: Scan, qualified: Qualification, step: NativePreparationReconstructionStep,
            attempt: Ref, proof: NativeJournalNode, nodes: [StageNodeDeclaration]) throws {
            guard let tip = state.tip else { throw NativeEnrollmentJournalError.conflict }
            self.step = step; stageAttemptID = attempt.attemptID; retainedOwnerships = state.stageOwnerships
            issuer = ObjectIdentifier(store); generation = qualified.epoch; binding = qualified.binding; self.tip = tip; self.proof = proof; count = state.refs.count; self.nodes = nodes
        }
    }
    func captureStageIntent(preparationID: UUID) throws -> StageCheckpoint { try captureStage(preparationID, phase: 0, attemptID: nil) }
    func captureBoundStage(preparationID: UUID) throws -> StageCheckpoint { try captureStage(preparationID, phase: 2, attemptID: nil) }
    func captureStageAttempt(preparationID: UUID, stageAttemptID: UUID) throws -> StageCheckpoint { try captureStage(preparationID, phase: 1, attemptID: stageAttemptID) }
    private func captureStage(_ preparation: UUID, phase: Int, attemptID: UUID?) throws -> StageCheckpoint {
        try disk { d in
            let state = try scan(d); try requireQualification(d, state)
            guard let ref = state.refs.last, ref.preparationID == preparation, ref.phase == phase,
                attemptID == nil || ref.attemptID == attemptID, let initial = state.unfinishedIntent, let q = qualification else { throw NativeEnrollmentJournalError.conflict }
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: phase), context: state.context)
            try NativeJournalCodec.stageOwnershipReservationProof(NativeEnrollmentStageBinding(cloudRootID: cloudRootID, proposal: step.proposal))
            return try .init(store: self, state: state, qualified: q, step: step, attempt: ref, proof: loadAttempt(d, ref).node, nodes: stageNodes(d, refs: state.refs))
        }
    }
    func verifyStageCheckpoint(_ c: StageCheckpoint) throws {
        try disk { d in let state = try scan(d); try requireQualification(d, state); try originalStage(c, d: d, state: state) }
    }
    private func originalStage(_ c: StageCheckpoint, d: Disk, state: Scan) throws {
        try validateStagePrefix(c, d: d, state: state)
        guard c.issuer == ObjectIdentifier(self), (c.generation == epoch() || originalStageReplayEpochs[ObjectIdentifier(c)] == epoch()), c.binding == d.binding,
            c.tip == state.tip, state.refs.count == c.count, let ref = state.refs.last,
            ref.attemptID == c.stageAttemptID, try loadAttempt(d, ref).node == c.proof else { throw NativeEnrollmentJournalError.outcomeUncertain }
    }
    private func stageNodes(_ d: Disk, refs: [Ref]) throws -> [StageNodeDeclaration] {
        // Conservative compact declaration payload bound, not a heap promise.
        guard refs.count <= NativeJournalCodec.nodeLimit, refs.count * 512 <= NativeJournalCodec.compactDeclarationLimit else { throw NativeEnrollmentJournalError.capacity }
        return try refs.map { ref in
            guard ref.name.utf8.count <= 64, let frame = try readFile(d.frames, ref.name, limit: NativeJournalCodec.frameLimit),
                frame.identity == (try loadAttemptWitness(d, ref)).value.candidateIdentity else { throw NativeEnrollmentJournalError.outcomeUncertain }
            return .init(ref: ref, frameIdentity: frame.identity)
        }
    }
    private func validateStagePrefix(_ c: StageCheckpoint, d: Disk, state: Scan) throws {
        guard c.issuer == ObjectIdentifier(self), c.binding == d.binding, c.nodes.count == c.count,
            state.refs.count >= c.count, Array(state.refs.prefix(c.count)) == c.nodes.map({ $0.ref }),
            try stageNodes(d, refs: Array(state.refs.prefix(c.count))) == c.nodes,
            let last = c.nodes.last,
            try readFile(d.frames, last.ref.name, limit: NativeJournalCodec.frameLimit) == c.tip,
            try loadAttempt(d, last.ref).node == c.proof else { throw NativeEnrollmentJournalError.outcomeUncertain }
        // A fully admitted same-current preparation can reconstruct the exact
        // original prefix without replaying every historical preparation again.
        // Ordinary phase/ownership suffixes and historical checkpoints keep the
        // complete original fallback; no metadata-selected prefix is accepted.
        let prefix: Scan
        if try admittedCurrentStagePrefix(c, d: d, state: state) { prefix = state }
        else { prefix = try scanPublished(d, attemptNames: c.nodes.map { $0.ref.name }, frameNames: Set(c.nodes.map { $0.ref.name })) }
        guard prefix.latestInstalled, let initial = prefix.unfinishedIntent else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let replay = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: last.ref.phase), context: prefix.context)
        let x = replay.proposal, y = c.step.proposal
        guard x.preparationId == y.preparationId, x.enrollmentId == y.enrollmentId, x.phase == y.phase,
            x.stageReference.utf8.elementsEqual(y.stageReference.utf8), x.binding == y.binding, x.claimInput == y.claimInput,
            x.reservedBytes == y.reservedBytes,
            try nativeEnrollmentBytes(x.source) == nativeEnrollmentBytes(y.source),
            try nativeEnrollmentBytes(x.targetHistory) == nativeEnrollmentBytes(y.targetHistory),
            try nativeEnrollmentBytes(x.sourceEnrollment) == nativeEnrollmentBytes(y.sourceEnrollment),
            try nativeEnrollmentBytes(x.targetEnrollment) == nativeEnrollmentBytes(y.targetEnrollment),
            try nativeEnrollmentBytes(replay.priorDeclarations) == nativeEnrollmentBytes(c.step.priorDeclarations),
            prefix.stageOwnerships == c.retainedOwnerships else { throw NativeEnrollmentJournalError.outcomeUncertain }
    }
    /// Only called after exact original physical prefix checks above and a
    /// complete strict current-chain admission in this command. No retained
    /// current-prefix cache or captured proposal supplies reconstruction input.
    private func admittedCurrentStagePrefix(_ c: StageCheckpoint, d: Disk, state: Scan) throws -> Bool {
        guard state.latestInstalled, state.unfinishedIntent != nil, let captured = c.nodes.last,
            let current = state.refs.last, current.preparationID == captured.ref.preparationID,
            let tip = state.tip, state.stageOwnerships == c.retainedOwnerships else { return false }
        let originalFrame = try NativeJournalCodec.frame(c.tip.bytes), currentFrame = try NativeJournalCodec.frame(tip.bytes)
        guard currentFrame.preparationID == originalFrame.preparationID,
            currentFrame.intentAttemptID == originalFrame.intentAttemptID,
            let initialRef = state.refs.first(where: { $0.attemptID == originalFrame.intentAttemptID }),
            initialRef.phase == 0, initialRef.preparationID == captured.ref.preparationID,
            initialRef.index <= c.count else { return false }
        var predecessor = c.tip
        for ref in state.refs.dropFirst(c.count) {
            let a = try loadAttemptWitness(d, ref).value
            let f = try NativeJournalCodec.frame(a.targetPayload)
            guard a.method == .pairedEvidence, a.preparationID == captured.ref.preparationID,
                a.cloudRootID == cloudRootID, a.rootBindingIdentity == d.binding?.identity,
                a.index == ref.index, a.predecessor == predecessor,
                f.cloudRootID == cloudRootID, f.attemptID == ref.attemptID,
                f.index == ref.index, f.phase == ref.phase, f.preparationID == captured.ref.preparationID,
                f.intentAttemptID == originalFrame.intentAttemptID,
                f.pairedEvidence != nil, f.stageOwnership == nil, [2, 3].contains(f.phase) else { return false }
            // Full admission already validated the legal chronological role
            // sequence. Fresh independent bytes/inode checks prove this suffix
            // is still that admitted physical sequence before reuse.
            guard let frame = try readFile(d.frames, ref.name, limit: NativeJournalCodec.frameLimit),
                frame.identity == a.candidateIdentity, frame.bytes == a.targetPayload else { throw NativeEnrollmentJournalError.outcomeUncertain }
            predecessor = frame
        }
        guard predecessor == state.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
        return true
    }
    private func originalPendingExists(_ a: NativeEnrollmentStageBridge.Attempt, d: Disk) throws -> Bool {
        try readFile(d.attempts, filename(a.checkpoint.count + 1, a.ownershipAttemptID) + ".pending", limit: NativeJournalCodec.phaseAttemptLimit) != nil
    }
    private func inspectOriginalPending(_ a: NativeEnrollmentStageBridge.Attempt, d: Disk) throws -> (Ref, NativeJournalNode, NativeJournalAttempt) {
        let c = a.checkpoint, name = filename(c.count + 1, a.ownershipAttemptID)
        guard c.issuer == ObjectIdentifier(self), c.binding == d.binding, c.step.proposal.phase == .stageAttempted,
            liveStageEpochs[a.ownershipAttemptID] == epoch(), let captured = liveStageCommits[a.ownershipAttemptID],
            Set(try names(d.attempts)) == Set(c.nodes.map { $0.ref.name } + [name + ".pending"]),
            Set(try names(d.frames)) == Set(c.nodes.map { $0.ref.name } + [name + ".pending"]),
            let pending = try readFile(d.attempts, name + ".pending", limit: NativeJournalCodec.phaseAttemptLimit), pending == captured else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let recorded = try NativeJournalCodec.attempt(pending.bytes)
        guard recorded.method == .bindStageOwnership, recorded.cloudRootID == cloudRootID,
            recorded.preparationID == a.envelope.binding.preparationID, recorded.attemptID == a.ownershipAttemptID,
            recorded.index == c.count + 1, recorded.rootBindingIdentity == c.binding.identity,
            recorded.ownIdentity == pending.identity, recorded.predecessor == c.tip,
            recorded.targetPayload == (try NativeJournalCodec.encode(ownershipFrame(a))),
            let candidate = try readFile(d.frames, name + ".pending", limit: NativeJournalCodec.frameLimit),
            candidate.identity == recorded.candidateIdentity, candidate.bytes.isEmpty else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let prefix = try scanPublished(d, attemptNames: c.nodes.map { $0.ref.name }, frameNames: Set(c.nodes.map { $0.ref.name }))
        try validateStagePrefix(c, d: d, state: prefix)
        try check(d)
        guard liveStageEpochs[a.ownershipAttemptID] == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
        return (.init(name: name, attemptID: a.ownershipAttemptID, preparationID: recorded.preparationID,
            index: recorded.index, phase: 2, identity: pending.identity), pending, recorded)
    }
    private func recommitOriginalPending(_ a: NativeEnrollmentStageBridge.Attempt, d: Disk) throws -> LocalDurabilityReceipt {
        // All preflight is read-only and precedes epoch/write effects. Empty,
        // partial, replaced or metadata-issued attempts never enter this path.
        let (ref, node, recorded) = try inspectOriginalPending(a, d: d)
        let generation = beginAttempt(); liveStageEpochs[a.ownershipAttemptID] = generation
        try syncExisting(d.attempts, ref.name + ".pending", expected: node, limit: NativeJournalCodec.phaseAttemptLimit)
        try event(.attempt, .fileSynced)
        try publish(d, parent: d.attempts, temporary: ref.name + ".pending", name: ref.name, kind: .attempt, expected: node.identity)
        let fd = openat(d.frames, ref.name + ".pending", O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard try identity(fd, directory: false) == recorded.candidateIdentity else { throw NativeEnrollmentJournalError.outcomeUncertain }
        try writeExact(fd, recorded.targetPayload); try event(.candidate, .written)
        try sync(fd); try event(.candidate, .fileSynced)
        try publish(d, parent: d.frames, temporary: ref.name + ".pending", name: ref.name, kind: .candidate, expected: recorded.candidateIdentity)
        let receipt = try qualify(d, ref: ref, generation: generation)
        let state = try scan(d); try requireQualification(d, state)
        _ = try installedOriginalOwnership(a, d: d, state: state)
        try check(d)
        return receipt
    }
    func invalidateStageQualification(original: NativeEnrollmentStageBridge.Attempt? = nil) {
        // Only our own exact in-process original can preserve explicit retry
        // permission. A foreign epoch change is never converted into that right.
        guard mutex.try() else { _ = epoch(invalidate: true); return }
        defer { mutex.unlock() }
        let old = epoch(), next = epoch(invalidate: true); qualification = nil
        if let a = original {
            let c = a.checkpoint
            if c.issuer == ObjectIdentifier(self), c.generation == old || originalStageReplayEpochs[ObjectIdentifier(c)] == old {
                originalStageReplayEpochs[ObjectIdentifier(c)] = next
            }
            if liveStageEpochs[a.ownershipAttemptID] == old { liveStageEpochs[a.ownershipAttemptID] = next }
        }
    }
    private func ownershipFrame(_ a: NativeEnrollmentStageBridge.Attempt) throws -> NativeJournalFrame {
        let c = a.checkpoint
        return .init(schemaVersion: try NativeJournalCodec.frame(c.tip.bytes).schemaVersion >= 3 ? NativeJournalCodec.frame(c.tip.bytes).schemaVersion : 2, cloudRootID: cloudRootID, preparationID: a.envelope.binding.preparationID,
            attemptID: a.ownershipAttemptID, intentAttemptID: try NativeJournalCodec.frame(c.tip.bytes).intentAttemptID,
            index: c.count + 1, phase: 2, stageOwnership: try a.ownership(), promotionProtocolVersion: try NativeJournalCodec.frame(c.tip.bytes).promotionProtocolVersion)
    }
    private func installedOriginalOwnership(_ a: NativeEnrollmentStageBridge.Attempt, d: Disk, state: Scan) throws -> Ref {
        let c = a.checkpoint
        try validateStagePrefix(c, d: d, state: state)
        guard c.issuer == ObjectIdentifier(self), c.binding == d.binding, state.refs.count == c.count + 1,
            let ref = state.refs.last, ref.attemptID == a.ownershipAttemptID, ref.phase == 2,
            let captured = liveStageCommits[a.ownershipAttemptID], liveStageEpochs[a.ownershipAttemptID] == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let recorded = try loadAttempt(d, ref)
        guard recorded.node == captured, recorded.value.method == .bindStageOwnership,
            recorded.value.predecessor == c.tip, recorded.value.targetPayload == (try NativeJournalCodec.encode(ownershipFrame(a))) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        return ref
    }
    func verifyStageAttemptOrOriginalOwnership(_ a: NativeEnrollmentStageBridge.Attempt) throws {
        try disk { d in
            if try originalPendingExists(a, d: d) { _ = try inspectOriginalPending(a, d: d); return }
            let state = try scan(d)
            if state.refs.last?.attemptID == a.ownershipAttemptID { _ = try installedOriginalOwnership(a, d: d, state: state) }
            else {
                try originalStage(a.checkpoint, d: d, state: state)
                if qualification == nil {
                    guard originalStageReplayEpochs[ObjectIdentifier(a.checkpoint)] == epoch(), let ref = state.refs.last else { throw NativeEnrollmentJournalError.outcomeUncertain }
                    _ = try recommit(d, state: state, ref: ref)
                    originalStageReplayEpochs[ObjectIdentifier(a.checkpoint)] = epoch()
                }
                try requireQualification(d, state)
            }
        }
    }
    func commitOriginalStageOwnership(_ a: NativeEnrollmentStageBridge.Attempt) throws -> LocalDurabilityReceipt {
        do {
            return try disk { d in
                if try originalPendingExists(a, d: d) { return try recommitOriginalPending(a, d: d) }
                let state = try scan(d)
                if state.refs.last?.attemptID == a.ownershipAttemptID {
                    let ref = try installedOriginalOwnership(a, d: d, state: state)
                    let receipt = try recommit(d, state: state, ref: ref)
                    liveStageEpochs[a.ownershipAttemptID] = epoch(); return receipt
                }
                try requireQualification(d, state); try originalStage(a.checkpoint, d: d, state: state)
                guard a.checkpoint.step.proposal.phase == .stageAttempted else { throw NativeEnrollmentJournalError.conflict }
                return try install(d, state: state, attemptID: a.ownershipAttemptID, preparationID: a.envelope.binding.preparationID,
                    phase: 2, intentAttemptID: try NativeJournalCodec.frame(a.checkpoint.tip.bytes).intentAttemptID,
                    intent: nil, reservation: 0, stageOwnership: a.ownership())
            }
        } catch { invalidateStageQualification(original: a); throw error }
    }
    func verifyCommittedOriginalStageOwnership(_ a: NativeEnrollmentStageBridge.Attempt) throws {
        try disk { d in let state = try scan(d); try requireQualification(d, state); _ = try installedOriginalOwnership(a, d: d, state: state) }
    }
    private func requireQualification(_ d: Disk, _ state: Scan) throws {
        guard state.latestInstalled, let qualified = qualification, qualified.epoch == epoch(),
            qualified.binding == d.binding, qualified.tip == state.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if let ref = state.refs.last {
            guard try loadAttempt(d, ref).node == qualified.proof else { throw NativeEnrollmentJournalError.outcomeUncertain }
        } else { guard qualified.proof == nil else { throw NativeEnrollmentJournalError.outcomeUncertain } }
    }
    private func filename(_ index: Int, _ id: UUID) -> String { String(format: "%04d", index) + "-" + id.uuidString.lowercased() + ".json" }
    private func install(_ d: Disk, state: Scan, attemptID: UUID, preparationID: UUID,
                         phase: Int, intentAttemptID: UUID, intent: Data?, reservation: Int, stageOwnership: NativeJournalStageOwnership? = nil, pairedEvidence: NativeJournalPairAssertion? = nil, promotionProtocolVersion: Int? = nil, finalOwnership: NativeJournalFinalOwnership? = nil, activationProposal: NativeJournalActivationProposal? = nil, activationAssociation: NativeJournalActivationAssociation? = nil) throws -> LocalDurabilityReceipt {
        guard !state.refs.contains(where: { $0.attemptID == attemptID }), let binding = d.binding else { throw NativeEnrollmentJournalError.conflict }
        let index = state.refs.count + 1
        let inheritedPromotion = phase == 0 ? nil : try state.tip.flatMap { try NativeJournalCodec.frame($0.bytes).promotionProtocolVersion }
        let promotion = promotionProtocolVersion ?? inheritedPromotion
        if promotion != nil { _ = try NativeJournalCodec.promotionLayoutReservationProof() }
        let extended = promotion != nil || pairedEvidence != nil || state.paired.initialization != nil
        guard index <= (extended ? NativeJournalCodec.nodeLimit : NativeJournalCodec.legacyNodeLimit) else { throw NativeEnrollmentJournalError.capacity }
        try pairEncodingProof(state: state, attemptID: attemptID, preparationID: preparationID, phase: phase, intentAttemptID: intentAttemptID, stageOwnership: stageOwnership, pair: pairedEvidence)
        let generation = try pairPrivateAttempt.map { try beginPairAttempt($0) } ?? beginAttempt()
        promotionInstalling?.generation = generation
        if ordinaryScopeActive {
            guard ordinaryPhaseAnchor.map({ $0.expectedEpoch &+ 1 }) == generation else { throw NativeEnrollmentJournalError.outcomeUncertain }
            ordinaryPhaseAnchor?.expectedEpoch = generation
        }
        let name = filename(index, attemptID)
        let candidateFD = try create(d.frames, name + ".pending"); defer { close(candidateFD) }
        let candidateIdentity = try identity(candidateFD, directory: false)
        if pairCommandScope || ordinaryScopeActive { pairPendingWitness = .init(name: name, candidateIdentity: candidateIdentity, method: nil) }
        try event(.candidate, .created)
        // Preserve the captured empty inode before any attempt can durably bind it.
        try sync(candidateFD); try sync(d.frames); try check(d)
        let frame = NativeJournalFrame(schemaVersion: promotion != nil ? 4 : (extended ? 3 : (stageOwnership == nil ? 1 : 2)), cloudRootID: cloudRootID, preparationID: preparationID,
            attemptID: attemptID, intentAttemptID: intentAttemptID, index: index, phase: phase, stageOwnership: stageOwnership, pairedEvidence: pairedEvidence, promotionProtocolVersion: promotion, finalOwnership: finalOwnership, activationProposal: activationProposal, activationAssociation: activationAssociation)
        let target = try NativeJournalCodec.encode(frame)
        let attemptFD = try create(d.attempts, name + ".pending"); defer { close(attemptFD) }
        let attemptIdentity = try identity(attemptFD, directory: false)
        let attempt = NativeJournalAttempt(schemaVersion: promotion != nil ? 3 : (extended ? 2 : 1), cloudRootID: cloudRootID, preparationID: preparationID, attemptID: attemptID,
            index: index, method: activationAssociation != nil ? .bindActivationAssociation : (finalOwnership != nil ? .bindFinalOwnership : (pairedEvidence != nil ? .pairedEvidence : (stageOwnership != nil ? .bindStageOwnership : (phase == 0 ? .prepareIntent : .appendPhaseAssertion)))),
            rootBindingIdentity: binding.identity, ownIdentity: attemptIdentity, predecessor: state.tip,
            candidateIdentity: candidateIdentity, targetPayload: target, intentPayload: intent, reservation: reservation)
        let bytes = try NativeJournalCodec.encode(attempt)
        guard bytes.count <= (phase == 0 ? NativeJournalCodec.attemptLimit : NativeJournalCodec.phaseAttemptLimit), target.count <= NativeJournalCodec.frameLimit else { throw NativeEnrollmentJournalError.capacity }
        if pairedEvidence != nil {
            livePairCommits[attemptID] = .init(identity: attemptIdentity, bytes: bytes)
            pairPendingWitness?.method = .init(identity: attemptIdentity, bytes: bytes)
        }
        if ordinaryScopeActive {
            ordinaryPhaseAnchor?.issuedMethod = .init(identity: attemptIdentity, bytes: bytes)
            ordinaryPhaseAnchor?.issuedAttempt = attempt
            pairPendingWitness?.method = .init(identity: attemptIdentity, bytes: bytes)
        }
        if stageOwnership != nil { liveStageCommits[attemptID] = .init(identity: attemptIdentity, bytes: bytes); liveStageEpochs[attemptID] = generation }
        if let promotionInstalling {
            promotionInstalling.generation = generation
            livePromotionCommits[attemptID] = .init(identity: attemptIdentity, bytes: bytes)
        }
        try event(.attempt, .created); try writeExact(attemptFD, bytes); try event(.attempt, .written)
        try sync(attemptFD); try event(.attempt, .fileSynced)
        try publish(d, parent: d.attempts, temporary: name + ".pending", name: name, kind: .attempt, expected: attemptIdentity)
        // The captured candidate inode is now bound by the exact synchronized
        // attempt record. Its bytes are not authoritative until recommitted.
        try writeExact(candidateFD, target); try event(.candidate, .written)
        try sync(candidateFD); try event(.candidate, .fileSynced)
        try publish(d, parent: d.frames, temporary: name + ".pending", name: name, kind: .candidate, expected: candidateIdentity)
        let ref = Ref(name: name, attemptID: attemptID, preparationID: preparationID, index: index, phase: phase, identity: attemptIdentity)
        if pairCommandScope { try extendPairView(d, ref: ref, attempt: attempt, installed: true) }
        if ordinaryScopeActive { try extendOrdinaryPhaseView(d, ref: ref, attempt: attempt) }
        return try qualify(d, ref: ref, generation: generation)
    }
    private func recommit(_ d: Disk, state: Scan, ref: Ref) throws -> LocalDurabilityReceipt {
        let generation = try pairPrivateAttempt.map { try beginPairAttempt($0) } ?? beginAttempt()
        promotionInstalling?.generation = generation
        let loaded = try loadAttempt(d, ref)
        try syncExisting(d.attempts, ref.name, expected: loaded.node, limit: NativeJournalCodec.attemptLimit)
        try event(.attempt, .fileSynced); try sync(d.attempts); try event(.attempt, .directorySynced); try check(d)
        if !state.latestInstalled && ref.index == state.refs.count {
            let name = ref.name + ".pending"
            let fd = openat(d.frames, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            guard try identity(fd, directory: false) == loaded.value.candidateIdentity else { throw NativeEnrollmentJournalError.conflict }
            try writeExact(fd, loaded.value.targetPayload)
            if pairCommandScope, let current = pairScanView, !current.latestInstalled {
                // Fixed original recommit wrote these issued bytes to its bound
                // inode; no diagnostic bytes are accepted as a refreshed tip.
                pairScanView = .init(refs: current.refs, tip: .init(identity: loaded.value.candidateIdentity, bytes: loaded.value.targetPayload), latestInstalled: false,
                    preparationCount: current.preparationCount, reservedBytes: current.reservedBytes, context: current.context, firstNativePreparationIDs: current.firstNativePreparationIDs,
                    unfinishedIntent: current.unfinishedIntent, stageOwnerships: current.stageOwnerships, paired: current.paired)
            }
            try event(.candidate, .written)
            try sync(fd); try event(.candidate, .fileSynced)
            try publish(d, parent: d.frames, temporary: name, name: ref.name, kind: .candidate, expected: loaded.value.candidateIdentity)
        }
        if ref.index == state.refs.count {
            if pairCommandScope, let current = pairScanView, !current.latestInstalled {
                pairScanView = .init(refs: current.refs, tip: .init(identity: loaded.value.candidateIdentity, bytes: loaded.value.targetPayload), latestInstalled: true,
                    preparationCount: current.preparationCount, reservedBytes: current.reservedBytes, context: current.context, firstNativePreparationIDs: current.firstNativePreparationIDs,
                    unfinishedIntent: current.unfinishedIntent, stageOwnerships: current.stageOwnerships, paired: current.paired)
                pairPendingWitness = nil
            }
            return try qualify(d, ref: ref, generation: generation)
        }
        // Retained old replay synchronizes only its own proof and installed frame.
        // It invalidates every instance and never qualifies a different current tip.
        guard let old = try readFile(d.frames, ref.name, limit: NativeJournalCodec.frameLimit),
            old.identity == loaded.value.candidateIdentity, old.bytes == loaded.value.targetPayload else { throw NativeEnrollmentJournalError.conflict }
        try syncExisting(d.frames, ref.name, expected: old, limit: NativeJournalCodec.frameLimit)
        try sync(d.frames); try sync(d.root); try check(d)
        return .init(journalAttemptID: ref.attemptID, qualifiesCurrentJournalTip: false)
    }
    private func qualify(_ d: Disk, ref: Ref, generation: UInt64) throws -> LocalDurabilityReceipt {
        let state = try scan(d)
        guard state.latestInstalled, state.refs.last?.attemptID == ref.attemptID, let binding = d.binding else { throw NativeEnrollmentJournalError.conflict }
        // Explicit restart qualification synchronizes the entire independently
        // retained proof chain one bounded record at a time, not just visible tip.
        for item in state.refs {
            let a = try loadAttemptWitness(d, item)
            try syncExisting(d.attempts, item.name, expected: a.node, limit: NativeJournalCodec.attemptLimit)
            guard let frame = try readFile(d.frames, item.name, limit: NativeJournalCodec.frameLimit),
                frame.identity == a.value.candidateIdentity, frame.bytes == a.value.targetPayload else { throw NativeEnrollmentJournalError.conflict }
            try syncExisting(d.frames, item.name, expected: frame, limit: NativeJournalCodec.frameLimit)
        }
        try syncExisting(d.root, "root-binding.json", expected: binding, limit: NativeJournalCodec.frameLimit)
        try sync(d.lock); try sync(d.attempts); try sync(d.frames); try sync(d.root); try check(d)
        let checked = try scan(d), proof = try loadAttempt(d, ref).node
        guard checked.tip == state.tip, checked.refs.last?.attemptID == ref.attemptID, epoch() == generation else { throw NativeEnrollmentJournalError.outcomeUncertain }
        qualification = .init(epoch: generation, binding: binding, tip: checked.tip, proof: proof)
        return .init(journalAttemptID: ref.attemptID, qualifiesCurrentJournalTip: true)
    }
    private func loadAttemptWitness(_ d: Disk, _ ref: Ref) throws -> (node: NativeJournalNode, value: NativeJournalAttemptWitness) {
        guard let node = try readFile(d.attempts, ref.name, limit: NativeJournalCodec.attemptLimit), node.identity == ref.identity else { throw NativeEnrollmentJournalError.conflict }
        let value = try NativeJournalCodec.attemptWitness(node.bytes)
        guard value.ownIdentity == node.identity, value.attemptID == ref.attemptID else { throw NativeEnrollmentJournalError.conflict }
        return (node, value)
    }
    private func loadAttempt(_ d: Disk, _ ref: Ref) throws -> (node: NativeJournalNode, value: NativeJournalAttempt) {
        guard let node = try readFile(d.attempts, ref.name, limit: NativeJournalCodec.attemptLimit), node.identity == ref.identity else { throw NativeEnrollmentJournalError.conflict }
        let value = try NativeJournalCodec.attempt(node.bytes)
        guard value.ownIdentity == node.identity, value.attemptID == ref.attemptID else { throw NativeEnrollmentJournalError.conflict }; return (node, value)
    }
    private func scan(_ d: Disk, visit: (Diagnostic) throws -> Void = { _ in }) throws -> Scan {
        guard d.binding != nil else { throw NativeEnrollmentJournalError.unsafeRoot }
        if (pairCommandScope || ordinaryScopeActive), let view = pairScanView { try check(d); return view }
        let attemptNames = try names(d.attempts).sorted(), frameNames = Set(try names(d.frames))
        guard attemptNames.allSatisfy({ !$0.hasSuffix(".pending") }), attemptNames.count <= NativeJournalCodec.nodeLimit else { throw NativeEnrollmentJournalError.outcomeUncertain }
        return try scanPublished(d, attemptNames: attemptNames, frameNames: frameNames, captureOrdinary: ordinaryScopeActive, visit: visit)
    }
    // Only journal-owned callers select a captured prefix, never metadata callers.
    private func scanPublished(_ d: Disk, attemptNames: [String], frameNames: Set<String>, captureOrdinary: Bool = false,
        visit: (Diagnostic) throws -> Void = { _ in }) throws -> Scan {
        if pairCommandScope, let view = pairScanView { try check(d); return view }
        guard let binding = d.binding, attemptNames.count <= NativeJournalCodec.nodeLimit, attemptNames.allSatisfy({ !$0.hasSuffix(".pending") }) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let boundNames = Set(attemptNames.flatMap { [$0, $0 + ".pending"] })
        guard frameNames.isSubset(of: boundNames) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        var usedFrames = Set<String>(), refs: [Ref] = [], tip: NativeJournalNode?
        var ownerships: [NativeJournalStageOwnership] = [], persistentRefs = Set<Data>(), paired = NativePairReplay()
        var firstNativePreparationIDs = Set<UUID>()
        var context = NativePreparationReconstructionContext.empty(), intent: Data?, intentAttemptID: UUID?
        var preparationID: UUID?, phase = -1, count = 0, reserved = 0, installed = true
        var promotionProtocol: Int?
        var activationProposal: NativeJournalActivationProposal?, finalOwnershipAttemptID: UUID?
        for (offset, name) in attemptNames.enumerated() {
            guard let node = try readFile(d.attempts, name, limit: NativeJournalCodec.attemptLimit) else { throw NativeEnrollmentJournalError.conflict }
            let a = try NativeJournalCodec.attempt(node.bytes), f = try NativeJournalCodec.frame(a.targetPayload)
            guard name == filename(offset + 1, a.attemptID), a.index == offset + 1,
                a.cloudRootID == cloudRootID, a.rootBindingIdentity == binding.identity, a.ownIdentity == node.identity,
                a.predecessor == tip, f.cloudRootID == cloudRootID, f.preparationID == a.preparationID,
                f.attemptID == a.attemptID, f.index == a.index,
                !refs.contains(where: { $0.attemptID == a.attemptID }) else { throw NativeEnrollmentJournalError.conflict }
            if a.method == .prepareIntent {
                paired.newPreparation()
                guard intent == nil, f.phase == 0, f.intentAttemptID == a.attemptID,
                    !refs.contains(where: { $0.preparationID == a.preparationID }), let initial = a.intentPayload else { throw NativeEnrollmentJournalError.conflict }
                let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(initial, context: context)
                guard step.proposal.phase == .intent, step.proposal.preparationId == a.preparationID else { throw NativeEnrollmentJournalError.invalidRecord }
                if step.proposal.source.isFirstNative { firstNativePreparationIDs.insert(a.preparationID) }
                intent = initial; intentAttemptID = a.attemptID; preparationID = a.preparationID; promotionProtocol = f.promotionProtocolVersion; activationProposal = nil; finalOwnershipAttemptID = nil
                count += 1; reserved += a.reservation
                guard count <= 64, reserved <= NativeJournalCodec.totalReservationLimit else { throw NativeEnrollmentJournalError.capacity }
            } else if let pair = f.pairedEvidence {
                guard intent != nil, a.preparationID == preparationID, f.intentAttemptID == intentAttemptID else { throw NativeEnrollmentJournalError.conflict }
                try paired.accept(pair, frame: f, attempt: a, previousPhase: phase, previousAttemptID: refs.last?.attemptID, previousIdentity: refs.last?.identity)
            } else {
                guard intent != nil, a.preparationID == preparationID, f.phase == phase + 1,
                    f.intentAttemptID == intentAttemptID,
                    !(paired.initialization != nil && f.phase == 3) else { throw NativeEnrollmentJournalError.conflict }
            }
            guard f.promotionProtocolVersion == promotionProtocol else { throw NativeEnrollmentJournalError.conflict }
            if let owned = f.stageOwnership {
                guard let initial = intent, let previous = refs.last, previous.phase == 1,
                    owned.stageAttemptID == previous.attemptID else { throw NativeEnrollmentJournalError.conflict }
                let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 1), context: context)
                let expected = try NativeEnrollmentStageBinding(cloudRootID: cloudRootID, proposal: step.proposal)
                guard owned.matches(expected), persistentRefs.insert(owned.persistentReference).inserted else { throw NativeEnrollmentJournalError.conflict }
                ownerships.append(owned)
            }
            if let proposal = f.activationProposal {
                guard let initial = intent, f.phase == 4 else { throw NativeEnrollmentJournalError.conflict }
                let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 3), context: context)
                let expected = try NativeEnrollmentStageBinding(cloudRootID: cloudRootID, proposal: step.proposal)
                let ids = Set(refs.flatMap { [$0.attemptID, $0.preparationID] }).union(stateIDsForProposal(expected))
                guard proposal.matches(expected), !ids.contains(proposal.activationInput.requestId), proposal.activationInput.requestId != f.attemptID else { throw NativeEnrollmentJournalError.conflict }
                try validateActivationProjection(proposal, preparation: step.proposal)
                activationProposal = proposal
            }
            if let association = f.activationAssociation {
                guard let proposal = activationProposal, let ownedID = finalOwnershipAttemptID,
                    association.finalOwnershipAttemptID == ownedID, association.activationInput.requestId != f.attemptID else { throw NativeEnrollmentJournalError.conflict }
                try association.validate(proposal: proposal)
                guard let initial = intent else { throw NativeEnrollmentJournalError.conflict }
                let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 3), context: context)
                try validateActivationProjection(proposal, preparation: step.proposal, activation: association.activation.receipt())
            }
            if let final = f.finalOwnership {
                finalOwnershipAttemptID = f.attemptID
                guard let previous = refs.last, previous.phase == 4, final.promotionAttemptID == previous.attemptID,
                    final.originalIntentAttemptID == intentAttemptID, final.pairedCompletionAttemptID == paired.latest?.completionAttemptID,
                    let owned = ownerships.first(where: { $0.preparationID == a.preparationID }),
                    final.stagePersistentReference == owned.persistentReference, final.stageService == owned.stageService,
                    final.stageAccount == owned.stageAccount, final.cloudRootID == owned.cloudRootID,
                    refs.contains(where: { $0.attemptID == final.stageOwnershipAttemptID && $0.phase == 2 && $0.preparationID == a.preparationID }),
                    final.enrollmentID == owned.enrollmentID, final.localBindingID == owned.localBindingID,
                    final.transitionID == owned.transitionID, final.claimRequestID == owned.claimRequestID,
                    persistentRefs.insert(final.finalPersistentReference).inserted, let initial = intent else { throw NativeEnrollmentJournalError.conflict }
                let proposal = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 3), context: context).proposal
                guard final.finalAccount.utf8.elementsEqual(proposal.binding.credentialReference.utf8) else { throw NativeEnrollmentJournalError.conflict }
            }
            let committed = try readFile(d.frames, name, limit: NativeJournalCodec.frameLimit)
            let pending = try readFile(d.frames, name + ".pending", limit: NativeJournalCodec.frameLimit)
            guard (committed == nil) != (pending == nil) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            installed = committed != nil
            if let committed {
                guard committed.identity == a.candidateIdentity, committed.bytes == a.targetPayload else { throw NativeEnrollmentJournalError.conflict }
                tip = committed; usedFrames.insert(name)
            } else {
                guard offset == attemptNames.count - 1, let pending, pending.identity == a.candidateIdentity else { throw NativeEnrollmentJournalError.conflict }
                tip = pending; usedFrames.insert(name + ".pending")
            }
            phase = f.phase
            let ref = Ref(name: name, attemptID: a.attemptID, preparationID: a.preparationID, index: a.index, phase: phase, identity: node.identity)
            refs.append(ref)
            if phase == 6 || offset == attemptNames.count - 1 {
                guard let initial = intent else { throw NativeEnrollmentJournalError.invalidRecord }
                let effective = try NativeJournalCodec.effectiveIntent(initial, phase: phase)
                let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(effective, context: context)
                if captureOrdinary, ordinaryPhaseCommand?.phase == 6, offset == attemptNames.count - 1 {
                    guard ordinaryAdmissionStep == nil else { throw NativeEnrollmentJournalError.outcomeUncertain }
                    ordinaryAdmissionStep = step
                }
                try visit(.init(attemptID: a.attemptID, candidateInstalled: installed, step: step))
                if phase == 6 && installed {
                    context = try requireContinuation(step); intent = nil; intentAttemptID = nil; preparationID = nil
                }
            }
        }
        guard usedFrames == frameNames else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let result = Scan(refs: refs, tip: tip, latestInstalled: installed, preparationCount: count, reservedBytes: reserved, context: context, firstNativePreparationIDs: firstNativePreparationIDs, unfinishedIntent: intent, stageOwnerships: ownerships, paired: paired)
        if pairCommandScope || captureOrdinary {
            guard !captureOrdinary || (ordinaryScopeActive && ordinaryPhaseAnchor == nil) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            pairScanView = result
            pairFrameIdentities = try refs.map { ref in
                let a = try loadAttemptWitness(d, ref).value
                return a.candidateIdentity
            }
        }
        if captureOrdinary {
            if let binding = d.binding, installed, ordinaryPreparationRequest != nil || intent != nil {
                let proof: NativeJournalNode?
                if let last = refs.last {
                    guard let node = try readFile(d.attempts, last.name, limit: NativeJournalCodec.attemptLimit) else { throw NativeEnrollmentJournalError.conflict }
                    proof = node
                } else {
                    guard tip == nil, count == 0, reserved == 0, intent == nil,
                        context.retainedDeclarationCount == 0, ownerships.isEmpty,
                        paired.initialization == nil else { throw NativeEnrollmentJournalError.outcomeUncertain }
                    proof = nil // Only the fully replayed initialized empty journal.
                }
                let generation = epoch()
                ordinaryPhaseAnchor = .init(binding: binding, nodes: zip(refs, pairFrameIdentities).map { .init(ref: $0.0, frameIdentity: $0.1) },
                    tip: tip, proof: proof, originalEpoch: generation, expectedEpoch: generation, issuedMethod: nil, issuedAttempt: nil)
            } else { disableOrdinaryPhaseScope() } // Pending/completed exact phase replay stays generic.
        }
        try check(d)
        return result
    }
    private func requireContinuation(_ step: NativePreparationReconstructionStep) throws -> NativePreparationReconstructionContext {
        guard let continuation = step.continuation else { throw NativeEnrollmentJournalError.invalidRecord }; return continuation
    }
    private func disk<T>(create: Bool = false, pairOriginal: PairAttempt? = nil, ordinaryPhase: OrdinaryPhaseCommand? = nil, ordinaryPreparation: OrdinaryPreparationRequest? = nil, diagnosticWitness: DiagnosticPhysicalWitness? = nil, _ operation: (Disk) throws -> T) throws -> T {
        // One synchronous command lifetime only. The inner command releases all
        // locks/descriptors and checks its throwing exit before this pool drains.
        // The generic return remains strongly owned; callbacks execute elsewhere.
#if canImport(Darwin)
        return try autoreleasepool {
            try diskCommand(create: create, pairOriginal: pairOriginal, ordinaryPhase: ordinaryPhase,
                ordinaryPreparation: ordinaryPreparation, diagnosticWitness: diagnosticWitness, operation)
        }
#else
        return try diskCommand(create: create, pairOriginal: pairOriginal, ordinaryPhase: ordinaryPhase,
            ordinaryPreparation: ordinaryPreparation, diagnosticWitness: diagnosticWitness, operation)
#endif
    }
    private func diskCommand<T>(create: Bool = false, pairOriginal: PairAttempt? = nil, ordinaryPhase: OrdinaryPhaseCommand? = nil, ordinaryPreparation: OrdinaryPreparationRequest? = nil, diagnosticWitness: DiagnosticPhysicalWitness? = nil, _ operation: (Disk) throws -> T) throws -> T {
        guard mutex.try() else { throw NativeEnrollmentJournalError.outcomeUncertain }; defer { mutex.unlock() }
        let entryQualification = qualification
        let entryEpoch = epoch()
        pairScanView = nil; pairFrameIdentities = []; pairPendingWitness = nil
        ordinaryPreparationRequest = ordinaryPreparation; ordinaryAdmissionStep = nil
        ordinaryPhaseCommand = ordinaryPhase; ordinaryPhaseAnchor = nil
        pairCommandScope = pairOriginal != nil; pairPrivateAttempt = pairOriginal; pairPrivateRoot = pairOriginal?.createdRoot; pairPrivateFiles = pairOriginal?.createdFiles
        defer {
            pairScanView = nil; pairFrameIdentities = []; pairPendingWitness = nil
            ordinaryPreparationRequest = nil; ordinaryAdmissionStep = nil
            ordinaryPhaseCommand = nil; ordinaryPhaseAnchor = nil
            pairCommandScope = false; pairPrivateAttempt = nil; pairPrivateRoot = nil; pairPrivateFiles = nil
        }
        let path = root.path, excluded = excludedLocalResetRoot.path
        guard path.utf8.count <= 4096, excluded.utf8.count <= 4096,
            path.utf8.elementsEqual(root.resolvingSymlinksInPath().path.utf8),
            excluded.utf8.elementsEqual(excludedLocalResetRoot.resolvingSymlinksInPath().path.utf8),
            path != excluded, !path.hasPrefix(excluded + "/"), !excluded.hasPrefix(path + "/") else { throw NativeEnrollmentJournalError.unsafeRoot }
        let rootFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard rootFD >= 0 else { throw failure() }; defer { close(rootFD) }
        let directory = try identity(rootFD, directory: true)
        let rootNames = Set(try names(rootFD)), allowed: Set<String> = ["journal.lock", "attempts", "frames", "root-binding.json", "evidence"]
        guard rootNames.isSubset(of: allowed), !rootNames.contains("evidence") || rootNames.contains("root-binding.json") else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if create { _ = beginAttempt() } // Invalidate before owned initialization writes.
        let lockFD = openat(rootFD, "journal.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
        guard lockFD >= 0 else { throw failure() }; defer { close(lockFD) }
        let lockIdentity = try identity(lockFD, directory: false)
        // Fail closed on a busy/reentrant root rather than deadlocking a streaming
        // diagnostic callback or a second instance. No write has been admitted.
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw NativeEnrollmentJournalError.outcomeUncertain }
            throw failure()
        }
        defer { flock(lockFD, LOCK_UN) }
        if create {
            for name in ["attempts", "frames"] { if mkdirat(rootFD, name, 0o700) != 0 && errno != EEXIST { throw failure() } }
        }
        let attemptsFD = openat(rootFD, "attempts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard attemptsFD >= 0 else { throw failure() }; defer { close(attemptsFD) }
        let framesFD = openat(rootFD, "frames", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard framesFD >= 0 else { throw failure() }; defer { close(framesFD) }
        let binding = try readFile(rootFD, "root-binding.json", limit: NativeJournalCodec.frameLimit)
        guard create || binding != nil else { throw NativeEnrollmentJournalError.unsafeRoot }
        let d = Disk(root: rootFD, lock: lockFD, attempts: attemptsFD, frames: framesFD, directory: directory, lockIdentity: lockIdentity,
            attemptsIdentity: try identity(attemptsFD, directory: true), framesIdentity: try identity(framesFD, directory: true), binding: binding, diagnosticWitness: diagnosticWitness)
        try check(d)
        var operationReturned = false
        do {
            let value = try operation(d)
            operationReturned = true
            if ordinaryScopeActive { try check(d) } // Throwing exit before a receipt can escape.
            return value
        } catch {
            if ordinaryScopeActive {
                // Preserve only the SAME already-qualified, fully admitted original
                // after a side-effect-free rejection. Never recapture permission.
                var unchanged = false
                if !operationReturned, let entry = entryQualification, let current = qualification, let anchor = ordinaryPhaseAnchor,
                    epoch() == entryEpoch, entry.epoch == entryEpoch, current.epoch == entry.epoch,
                    current.binding == entry.binding, current.tip == entry.tip, current.proof == entry.proof,
                    anchor.originalEpoch == entryEpoch, anchor.expectedEpoch == entryEpoch,
                    anchor.issuedMethod == nil, anchor.issuedAttempt == nil, anchor.binding == entry.binding,
                    anchor.tip == entry.tip, anchor.proof == entry.proof, let view = pairScanView {
                    do {
                        try check(d)
                        try checkOrdinaryPhaseWitnesses(d, view: view)
                        unchanged = true
                    } catch { unchanged = false }
                }
                if !unchanged { qualification = nil }
            }
            throw error
        }
    }
    /// Compact, nonauthorizing, command-local evidence. No decoded proposals retained.
    private struct DiagnosticPhysicalWitness: Equatable {
        let nodes: [PhysicalNode]
        let namespaces: [[String]]
    }
    private struct PhysicalNode: Equatable {
        let metadata: [UInt64]
        let digest: [UInt8]
    }
    private func physicalMetadata(_ fd: Int32, directory: Bool) throws -> [UInt64] {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw failure() }
        guard (value.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG),
            directory || value.st_nlink == 1, value.st_size >= 0 else { throw NativeEnrollmentJournalError.unsafeRoot }
#if canImport(Darwin)
        let modified = value.st_mtimespec, changed = value.st_ctimespec
#else
        let modified = value.st_mtim, changed = value.st_ctim
#endif
        return [UInt64(truncatingIfNeeded: value.st_dev), UInt64(value.st_ino), UInt64(value.st_mode),
            UInt64(value.st_uid), UInt64(value.st_gid), UInt64(value.st_nlink), UInt64(value.st_size),
            UInt64(truncatingIfNeeded: modified.tv_sec), UInt64(truncatingIfNeeded: modified.tv_nsec),
            UInt64(truncatingIfNeeded: changed.tv_sec), UInt64(truncatingIfNeeded: changed.tv_nsec)]
    }
    private func physicalFile(_ parent: Int32, _ name: String, limit: Int) throws -> PhysicalNode {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        let before = try physicalMetadata(fd, directory: false)
        guard before[6] <= UInt64(limit) else { throw NativeEnrollmentJournalError.capacity }
        var hash = NativeJournalSHA256(), count = 0, buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let amount = read(fd, &buffer, buffer.count)
            if amount < 0 { if errno == EINTR { continue }; throw failure() }
            if amount == 0 { break }
            guard amount <= limit - count else { throw NativeEnrollmentJournalError.capacity }
            count += amount; try hash.update(buffer.prefix(amount))
        }
        guard UInt64(count) == before[6], try physicalMetadata(fd, directory: false) == before else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let reopened = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard reopened >= 0 else { throw failure() }; defer { close(reopened) }
        guard try physicalMetadata(reopened, directory: false) == before else { throw NativeEnrollmentJournalError.outcomeUncertain }
        return .init(metadata: before, digest: hash.finalized())
    }
    private func diagnosticPhysicalWitness(_ d: Disk) throws -> DiagnosticPhysicalWitness {
        var nodes: [PhysicalNode] = [], namespaces: [[String]] = []
        var totalBytes: UInt64 = 0
        func retain(_ node: PhysicalNode) throws {
            guard node.metadata[6] <= 167_772_160 - totalBytes else { throw NativeEnrollmentJournalError.capacity }
            totalBytes += node.metadata[6]; nodes.append(node)
        }
        let rootNames = try names(d.root).sorted()
        guard Set(rootNames).isSubset(of: ["journal.lock", "attempts", "frames", "root-binding.json", "evidence"]) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        namespaces.append(rootNames)
        nodes.append(.init(metadata: try physicalMetadata(d.root, directory: true), digest: []))
        for (directory, limit) in [(d.attempts, NativeJournalCodec.attemptLimit), (d.frames, NativeJournalCodec.frameLimit)] {
            let before = try physicalMetadata(directory, directory: true), entries = try names(directory).sorted()
            guard entries.count <= NativeJournalCodec.nodeLimit else { throw NativeEnrollmentJournalError.capacity }
            namespaces.append(entries); nodes.append(.init(metadata: before, digest: []))
            for name in entries { try retain(physicalFile(directory, name, limit: limit)) }
            let role = directory == d.attempts ? "attempts" : "frames"
            let reopened = openat(d.root, role, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard reopened >= 0 else { throw failure() }; defer { close(reopened) }
            guard try physicalMetadata(reopened, directory: true) == before,
                try names(directory).sorted() == entries, try physicalMetadata(directory, directory: true) == before else { throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        for name in rootNames where name == "journal.lock" || name == "root-binding.json" {
            try retain(physicalFile(d.root, name, limit: NativeJournalCodec.frameLimit))
        }
        if rootNames.contains("evidence") {
            let fd = openat(d.root, "evidence", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            let before = try physicalMetadata(fd, directory: true), entries = try names(fd).sorted()
            let allowed: Set<String> = ["pair.lock", "pair-binding.json", "pair-binding.json.pending", NativePairFiles.historyName,
                NativePairFiles.enrollmentName, NativePairFiles.sourceHistory, NativePairFiles.sourceEnrollment,
                NativePairFiles.targetHistory, NativePairFiles.targetEnrollment]
            guard Set(entries).isSubset(of: allowed) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            namespaces.append(entries); nodes.append(.init(metadata: before, digest: []))
            for name in entries {
                let history: Set<String> = [NativePairFiles.historyName, NativePairFiles.sourceHistory, NativePairFiles.targetHistory]
                let enrollment: Set<String> = [NativePairFiles.enrollmentName, NativePairFiles.sourceEnrollment, NativePairFiles.targetEnrollment]
                let limit = history.contains(name) ? 65536 : (enrollment.contains(name) ? 1048576 : NativeJournalCodec.frameLimit)
                try retain(physicalFile(fd, name, limit: limit))
            }
            let reopened = openat(d.root, "evidence", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard reopened >= 0 else { throw failure() }; defer { close(reopened) }
            guard try physicalMetadata(reopened, directory: true) == before, try names(fd).sorted() == entries,
                try physicalMetadata(fd, directory: true) == before else { throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        let reopenedRoot = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard reopenedRoot >= 0 else { throw failure() }; defer { close(reopenedRoot) }
        guard try physicalMetadata(reopenedRoot, directory: true) == nodes[0].metadata,
            try names(d.root).sorted() == rootNames,
            try physicalMetadata(d.root, directory: true) == nodes[0].metadata else { throw NativeEnrollmentJournalError.outcomeUncertain }
        return .init(nodes: nodes, namespaces: namespaces)
    }
    private func check(_ d: Disk, expectedBinding: NativeJournalNode? = nil) throws {
        guard root.path.utf8.elementsEqual(root.resolvingSymlinksInPath().path.utf8) else { throw NativeEnrollmentJournalError.unsafeRoot }
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
            NativeJournalIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino)) == d.directory else { throw NativeEnrollmentJournalError.unsafeRoot }
        for (name, expected, directory) in [("journal.lock", d.lockIdentity, false), ("attempts", d.attemptsIdentity, true), ("frames", d.framesIdentity, true)] {
            let fd = openat(d.root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            guard try identity(fd, directory: directory) == expected else { throw NativeEnrollmentJournalError.unsafeRoot }
        }
        let actual = try readFile(d.root, "root-binding.json", limit: NativeJournalCodec.frameLimit)
        if let expected = expectedBinding ?? d.binding { guard actual == expected else { throw NativeEnrollmentJournalError.unsafeRoot } }
        if let actual {
            let b = try NativeJournalCodec.binding(actual.bytes)
            guard b.cloudRootID == cloudRootID, b.canonicalPath.utf8.elementsEqual(root.path.utf8), b.directory == d.directory,
                b.lock == d.lockIdentity, b.attempts == d.attemptsIdentity, b.frames == d.framesIdentity,
                b.ownIdentity == actual.identity else { throw NativeEnrollmentJournalError.unsafeRoot }
        }
        let names = Set(try names(d.root))
        let allowed: Set<String> = ["journal.lock", "attempts", "frames", "root-binding.json", "root-binding.json.pending", "evidence"]
        guard names.isSubset(of: allowed), d.binding == nil || !names.contains("root-binding.json.pending") else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if d.binding != nil {
            if let witness = d.diagnosticWitness {
                guard try diagnosticPhysicalWitness(d) == witness else { throw NativeEnrollmentJournalError.outcomeUncertain }
            } else if ordinaryScopeActive {
                if let view = pairScanView {
                    try checkOrdinaryPhaseWitnesses(d, view: view)
                    try checkPairNamespace(d, replay: view.paired)
                }
                // Complete strict admission populates the anchor before effects.
            } else if pairCommandScope {
                if let view = pairScanView {
                    try checkPairWitnesses(d, view: view)
                    try checkPairNamespace(d, replay: view.paired)
                }
                // Before strict replay only physical root checks run. No effect
                // is admitted until the complete replay and namespace check finish.
            } else { try checkPairNamespace(d) }
        }
    }
    private func identity(_ fd: Int32, directory: Bool) throws -> NativeJournalIdentity {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw NativeEnrollmentJournalError.unsafeRoot }
        return .init(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }
    private func names(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd); guard duplicate >= 0 else { throw failure() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw failure() }; defer { closedir(stream) }
        rewinddir(stream); var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name); guard names.count <= NativeJournalCodec.nameLimit else { throw NativeEnrollmentJournalError.capacity }
        }
        return names
    }
    private func readFile(_ parent: Int32, _ name: String, limit: Int) throws -> NativeJournalNode? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        let before = try identity(fd, directory: false)
        var info = stat(); guard fstat(fd, &info) == 0 else { throw failure() }
        guard info.st_size >= 0, info.st_size <= limit else { throw NativeEnrollmentJournalError.capacity }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let amount = read(fd, &buffer, buffer.count)
            if amount < 0 { if errno == EINTR { continue }; throw failure() }
            if amount == 0 { break }
            guard bytes.count + amount <= limit else { throw NativeEnrollmentJournalError.capacity }
            bytes.append(contentsOf: buffer.prefix(amount))
        }
        guard bytes.count == info.st_size, try identity(fd, directory: false) == before else { throw NativeEnrollmentJournalError.conflict }
        return .init(identity: before, bytes: bytes)
    }
    private func create(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure() }; return fd
    }
    private func writeExact(_ fd: Int32, _ bytes: Data) throws {
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw failure() }
        try bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let amount = write(fd, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if amount < 0 { if errno == EINTR { continue }; throw failure() }
                guard amount > 0 else { throw failure() }; offset += amount
            }
        }
    }
    private func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw failure() } }
    private func syncExisting(_ parent: Int32, _ name: String, expected: NativeJournalNode, limit: Int) throws {
        guard try readFile(parent, name, limit: limit) == expected else { throw NativeEnrollmentJournalError.conflict }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard try identity(fd, directory: false) == expected.identity else { throw NativeEnrollmentJournalError.conflict }
        try sync(fd)
        guard try readFile(parent, name, limit: limit) == expected else { throw NativeEnrollmentJournalError.conflict }
    }
    private func publish(_ d: Disk, parent: Int32, temporary: String, name: String, kind: Kind, expected: NativeJournalIdentity) throws {
        try event(kind, .beforePublish); try check(d)
        guard let staged = try readFile(parent, temporary, limit: NativeJournalCodec.attemptLimit), staged.identity == expected,
            try readFile(parent, name, limit: NativeJournalCodec.attemptLimit) == nil else { throw NativeEnrollmentJournalError.conflict }
        guard renameat(parent, temporary, parent, name) == 0 else { throw failure() }
        try event(kind, .published); try check(d)
        guard try readFile(parent, name, limit: NativeJournalCodec.attemptLimit) == staged else { throw NativeEnrollmentJournalError.conflict }
        try sync(parent); try event(kind, .directorySynced); try check(d)
    }
    private func event(_ kind: Kind, _ point: Point) throws {
        // New paired commands use their outside-lock boundary channel. The
        // preexisting journal-only fault hook remains unchanged for old callers.
        if pairCommandScope {
            if let role = pairInstallingRole { try pairPrivateAttempt?.trip(role: role, boundary: .init(kind: kind, point: point)) }
        } else { try boundary(.init(kind: kind, point: point)) }
    }
    private func failure() -> NativeEnrollmentJournalError { .io(errno) }
}

extension NativeEnrollmentJournalStore {
    /// Private original cursor, never constructed or refreshed by metadata callers.
    final class PairAttempt {
        let preparationID: UUID
        fileprivate let issuer: ObjectIdentifier, original: StageCheckpoint
        fileprivate let operationID = UUID()
        fileprivate var ids = Dictionary(uniqueKeysWithValues: NativeJournalPairAssertion.Role.allCases.map { ($0, UUID()) })
        fileprivate var generation: UInt64, nodes: [StageNodeDeclaration], tip: NativeJournalNode, proof: NativeJournalNode
        fileprivate var createdRoot: NativeJournalPairRoot?, createdFiles: NativeJournalPairFiles?
        fileprivate let fault: NativeEnrollmentPairedEvidenceStore.Fault?
        fileprivate var faultFired = false
        fileprivate func trip(role: NativeJournalPairAssertion.Role, boundary: Boundary) throws {
            if !faultFired, fault == NativeEnrollmentPairedEvidenceStore.Fault(role: role, boundary: boundary) { faultFired = true; throw NativeEnrollmentJournalError.io(EIO) }
        }
        fileprivate init(_ journal: NativeEnrollmentJournalStore, checkpoint: StageCheckpoint, fault: NativeEnrollmentPairedEvidenceStore.Fault? = nil) {
            self.fault = fault
            issuer = ObjectIdentifier(journal); original = checkpoint; preparationID = checkpoint.step.proposal.preparationId
            generation = checkpoint.generation; nodes = checkpoint.nodes; tip = checkpoint.tip; proof = checkpoint.proof
        }
    }
    func capturePairOriginal(preparationID: UUID, fault: NativeEnrollmentPairedEvidenceStore.Fault? = nil) throws -> PairAttempt {
        try NativeJournalCodec.pairedLayoutReservationProof()
        return try disk { d in
            let state = try scan(d); try requireQualification(d, state)
            guard let ref = state.refs.last, ref.preparationID == preparationID, ref.phase == 2,
                let initial = state.unfinishedIntent, let q = qualification, state.paired.current == nil,
                let tip = state.tip, try NativeJournalCodec.frame(tip.bytes).stageOwnership != nil else { throw NativeEnrollmentJournalError.conflict }
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: 2), context: state.context)
            try NativeJournalCodec.stageOwnershipReservationProof(NativeEnrollmentStageBinding(cloudRootID: cloudRootID, proposal: step.proposal))
            let c = try StageCheckpoint(store: self, state: state, qualified: q, step: step, attempt: ref, proof: loadAttempt(d, ref).node, nodes: stageNodes(d, refs: state.refs))
            let result = PairAttempt(self, checkpoint: c, fault: fault)
            try pairIDProof(result, state: state)
            return result
        }
    }
    func capturePairRecovery(preparationID: UUID) throws -> PairAttempt {
        try NativeJournalCodec.pairedLayoutReservationProof()
        return try disk { d in
            let state = try scan(d); try requireQualification(d, state)
            guard let ref = state.refs.last, ref.preparationID == preparationID, [2, 3].contains(ref.phase),
                let initial = state.unfinishedIntent, let q = qualification, state.paired.initialization != nil,
                state.stageOwnerships.contains(where: { $0.preparationID == preparationID }) else { throw NativeEnrollmentJournalError.conflict }
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(NativeJournalCodec.effectiveIntent(initial, phase: ref.phase), context: state.context)
            let c = try StageCheckpoint(store: self, state: state, qualified: q, step: step, attempt: ref, proof: loadAttempt(d, ref).node, nodes: stageNodes(d, refs: state.refs))
            let result = PairAttempt(self, checkpoint: c)
            try pairIDProof(result, state: state)
            return result
        }
    }
    private func pairIDProof(_ original: PairAttempt, state: Scan) throws {
        let ids = Array(original.ids.values) + [original.operationID]
        let p = original.original.step.proposal
        var used = Set(state.refs.flatMap { [$0.attemptID, $0.preparationID] })
        used.formUnion(state.paired.retainedOperationIDs)
        used.formUnion([cloudRootID, p.preparationId, p.enrollmentId, p.binding.transitionID, p.binding.credentialGenerationID, p.claimInput.requestId, p.claimInput.accountId, p.claimInput.locationId])
        used.formUnion(p.source.transitions.map(\.transitionID) + p.source.credentials.map(\.credentialGenerationID))
        for record in p.sourceEnrollment.enrollments {
            used.formUnion([record.localEnrollmentId, record.claimInput.requestId])
            for event in record.events {
                switch event {
                case .activationProposed(let input): used.insert(input.requestId)
                case .pendingClaimObserved(let receipt), .terminalClaimObserved(let receipt): used.formUnion([receipt.installationId, receipt.challengeId])
                case .historicalActivationObserved(let receipt): used.formUnion([receipt.installationId, receipt.initialGeneration.generationId])
                default: break
                }
            }
        }
        guard Set(ids).count == ids.count, Set(ids).isDisjoint(with: used) else { throw NativeEnrollmentJournalError.conflict }
    }
    func verifyPairOriginal(_ original: PairAttempt) throws {
        try pairDisk(original) { d, state in try pairOriginal(original, d: d, state: state) }
    }
    func invalidatePairOriginal(_ original: PairAttempt) {
        guard mutex.try() else { _ = epoch(invalidate: true); return }; defer { mutex.unlock() }
        let old = epoch(), next = epoch(invalidate: true); qualification = nil
        if original.issuer == ObjectIdentifier(self), original.generation == old { original.generation = next }
    }
    private func pairOriginal(_ original: PairAttempt, d: Disk, state: Scan) throws {
        guard original.issuer == ObjectIdentifier(self), original.generation == epoch(),
            original.original.binding == d.binding, state.refs == original.nodes.map({ $0.ref }), state.tip == original.tip,
            let last = state.refs.last, try loadAttempt(d, last).node == original.proof,
            try stageNodes(d, refs: state.refs) == original.nodes else { throw NativeEnrollmentJournalError.outcomeUncertain }
        try validateStagePrefix(original.original, d: d, state: state)
    }
    private func pairDisk<T>(_ original: PairAttempt, _ operation: (Disk, Scan) throws -> T) throws -> T {
        // Fixed private cursor scope, never a metadata-selected pending exclusion.
        return try disk(pairOriginal: original) { d in
            try retryOriginalPairPending(original, d: d)
            let state = try scan(d); try pairOriginal(original, d: d, state: state)
            let value = try operation(d, state)
            try check(d); guard original.generation == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
            return value
        }
    }
    private func beginPairAttempt(_ original: PairAttempt) throws -> UInt64 {
        qualification = nil
        Self.epochLock.lock(); defer { Self.epochLock.unlock() }
        let key = root.path + "|" + cloudRootID.uuidString, current = Self.epochs[key] ?? 0
        guard original.issuer == ObjectIdentifier(self), original.generation == current else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let next = current &+ 1; Self.epochs[key] = next; original.generation = next
        return next
    }
    private func advanceCursor(_ original: PairAttempt, d: Disk) throws {
        guard original.generation == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let state = try scan(d), old = original.nodes.map { $0.ref }
        guard state.latestInstalled, let last = state.refs.last, let tip = state.tip,
            state.refs.count == old.count || state.refs.count == old.count + 1,
            Array(state.refs.prefix(old.count)) == old,
            state.refs.count == old.count || original.ids.values.contains(last.attemptID) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let nodes = try stageNodes(d, refs: state.refs), proof = try loadAttempt(d, last).node
        guard original.generation == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
        original.nodes = nodes; original.tip = tip; original.proof = proof
        livePairCommits.removeValue(forKey: last.attemptID)
    }
    private func pairInstall(_ original: PairAttempt, d: Disk, state: Scan, assertion: NativeJournalPairAssertion) throws {
        guard let ref = state.refs.last else { throw NativeEnrollmentJournalError.conflict }
        guard original.generation == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let frame = try NativeJournalCodec.frame(try loadAttempt(d, ref).value.targetPayload), id = original.ids[assertion.role]!
        pairInstallingRole = assertion.role; defer { pairInstallingRole = nil }
        do {
            _ = try install(d, state: state, attemptID: id, preparationID: original.preparationID,
                phase: assertion.role == .targetComplete ? 3 : 2, intentAttemptID: frame.intentAttemptID, intent: nil, reservation: 0, pairedEvidence: assertion)
            try advanceCursor(original, d: d)
        } catch {
            throw error
        }
    }
    private func retryOriginalPairPending(_ original: PairAttempt, d: Disk) throws {
        guard original.issuer == ObjectIdentifier(self), original.generation == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let namesNow = try names(d.attempts), prefix = original.nodes.map { $0.ref.name }
        if namesNow.sorted() == prefix.sorted() { return }
        if let id = original.ids.values.first(where: { livePairCommits[$0] != nil && namesNow.contains(filename(original.nodes.count + 1, $0)) }),
            let captured = livePairCommits[id] {
            let name = filename(original.nodes.count + 1, id)
            guard Set(namesNow) == Set(prefix + [name]),
                try readFile(d.attempts, name, limit: NativeJournalCodec.phaseAttemptLimit) == captured else { throw NativeEnrollmentJournalError.outcomeUncertain }
            let a = try NativeJournalCodec.attempt(captured.bytes)
            guard a.method == .pairedEvidence, a.cloudRootID == cloudRootID, a.attemptID == id, a.index == original.nodes.count + 1,
                a.ownIdentity == captured.identity, a.predecessor == original.tip, a.preparationID == original.preparationID,
                a.rootBindingIdentity == original.original.binding.identity else { throw NativeEnrollmentJournalError.outcomeUncertain }
            pairPendingWitness = .init(name: name, candidateIdentity: a.candidateIdentity, method: captured)
            let prefixState = try scanPublished(d, attemptNames: prefix, frameNames: Set(prefix)); try pairOriginal(original, d: d, state: prefixState)
            let ref = Ref(name: name, attemptID: id, preparationID: a.preparationID, index: a.index, phase: try NativeJournalCodec.frame(a.targetPayload).phase, identity: captured.identity)
            let isInstalled = try readFile(d.frames, name, limit: NativeJournalCodec.frameLimit) != nil
            try extendPairView(d, ref: ref, attempt: a, installed: isInstalled)
            guard let state = pairScanView else { throw NativeEnrollmentJournalError.outcomeUncertain }
            if !state.latestInstalled {
                guard let candidate = try readFile(d.frames, name + ".pending", limit: NativeJournalCodec.frameLimit),
                    candidate.identity == a.candidateIdentity, a.targetPayload.starts(with: candidate.bytes) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
            _ = try recommit(d, state: state, ref: ref); try advanceCursor(original, d: d); return
        }
        guard let id = original.ids.values.first(where: { livePairCommits[$0] != nil && namesNow.contains(filename(original.nodes.count + 1, $0) + ".pending") }),
            let captured = livePairCommits[id] else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let name = filename(original.nodes.count + 1, id)
        guard Set(namesNow) == Set(prefix + [name + ".pending"]), Set(try names(d.frames)) == Set(prefix + [name + ".pending"]),
            try readFile(d.attempts, name + ".pending", limit: NativeJournalCodec.phaseAttemptLimit) == captured else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let recorded = try NativeJournalCodec.attempt(captured.bytes)
        guard recorded.method == .pairedEvidence, recorded.cloudRootID == cloudRootID, recorded.attemptID == id,
            recorded.index == original.nodes.count + 1, recorded.preparationID == original.preparationID,
            recorded.predecessor == original.tip, recorded.rootBindingIdentity == original.original.binding.identity,
            recorded.ownIdentity == captured.identity, let candidate = try readFile(d.frames, name + ".pending", limit: NativeJournalCodec.frameLimit),
            candidate.identity == recorded.candidateIdentity, candidate.bytes.isEmpty else { throw NativeEnrollmentJournalError.outcomeUncertain }
        pairPendingWitness = .init(name: name, candidateIdentity: recorded.candidateIdentity, method: captured)
        let state = try scanPublished(d, attemptNames: prefix, frameNames: Set(prefix)); try pairOriginal(original, d: d, state: state)
        let generation = try beginPairAttempt(original)
        try syncExisting(d.attempts, name + ".pending", expected: captured, limit: NativeJournalCodec.phaseAttemptLimit)
        try publish(d, parent: d.attempts, temporary: name + ".pending", name: name, kind: .attempt, expected: captured.identity)
        let fd = openat(d.frames, name + ".pending", O_RDWR | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard try identity(fd, directory: false) == recorded.candidateIdentity else { throw NativeEnrollmentJournalError.outcomeUncertain }
        try writeExact(fd, recorded.targetPayload); try sync(fd)
        try publish(d, parent: d.frames, temporary: name + ".pending", name: name, kind: .candidate, expected: recorded.candidateIdentity)
        let ref = Ref(name: name, attemptID: id, preparationID: original.preparationID, index: recorded.index, phase: try NativeJournalCodec.frame(recorded.targetPayload).phase, identity: captured.identity)
        try extendPairView(d, ref: ref, attempt: recorded, installed: true)
        _ = try qualify(d, ref: ref, generation: generation); try advanceCursor(original, d: d)
    }
    func advancePairOriginal(_ original: PairAttempt) throws -> NativeEnrollmentPairedEvidenceStore.Boundary? {
        try pairDisk(original) { d, state in
            let p = original.original.step.proposal
            guard let binding = d.binding, let last = state.refs.last else { throw NativeEnrollmentJournalError.conflict }
            let intentID = try NativeJournalCodec.frame(try loadAttempt(d, last).value.targetPayload).intentAttemptID
            let operation = state.paired.current?.operationID ?? (state.paired.initialized ? original.operationID : (state.paired.initialization?.operationID ?? original.operationID))
            func assertion(_ role: NativeJournalPairAssertion.Role, root: NativeJournalPairRoot?, baseline: NativeJournalPairBaseline? = nil, candidates: NativeJournalPairFiles? = nil) -> NativeJournalPairAssertion {
                .init(role: role, operationID: operation, projection: .init(intentAttemptID: intentID, kind: [.targetReserve, .targetBind, .targetComplete].contains(role) ? .target : .source), root: root, baseline: baseline, candidates: candidates, workspaceReservation: role == .initReserve ? NativeJournalCodec.pairedReservationLimit : 0)
            }
            if state.paired.initialization == nil {
                guard try readPairDirectoryIdentity(d.root) == nil else { throw NativeEnrollmentJournalError.outcomeUncertain }
                try pairInstall(original, d: d, state: state, assertion: assertion(.initReserve, root: nil)); return .rootReserved
            }
            guard let initialization = state.paired.initialization else { throw NativeEnrollmentJournalError.conflict }
            if initialization.role == .initReserve {
                if original.createdRoot == nil {
                    original.generation = try beginPairAttempt(original)
                    original.createdRoot = try NativePairFiles.createRoot(d.root, initializationAttemptID: original.ids[.initBind]!, reservationAttemptID: last.attemptID, reservationIdentity: last.identity)
                    pairPrivateRoot = original.createdRoot
                    return .rootCreated
                }
                guard let captured = original.createdRoot else { throw NativeEnrollmentJournalError.outcomeUncertain }
                original.generation = try beginPairAttempt(original)
                try NativePairFiles.syncCreatedRoot(d.root, root: captured, cloudRootID: cloudRootID, journalBinding: binding.identity)
                try pairInstall(original, d: d, state: state, assertion: assertion(.initBind, root: captured)); return .rootBound
            }
            guard let pairRoot = initialization.root else { throw NativeEnrollmentJournalError.conflict }
            if initialization.role == .initBind {
                original.generation = try beginPairAttempt(original)
                try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity, allowEmptyBinding: true) { fd in
                    try NativePairFiles.bindRoot(fd, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity)
                }
                try pairInstall(original, d: d, state: state, assertion: assertion(.initComplete, root: pairRoot)); original.createdRoot = nil; return .rootSynchronized
            }
            if state.paired.current == nil {
                try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity) { fd in
                    try NativePairFiles.current(fd, files: state.paired.latest?.files, payload: try state.paired.latest.map { try pairPayload(d, projection: $0.projection) })
                }
                try pairInstall(original, d: d, state: state, assertion: assertion(.sourceReserve, root: pairRoot, baseline: state.paired.latest)); return .sourceReserved
            }
            guard let current = state.paired.current else { throw NativeEnrollmentJournalError.conflict }
            switch current.role {
            case .sourceReserve, .targetReserve:
                let target = current.role == .targetReserve
                if original.createdFiles == nil {
                    original.generation = try beginPairAttempt(original)
                    original.createdFiles = try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity) { fd in
                        try NativePairFiles.current(fd, files: current.baseline?.files, payload: try current.baseline.map { try pairPayload(d, projection: $0.projection) })
                        return try NativePairFiles.createCandidates(fd, target: target)
                    }
                    pairPrivateFiles = original.createdFiles; return target ? .targetCreated : .sourceCreated
                }
                guard let captured = original.createdFiles else { throw NativeEnrollmentJournalError.outcomeUncertain }
                original.generation = try beginPairAttempt(original)
                try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity) { fd in
                    try NativePairFiles.syncCreatedCandidates(fd, files: captured, target: target)
                }
                try pairInstall(original, d: d, state: state, assertion: assertion(target ? .targetBind : .sourceBind, root: pairRoot, baseline: current.baseline, candidates: captured)); return target ? .targetBound : .sourceBound
            case .sourceBind, .targetBind:
                let target = current.role == .targetBind
                guard let candidates = current.candidates else { throw NativeEnrollmentJournalError.conflict }
                original.generation = try beginPairAttempt(original)
                try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity) { fd in
                    try NativePairFiles.publishPair(fd, candidates: candidates, target: target, payload: NativePairFiles.Payload(p, target: target), baseline: current.baseline, baselinePayload: try current.baseline.map { try pairPayload(d, projection: $0.projection) })
                }
                try pairInstall(original, d: d, state: state, assertion: assertion(target ? .targetComplete : .sourceComplete, root: pairRoot, baseline: current.baseline, candidates: candidates)); original.createdFiles = nil
                return target ? .targetSynchronized : .sourceSynchronized
            case .sourceComplete:
                try pairInstall(original, d: d, state: state, assertion: assertion(.targetReserve, root: pairRoot, baseline: state.paired.latest)); return .targetReserved
            case .targetComplete: return nil
            default: throw NativeEnrollmentJournalError.conflict
            }
        }
    }
    func qualifyPairOriginal(_ original: PairAttempt) throws -> UUID {
        try pairDisk(original) { d, state in
            guard state.paired.current?.role == .targetComplete, let root = state.paired.initialization?.root,
                let latest = state.paired.latest, let last = state.refs.last,
                latest.completionAttemptID == last.attemptID, last.phase == 3, let binding = d.binding else { throw NativeEnrollmentJournalError.outcomeUncertain }
            original.generation = try beginPairAttempt(original)
            try NativePairFiles.withRoot(d.root, root: root, cloudRootID: cloudRootID, journalBinding: binding.identity) { fd in
                let payload = try pairPayload(d, projection: latest.projection)
                try NativePairFiles.current(fd, files: latest.files, payload: payload)
                try NativePairFiles.syncFile(fd, NativePairFiles.historyName, expected: .init(identity: latest.files.history, bytes: payload.history), limit: 65536)
                try NativePairFiles.syncFile(fd, NativePairFiles.enrollmentName, expected: .init(identity: latest.files.enrollment, bytes: payload.enrollment), limit: 1048576)
                try NativePairFiles.sync(fd)
            }
            _ = try qualify(d, ref: last, generation: original.generation); try advanceCursor(original, d: d)
            return last.attemptID
        }
    }
    private func pairEncodingProof(state: Scan, attemptID: UUID, preparationID: UUID, phase: Int, intentAttemptID: UUID,
        stageOwnership: NativeJournalStageOwnership?, pair: NativeJournalPairAssertion?) throws {
        guard NativeJournalCodec.pairedCompletionReservation <= NativeJournalCodec.pairedReservationLimit else { throw NativeEnrollmentJournalError.capacity }
        let extended = pair != nil || state.paired.initialization != nil, maxIdentity = NativeJournalIdentity(device: .max, inode: .max)
        let frame = NativeJournalFrame(schemaVersion: extended ? 3 : (stageOwnership == nil ? 1 : 2), cloudRootID: cloudRootID, preparationID: preparationID, attemptID: attemptID, intentAttemptID: intentAttemptID, index: extended ? 771 : 448, phase: phase, stageOwnership: stageOwnership, pairedEvidence: pair)
        let payload = try NativeJournalCodec.encode(frame)
        let a = NativeJournalAttempt(schemaVersion: extended ? 2 : 1, cloudRootID: cloudRootID, preparationID: preparationID, attemptID: attemptID, index: extended ? 771 : 448, method: pair != nil ? .pairedEvidence : (stageOwnership != nil ? .bindStageOwnership : .appendPhaseAssertion), rootBindingIdentity: maxIdentity, ownIdentity: maxIdentity, predecessor: .init(identity: maxIdentity, bytes: Data(repeating: 0, count: 8192)), candidateIdentity: maxIdentity, targetPayload: payload, intentPayload: nil, reservation: 0)
        guard payload.count <= 8192, try NativeJournalCodec.encode(a).count <= 32768 else { throw NativeEnrollmentJournalError.capacity }
    }
    private func readPairDirectoryIdentity(_ root: Int32) throws -> NativeJournalIdentity? {
        let fd = openat(root, "evidence", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw failure() }; defer { close(fd) }
        return try identity(fd, directory: true)
    }
    private func pairPayload(_ d: Disk, projection: NativeJournalPairProjection) throws -> NativePairFiles.Payload {
        // The complete chain replayed this original strict intent. These exact
        // canonical projections are not caller-provided snapshots or authority.
        let suffix = "-" + projection.intentAttemptID.uuidString.lowercased() + ".json"
        let matching = try names(d.attempts).filter { $0.hasSuffix(suffix) }
        guard matching.count == 1, let name = matching.first,
            let node = try readFile(d.attempts, name, limit: NativeJournalCodec.attemptLimit) else { throw NativeEnrollmentJournalError.invalidRecord }
        let recorded = try NativeJournalCodec.attempt(node.bytes)
        guard recorded.attemptID == projection.intentAttemptID, recorded.method == .prepareIntent, recorded.ownIdentity == node.identity,
            let initial = recorded.intentPayload,
            let object = try JSONSerialization.jsonObject(with: initial) as? [String: Any],
            let h = object[projection.kind == .source ? "sourceHistory" : "targetHistory"],
            let e = object[projection.kind == .source ? "sourceEnrollment" : "targetEnrollment"] else { throw NativeEnrollmentJournalError.invalidRecord }
        return try NativePairFiles.Payload(history: JSONSerialization.data(withJSONObject: h, options: [.sortedKeys, .withoutEscapingSlashes]), enrollment: JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    /// No semantic reconstruction here: stream the independent exact method/frame
    /// witnesses against this command's strictly replayed compact declarations.
    private func disableOrdinaryPhaseScope() {
        ordinaryPreparationRequest = nil; ordinaryAdmissionStep = nil
        ordinaryPhaseCommand = nil; ordinaryPhaseAnchor = nil
        pairScanView = nil; pairFrameIdentities = []; pairPendingWitness = nil
    }
    /// Original compact physical declarations, not retained historical intent snapshots.
    /// Only this fixed command's captured inode/bytes can account for a new suffix.
    private func checkOrdinaryPhaseWitnesses(_ d: Disk, view: Scan) throws {
        guard ordinaryScopeActive, let anchor = ordinaryPhaseAnchor,
            anchor.binding == d.binding, anchor.expectedEpoch == epoch(),
            view.refs.count == pairFrameIdentities.count,
            view.refs.count == anchor.nodes.count || view.refs.count == anchor.nodes.count + 1,
            view.refs.count <= NativeJournalCodec.nodeLimit else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let expectedNames = Set(view.refs.map(\.name))
        let extra = pairPendingWitness.map { Set([$0.name, $0.name + ".pending"]) } ?? []
        let actualAttempts = Set(try names(d.attempts)), actualFrames = Set(try names(d.frames))
        guard actualAttempts.isSubset(of: expectedNames.union(extra)), actualFrames.isSubset(of: expectedNames.union(extra)) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        var predecessor: NativeJournalNode?
        for (offset, ref) in view.refs.enumerated() {
            let loaded = try loadAttemptWitness(d, ref), a = loaded.value
            guard let committed = try readFile(d.frames, ref.name, limit: NativeJournalCodec.frameLimit),
                try readFile(d.frames, ref.name + ".pending", limit: NativeJournalCodec.frameLimit) == nil,
                actualAttempts.contains(ref.name), !actualAttempts.contains(ref.name + ".pending"),
                a.index == offset + 1, a.cloudRootID == cloudRootID, a.preparationID == ref.preparationID,
                a.rootBindingIdentity == anchor.binding.identity, a.predecessor == predecessor,
                a.candidateIdentity == pairFrameIdentities[offset], committed.identity == a.candidateIdentity,
                committed.bytes == a.targetPayload else { throw NativeEnrollmentJournalError.conflict }
            if offset < anchor.nodes.count {
                guard anchor.nodes[offset].ref == ref, anchor.nodes[offset].frameIdentity == a.candidateIdentity else { throw NativeEnrollmentJournalError.outcomeUncertain }
            } else {
                guard let command = ordinaryPhaseCommand, ref.attemptID == command.attemptID, ref.preparationID == command.preparationID,
                    ref.phase == command.phase, loaded.node == anchor.issuedMethod else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
            predecessor = committed
            if offset == anchor.nodes.count - 1 {
                guard loaded.node == anchor.proof, predecessor == anchor.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
        }
        guard predecessor == view.tip, view.latestInstalled else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if let pending = pairPendingWitness {
            guard !expectedNames.contains(pending.name), view.refs.count == anchor.nodes.count,
                pending.method == anchor.issuedMethod else { throw NativeEnrollmentJournalError.outcomeUncertain }
            let limit = ordinaryPhaseCommand?.phase == 0 ? NativeJournalCodec.attemptLimit : NativeJournalCodec.phaseAttemptLimit
            let published = try readFile(d.attempts, pending.name, limit: limit)
            let staged = try readFile(d.attempts, pending.name + ".pending", limit: limit)
            if let method = pending.method {
                guard let command = ordinaryPhaseCommand else { throw NativeEnrollmentJournalError.outcomeUncertain }
                guard (published == nil) != (staged == nil), (published ?? staged) == method else { throw NativeEnrollmentJournalError.outcomeUncertain }
                guard let a = anchor.issuedAttempt else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let witness = try NativeJournalCodec.attemptWitness(method.bytes)
                // Full actual method bytes equal our privately captured encoding;
                // the raw-span parser still freshly validates canonical fields/base64.
                guard witness.schemaVersion == a.schemaVersion, witness.cloudRootID == a.cloudRootID,
                    witness.preparationID == a.preparationID, witness.attemptID == a.attemptID,
                    witness.index == a.index, witness.method == a.method, witness.rootBindingIdentity == a.rootBindingIdentity,
                    witness.ownIdentity == a.ownIdentity, witness.predecessor == a.predecessor,
                    witness.candidateIdentity == a.candidateIdentity, witness.targetPayload == a.targetPayload,
                    witness.reservation == a.reservation, witness.decodedIntentBytes == a.intentPayload?.count else { throw NativeEnrollmentJournalError.conflict }
                try validateIssuedOrdinaryPhase(a, command: command, anchor: anchor, view: view)
                let committed = try readFile(d.frames, pending.name, limit: NativeJournalCodec.frameLimit)
                let candidate = try readFile(d.frames, pending.name + ".pending", limit: NativeJournalCodec.frameLimit)
                guard (committed == nil) != (candidate == nil), let actual = committed ?? candidate,
                    actual.identity == pending.candidateIdentity, a.candidateIdentity == pending.candidateIdentity,
                    (committed != nil ? actual.bytes == a.targetPayload : a.targetPayload.starts(with: actual.bytes)) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            } else {
                guard published == nil, staged == nil,
                    try readFile(d.frames, pending.name, limit: NativeJournalCodec.frameLimit) == nil,
                    try readFile(d.frames, pending.name + ".pending", limit: NativeJournalCodec.frameLimit) == NativeJournalNode(identity: pending.candidateIdentity, bytes: Data()) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
        } else {
            guard actualAttempts == expectedNames, actualFrames == expectedNames else { throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        guard anchor.expectedEpoch == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
    }
    private func requireOrdinaryImmutableProjection(_ x: NativePreparationReconstructionStep, _ y: NativePreparationReconstructionStep) throws {
        let a = x.proposal, b = y.proposal
        guard a.preparationId == b.preparationId, a.enrollmentId == b.enrollmentId,
            a.stageReference.utf8.elementsEqual(b.stageReference.utf8),
            try nativeEnrollmentBytes(a.binding) == nativeEnrollmentBytes(b.binding),
            try nativeEnrollmentBytes(a.claimInput) == nativeEnrollmentBytes(b.claimInput), a.reservedBytes == b.reservedBytes,
            try nativeEnrollmentBytes(a.source) == nativeEnrollmentBytes(b.source),
            try nativeEnrollmentBytes(a.targetHistory) == nativeEnrollmentBytes(b.targetHistory),
            try nativeEnrollmentBytes(a.sourceEnrollment) == nativeEnrollmentBytes(b.sourceEnrollment),
            try nativeEnrollmentBytes(a.targetEnrollment) == nativeEnrollmentBytes(b.targetEnrollment),
            try nativeEnrollmentBytes(x.priorDeclarations) == nativeEnrollmentBytes(y.priorDeclarations) else { throw NativeEnrollmentJournalError.conflict }
    }
    private func validateIssuedOrdinaryPhase(_ attempt: NativeJournalAttempt, command: OrdinaryPhaseCommand,
        anchor: OrdinaryPhaseAnchor, view: Scan) throws {
        let frame = try NativeJournalCodec.frame(attempt.targetPayload)
        guard attempt.preparationID == command.preparationID, attempt.attemptID == command.attemptID,
            attempt.index == view.refs.count + 1, attempt.predecessor == anchor.tip,
            attempt.rootBindingIdentity == anchor.binding.identity, attempt.cloudRootID == cloudRootID,
            frame.stageOwnership == nil, frame.pairedEvidence == nil, frame.phase == command.phase,
            frame.cloudRootID == cloudRootID, frame.preparationID == command.preparationID,
            frame.attemptID == command.attemptID, frame.index == attempt.index else { throw NativeEnrollmentJournalError.conflict }
        if command.phase == 0 {
            guard let input = command.intent, let step = command.step, step.proposal.phase == .intent,
                step.proposal.preparationId == command.preparationID,
                ordinaryPreparationRequest?.bytes == input, ordinaryPreparationRequest?.attemptID == command.attemptID,
                view.unfinishedIntent == nil, view.preparationCount < 64,
                !view.refs.contains(where: { $0.preparationID == command.preparationID || $0.attemptID == command.attemptID }),
                attempt.method == .prepareIntent, attempt.intentPayload == input,
                command.reservation == (try NativeJournalCodec.reservation(intentBytes: input.count)),
                attempt.reservation == command.reservation,
                view.reservedBytes + command.reservation <= NativeJournalCodec.totalReservationLimit,
                frame.intentAttemptID == command.attemptID else { throw NativeEnrollmentJournalError.conflict }
        } else {
            guard let prior = view.refs.last, let originalTip = anchor.tip, let originalProof = anchor.proof else { throw NativeEnrollmentJournalError.outcomeUncertain }
            let originalFrame = try NativeJournalCodec.frame(originalTip.bytes)
            guard (1...6).contains(command.phase), command.phase == prior.phase + 1,
                prior.preparationID == command.preparationID, view.unfinishedIntent != nil,
                !(view.paired.initialization != nil && command.phase == 3),
                attempt.method == .appendPhaseAssertion, command.intent == nil, attempt.intentPayload == nil,
                command.reservation == 0, attempt.reservation == 0, frame.intentAttemptID == originalFrame.intentAttemptID,
                try NativeJournalCodec.attemptWitness(originalProof.bytes).attemptID == prior.attemptID else { throw NativeEnrollmentJournalError.conflict }
            if command.phase == 6 {
                guard let step = command.step, let admitted = ordinaryAdmissionStep,
                    admitted.proposal.phase == .promotionQualified, step.proposal.phase == .complete,
                    step.proposal.preparationId == command.preparationID, step.continuation != nil else { throw NativeEnrollmentJournalError.invalidRecord }
                // Exact immutable typed fields were compared once before effects;
                // these privately held value projections cannot be renewed by readback.
            } else { guard command.step == nil else { throw NativeEnrollmentJournalError.conflict } }
        }
    }
    private func extendOrdinaryPhaseView(_ d: Disk, ref: Ref, attempt: NativeJournalAttempt) throws {
        guard let command = ordinaryPhaseCommand, let anchor = ordinaryPhaseAnchor, let old = pairScanView,
            anchor.expectedEpoch == epoch(), anchor.expectedEpoch == anchor.originalEpoch &+ 1,
            old.refs.count == anchor.nodes.count, ref.index == old.refs.count + 1,
            anchor.issuedMethod == NativeJournalNode(identity: ref.identity, bytes: try NativeJournalCodec.encode(attempt)),
            attempt.ownIdentity == ref.identity else { throw NativeEnrollmentJournalError.outcomeUncertain }
        try validateIssuedOrdinaryPhase(attempt, command: command, anchor: anchor, view: old)
        let tip = NativeJournalNode(identity: attempt.candidateIdentity, bytes: attempt.targetPayload)
        var context = old.context, intent = old.unfinishedIntent, count = old.preparationCount, reserved = old.reservedBytes, paired = old.paired
        var firstNativePreparationIDs = old.firstNativePreparationIDs
        if command.phase == 0 {
            if let step = command.step, step.proposal.source.isFirstNative { firstNativePreparationIDs.insert(command.preparationID) }
            intent = command.intent; count += 1; reserved += command.reservation; paired.newPreparation()
        } else if command.phase == 6 {
            guard let step = command.step else { throw NativeEnrollmentJournalError.invalidRecord }
            context = try requireContinuation(step); intent = nil
        }
        pairScanView = .init(refs: old.refs + [ref], tip: tip, latestInstalled: true,
            preparationCount: count, reservedBytes: reserved, context: context, firstNativePreparationIDs: firstNativePreparationIDs,
            unfinishedIntent: intent, stageOwnerships: old.stageOwnerships, paired: paired)
        pairFrameIdentities.append(attempt.candidateIdentity); pairPendingWitness = nil
        try check(d)
    }
    private func checkPairWitnesses(_ d: Disk, view: Scan) throws {
        guard let original = pairPrivateAttempt, original.issuer == ObjectIdentifier(self),
            original.generation == epoch(), original.original.binding == d.binding,
            view.refs.count == pairFrameIdentities.count,
            view.refs.count <= NativeJournalCodec.nodeLimit else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let expectedNames = Set(view.refs.map(\.name))
        var extra = pairPendingWitness.map { Set([$0.name, $0.name + ".pending"]) } ?? Set<String>()
        if !view.latestInstalled, let last = view.refs.last { extra.insert(last.name + ".pending") }
        let actualAttempts = Set(try names(d.attempts)), actualFrames = Set(try names(d.frames))
        guard actualAttempts.isSubset(of: expectedNames.union(extra)), actualFrames.isSubset(of: expectedNames.union(extra)) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        var predecessor: NativeJournalNode?
        for (offset, ref) in view.refs.enumerated() {
            let loaded = try loadAttemptWitness(d, ref), a = loaded.value
            let committed = try readFile(d.frames, ref.name, limit: NativeJournalCodec.frameLimit)
            let pending = try readFile(d.frames, ref.name + ".pending", limit: NativeJournalCodec.frameLimit)
            guard actualAttempts.contains(ref.name), !actualAttempts.contains(ref.name + ".pending"),
                a.index == offset + 1, a.cloudRootID == cloudRootID, a.preparationID == ref.preparationID,
                a.rootBindingIdentity == d.binding?.identity, a.predecessor == predecessor,
                a.candidateIdentity == pairFrameIdentities[offset], (committed == nil) != (pending == nil) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            if let committed {
                guard committed.identity == a.candidateIdentity, committed.bytes == a.targetPayload else { throw NativeEnrollmentJournalError.conflict }
                predecessor = committed
            } else {
                guard offset == view.refs.count - 1, !view.latestInstalled, let pending,
                    pending.identity == a.candidateIdentity, a.targetPayload.starts(with: pending.bytes) else { throw NativeEnrollmentJournalError.outcomeUncertain }
                predecessor = pending
            }
            if offset < original.nodes.count {
                guard original.nodes[offset].ref == ref, original.nodes[offset].frameIdentity == a.candidateIdentity else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
            if offset == original.nodes.count - 1 {
                guard loaded.node == original.proof, predecessor == original.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
            if offset == view.refs.count - 1 {
                guard predecessor == view.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
                if view.refs.count == original.nodes.count { guard loaded.node == original.proof, view.tip == original.tip else { throw NativeEnrollmentJournalError.outcomeUncertain } }
            }
        }
        if let pending = pairPendingWitness {
            guard !expectedNames.contains(pending.name) else { throw NativeEnrollmentJournalError.conflict }
            let published = try readFile(d.attempts, pending.name, limit: NativeJournalCodec.phaseAttemptLimit)
            let staged = try readFile(d.attempts, pending.name + ".pending", limit: NativeJournalCodec.phaseAttemptLimit)
            if let captured = pending.method {
                guard (published == nil) != (staged == nil), (published ?? staged) == captured else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let a = try NativeJournalCodec.attempt(captured.bytes)
                guard a.predecessor == view.tip, a.index == view.refs.count + 1,
                    a.candidateIdentity == pending.candidateIdentity, a.ownIdentity == captured.identity,
                    a.rootBindingIdentity == d.binding?.identity, a.cloudRootID == cloudRootID,
                    a.method == .pairedEvidence, original.ids.values.contains(a.attemptID) else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let committed = try readFile(d.frames, pending.name, limit: NativeJournalCodec.frameLimit)
                let candidate = try readFile(d.frames, pending.name + ".pending", limit: NativeJournalCodec.frameLimit)
                guard (committed == nil) != (candidate == nil), let actual = committed ?? candidate,
                    actual.identity == pending.candidateIdentity,
                    (committed != nil ? actual.bytes == a.targetPayload : a.targetPayload.starts(with: actual.bytes)) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            } else {
                guard published == nil, staged == nil,
                    try readFile(d.frames, pending.name, limit: NativeJournalCodec.frameLimit) == nil,
                    try readFile(d.frames, pending.name + ".pending", limit: NativeJournalCodec.frameLimit) == NativeJournalNode(identity: pending.candidateIdentity, bytes: Data()) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
        } else {
            guard actualAttempts == expectedNames else { throw NativeEnrollmentJournalError.outcomeUncertain }
            if view.latestInstalled { guard actualFrames == expectedNames else { throw NativeEnrollmentJournalError.outcomeUncertain } }
            else {
                guard let last = view.refs.last, original.ids.values.contains(last.attemptID) else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let pendingNames = expectedNames.subtracting([last.name]).union([last.name + ".pending"])
                // The fixed recommit may have renamed its exact candidate but
                // has not yet acknowledged synchronization/qualified the view.
                guard actualFrames == pendingNames || actualFrames == expectedNames else { throw NativeEnrollmentJournalError.outcomeUncertain }
            }
        }
        guard original.generation == epoch() else { throw NativeEnrollmentJournalError.outcomeUncertain }
    }
    /// Only an issued fixed command can append the single already bounded role.
    /// No arbitrary scan/readback renews the original checkpoint.
    private func extendPairView(_ d: Disk, ref: Ref, attempt: NativeJournalAttempt, installed: Bool) throws {
        guard let old = pairScanView, let original = pairPrivateAttempt,
            original.generation == epoch(), ref.index == old.refs.count + 1,
            original.ids.values.contains(ref.attemptID), attempt.predecessor == old.tip,
            let prior = old.refs.last else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let f = try NativeJournalCodec.frame(attempt.targetPayload)
        guard let assertion = f.pairedEvidence, attempt.method == .pairedEvidence,
            attempt.preparationID == prior.preparationID, attempt.ownIdentity == ref.identity,
            attempt.cloudRootID == cloudRootID, attempt.rootBindingIdentity == d.binding?.identity,
            attempt.attemptID == ref.attemptID, attempt.index == ref.index,
            f.cloudRootID == cloudRootID, f.preparationID == ref.preparationID,
            f.attemptID == ref.attemptID, f.index == ref.index, f.phase == ref.phase,
            f.intentAttemptID == (try NativeJournalCodec.frame(original.original.tip.bytes)).intentAttemptID else { throw NativeEnrollmentJournalError.conflict }
        var replay = old.paired
        try replay.accept(assertion, frame: f, attempt: attempt, previousPhase: prior.phase,
            previousAttemptID: prior.attemptID, previousIdentity: prior.identity)
        let tip: NativeJournalNode
        if installed { tip = .init(identity: attempt.candidateIdentity, bytes: attempt.targetPayload) }
        else {
            guard let pending = try readFile(d.frames, ref.name + ".pending", limit: NativeJournalCodec.frameLimit),
                pending.identity == attempt.candidateIdentity, attempt.targetPayload.starts(with: pending.bytes) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            tip = pending
        }
        pairScanView = .init(refs: old.refs + [ref], tip: tip, latestInstalled: installed,
            preparationCount: old.preparationCount, reservedBytes: old.reservedBytes, context: old.context, firstNativePreparationIDs: old.firstNativePreparationIDs,
            unfinishedIntent: old.unfinishedIntent, stageOwnerships: old.stageOwnerships, paired: replay)
        pairFrameIdentities.append(attempt.candidateIdentity); pairPendingWitness = nil
        try check(d)
    }
    private func checkPairNamespace(_ d: Disk, replay: NativePairReplay? = nil) throws {
        guard let binding = d.binding else { throw NativeEnrollmentJournalError.unsafeRoot }
        var reserve: NativeJournalPairAssertion?, pairRoot: NativeJournalPairRoot?, lastPair: NativeJournalPairAssertion?
        if let replay {
            reserve = replay.reservation
            pairRoot = replay.initialization?.root
            lastPair = replay.lastAssertion
        } else {
        for name in try names(d.attempts).sorted() where !name.hasSuffix(".pending") {
            let f: NativeJournalFrame
            if let installed = try readFile(d.frames, name, limit: NativeJournalCodec.frameLimit) {
                f = try NativeJournalCodec.frame(installed.bytes)
            } else {
                guard let node = try readFile(d.attempts, name, limit: NativeJournalCodec.attemptLimit) else { throw NativeEnrollmentJournalError.conflict }
                f = try NativeJournalCodec.frame(NativeJournalCodec.attempt(node.bytes).targetPayload)
            }
            if let pair = f.pairedEvidence {
                guard let node = try readFile(d.attempts, name, limit: NativeJournalCodec.phaseAttemptLimit) else { throw NativeEnrollmentJournalError.conflict }
                let a = try NativeJournalCodec.attempt(node.bytes)
                guard a.targetPayload == (try NativeJournalCodec.encode(f)), a.cloudRootID == cloudRootID, a.rootBindingIdentity == binding.identity, a.ownIdentity == node.identity else { throw NativeEnrollmentJournalError.conflict }
                if pair.role == .initReserve { reserve = pair }
                if pair.role == .initBind { pairRoot = pair.root }
                lastPair = pair
            }
        }
        }
        let existingDirectory = try readPairDirectoryIdentity(d.root)
        if reserve == nil { guard existingDirectory == nil else { throw NativeEnrollmentJournalError.outcomeUncertain }; return }
        guard reserve?.workspaceReservation == NativeJournalCodec.pairedReservationLimit else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if existingDirectory == nil { guard pairRoot == nil, lastPair?.role == .initReserve else { throw NativeEnrollmentJournalError.outcomeUncertain }; return }
        if pairRoot == nil { pairRoot = pairPrivateRoot }
        guard let pairRoot else { throw NativeEnrollmentJournalError.outcomeUncertain }
        try NativePairFiles.withRoot(d.root, root: pairRoot, cloudRootID: cloudRootID, journalBinding: binding.identity, allowEmptyBinding: lastPair?.role == .initBind || pairPrivateRoot != nil) { fd in
            let names = try NativePairFiles.names(fd)
            if let pair = lastPair, [.sourceReserve, .targetReserve].contains(pair.role) {
                let target = pair.role == .targetReserve
                let h = try NativePairFiles.read(fd, target ? NativePairFiles.targetHistory : NativePairFiles.sourceHistory, limit: 65536)
                let e = try NativePairFiles.read(fd, target ? NativePairFiles.targetEnrollment : NativePairFiles.sourceEnrollment, limit: 1048576)
                if h != nil || e != nil {
                    guard let owned = pairPrivateFiles, h == NativeJournalNode(identity: owned.history, bytes: Data()), e == NativeJournalNode(identity: owned.enrollment, bytes: Data()) else { throw NativeEnrollmentJournalError.outcomeUncertain }
                }
            }
            guard let pair = lastPair else { throw NativeEnrollmentJournalError.outcomeUncertain }
            let ordinary: Set<String> = ["pair.lock", "pair-binding.json", "pair-binding.json.pending", NativePairFiles.historyName, NativePairFiles.enrollmentName]
            let target = [.targetReserve, .targetBind, .targetComplete].contains(pair.role)
            let candidateNames: Set<String> = target ? [NativePairFiles.targetHistory, NativePairFiles.targetEnrollment] : [NativePairFiles.sourceHistory, NativePairFiles.sourceEnrollment]
            let permitsCandidates = [.sourceBind, .targetBind].contains(pair.role) || (pairPrivateFiles != nil && [.sourceReserve, .targetReserve].contains(pair.role))
            guard names.isSubset(of: permitsCandidates ? ordinary.union(candidateNames) : ordinary) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            switch pair.role {
            case .initReserve, .initBind, .initComplete:
                guard !names.contains(NativePairFiles.historyName), !names.contains(NativePairFiles.enrollmentName) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            case .sourceReserve, .targetReserve:
                try NativePairFiles.current(fd, files: pair.baseline?.files, payload: try pair.baseline.map { try pairPayload(d, projection: $0.projection) })
            case .sourceBind, .targetBind:
                guard let candidates = pair.candidates else { throw NativeEnrollmentJournalError.conflict }
                try NativePairFiles.verifyTransition(fd, candidates: candidates, target: target, payload: pairPayload(d, projection: pair.projection), baseline: pair.baseline, baselinePayload: try pair.baseline.map { try pairPayload(d, projection: $0.projection) })
            case .sourceComplete, .targetComplete:
                try NativePairFiles.current(fd, files: pair.candidates, payload: pairPayload(d, projection: pair.projection))
            }
        }
    }
}
