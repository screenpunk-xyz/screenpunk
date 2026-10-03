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
    private struct Ref: Equatable {
        let name: String, attemptID: UUID, preparationID: UUID
        let index: Int, phase: Int
        let identity: NativeJournalIdentity
    }
    private struct Scan {
        let refs: [Ref]
        let tip: NativeJournalNode?
        let latestInstalled: Bool
        let preparationCount: Int, reservedBytes: Int
        let context: NativePreparationReconstructionContext
        let unfinishedIntent: Data?
    }
    private struct Disk {
        let root: Int32, lock: Int32, attempts: Int32, frames: Int32
        let directory: NativeJournalIdentity, lockIdentity: NativeJournalIdentity
        let attemptsIdentity: NativeJournalIdentity, framesIdentity: NativeJournalIdentity
        let binding: NativeJournalNode?
    }
    private struct Qualification {
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
        guard encodedRecord.count <= NativeEnrollmentPreparationCodec.maximumBytes else { throw NativeEnrollmentJournalError.capacity }
        return try disk { d in
            let state = try scan(d)
            // Existing attempts are exact replay, never existence acknowledgments.
            if let ref = state.refs.first(where: { $0.attemptID == attemptID }) {
                let a = try loadAttempt(d, ref).value
                guard a.method == .prepareIntent, a.intentPayload == encodedRecord else { throw NativeEnrollmentJournalError.conflict }
                return try recommit(d, state: state, ref: ref)
            }
            guard state.unfinishedIntent == nil, state.preparationCount < NativeJournalCodec.preparationLimit else { throw NativeEnrollmentJournalError.capacity }
            try requireQualification(d, state)
            let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(encodedRecord, context: state.context)
            guard step.proposal.phase == .intent, !state.refs.contains(where: { $0.preparationID == step.proposal.preparationId }) else { throw NativeEnrollmentJournalError.conflict }
            let intent = encodedRecord
            let reservation = try NativeJournalCodec.reservation(intentBytes: intent.count)
            guard state.reservedBytes + reservation <= NativeJournalCodec.totalReservationLimit else { throw NativeEnrollmentJournalError.capacity }
            return try install(d, state: state, attemptID: attemptID, preparationID: step.proposal.preparationId,
                phase: 0, intentAttemptID: attemptID, intent: intent, reservation: reservation)
        }
    }
    func appendPhaseAssertion(preparationID: UUID, next: NativeEnrollmentPreparation.Phase,
                              attemptID: UUID) throws -> LocalDurabilityReceipt {
        try disk { d in
            let state = try scan(d)
            if let existing = state.refs.first(where: { $0.attemptID == attemptID }) {
                guard existing.preparationID == preparationID, existing.phase == next.rawValue,
                    next != .intent else { throw NativeEnrollmentJournalError.conflict }
                return try recommit(d, state: state, ref: existing)
            }
            guard let previous = state.refs.last, previous.preparationID == preparationID,
                previous.phase + 1 == next.rawValue, state.unfinishedIntent != nil else { throw NativeEnrollmentJournalError.conflict }
            try requireQualification(d, state)
            let prior = try NativeJournalCodec.frame(try loadAttempt(d, previous).value.targetPayload)
            return try install(d, state: state, attemptID: attemptID, preparationID: preparationID,
                phase: next.rawValue, intentAttemptID: prior.intentAttemptID, intent: nil, reservation: 0)
        }
    }
    private struct DiagnosticSnapshot {
        let refs: [Ref] // At most 448 compact declarations, never proposal snapshots.
        let binding: NativeJournalNode?
        let tip: NativeJournalNode?
        let installed: Bool
        let epoch: UInt64
        let count: Int
    }
    /// Delivers one historical, nonqualifying proposal at a time outside all locks.
    /// Each replay validates the captured chain; callback mutations invalidate the
    /// remaining stream, including a mutation after its final delivery. No inventory
    /// is manufactured, and read-only diagnosis does not alter tip qualification.
    func diagnose(_ visit: (Diagnostic) throws -> Void) throws {
        let captured = try disk { d in
            let generation = epoch(), state = try scan(d)
            guard epoch() == generation else { throw NativeEnrollmentJournalError.outcomeUncertain }
            return DiagnosticSnapshot(refs: state.refs, binding: d.binding, tip: state.tip,
                installed: state.latestInstalled, epoch: generation, count: state.preparationCount)
        }
        for selected in 0..<captured.count {
            guard let value = try diagnosticReplay(captured, selected: selected) else { throw NativeEnrollmentJournalError.outcomeUncertain }
            try visit(value) // disk has returned: mutex and root flock are released.
        }
        _ = try diagnosticReplay(captured, selected: nil)
    }
    private func diagnosticReplay(_ captured: DiagnosticSnapshot, selected: Int?) throws -> Diagnostic? {
        do {
            return try disk { d in
                guard epoch() == captured.epoch, d.binding == captured.binding else { throw NativeEnrollmentJournalError.outcomeUncertain }
                let state = try scan(d)
                guard epoch() == captured.epoch, state.refs == captured.refs,
                    state.tip == captured.tip, state.latestInstalled == captured.installed,
                    state.preparationCount == captured.count else { throw NativeEnrollmentJournalError.outcomeUncertain }
                guard let selected else { return nil }
                // The complete chain was checked under this same root lock. Stop
                // the second replay at the selected value so later proposals never
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
    private func requireQualification(_ d: Disk, _ state: Scan) throws {
        guard state.latestInstalled, let qualified = qualification, qualified.epoch == epoch(),
            qualified.binding == d.binding, qualified.tip == state.tip else { throw NativeEnrollmentJournalError.outcomeUncertain }
        if let ref = state.refs.last {
            guard try loadAttempt(d, ref).node == qualified.proof else { throw NativeEnrollmentJournalError.outcomeUncertain }
        } else { guard qualified.proof == nil else { throw NativeEnrollmentJournalError.outcomeUncertain } }
    }
    private func filename(_ index: Int, _ id: UUID) -> String { String(format: "%04d", index) + "-" + id.uuidString.lowercased() + ".json" }
    private func install(_ d: Disk, state: Scan, attemptID: UUID, preparationID: UUID,
                         phase: Int, intentAttemptID: UUID, intent: Data?, reservation: Int) throws -> LocalDurabilityReceipt {
        guard !state.refs.contains(where: { $0.attemptID == attemptID }), let binding = d.binding else { throw NativeEnrollmentJournalError.conflict }
        let generation = beginAttempt(), index = state.refs.count + 1, name = filename(state.refs.count + 1, attemptID)
        let candidateFD = try create(d.frames, name + ".pending"); defer { close(candidateFD) }
        let candidateIdentity = try identity(candidateFD, directory: false)
        try event(.candidate, .created)
        // Preserve the captured empty inode before any attempt can durably bind it.
        try sync(candidateFD); try sync(d.frames); try check(d)
        let frame = NativeJournalFrame(schemaVersion: 1, cloudRootID: cloudRootID, preparationID: preparationID,
            attemptID: attemptID, intentAttemptID: intentAttemptID, index: index, phase: phase)
        let target = try NativeJournalCodec.encode(frame)
        let attemptFD = try create(d.attempts, name + ".pending"); defer { close(attemptFD) }
        let attemptIdentity = try identity(attemptFD, directory: false)
        let attempt = NativeJournalAttempt(schemaVersion: 1, cloudRootID: cloudRootID, preparationID: preparationID, attemptID: attemptID,
            index: index, method: phase == 0 ? .prepareIntent : .appendPhaseAssertion,
            rootBindingIdentity: binding.identity, ownIdentity: attemptIdentity, predecessor: state.tip,
            candidateIdentity: candidateIdentity, targetPayload: target, intentPayload: intent, reservation: reservation)
        let bytes = try NativeJournalCodec.encode(attempt)
        guard bytes.count <= (phase == 0 ? NativeJournalCodec.attemptLimit : NativeJournalCodec.phaseAttemptLimit), target.count <= NativeJournalCodec.frameLimit else { throw NativeEnrollmentJournalError.capacity }
        try event(.attempt, .created); try writeExact(attemptFD, bytes); try event(.attempt, .written)
        try sync(attemptFD); try event(.attempt, .fileSynced)
        try publish(d, parent: d.attempts, temporary: name + ".pending", name: name, kind: .attempt, expected: attemptIdentity)
        // The captured candidate inode is now bound by the exact synchronized
        // attempt record. Its bytes are not authoritative until recommitted.
        try writeExact(candidateFD, target); try event(.candidate, .written)
        try sync(candidateFD); try event(.candidate, .fileSynced)
        try publish(d, parent: d.frames, temporary: name + ".pending", name: name, kind: .candidate, expected: candidateIdentity)
        let ref = Ref(name: name, attemptID: attemptID, preparationID: preparationID, index: index, phase: phase, identity: attemptIdentity)
        return try qualify(d, ref: ref, generation: generation)
    }
    private func recommit(_ d: Disk, state: Scan, ref: Ref) throws -> LocalDurabilityReceipt {
        let generation = beginAttempt(), loaded = try loadAttempt(d, ref)
        try syncExisting(d.attempts, ref.name, expected: loaded.node, limit: NativeJournalCodec.attemptLimit)
        try event(.attempt, .fileSynced); try sync(d.attempts); try event(.attempt, .directorySynced); try check(d)
        if !state.latestInstalled && ref.index == state.refs.count {
            let name = ref.name + ".pending"
            let fd = openat(d.frames, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            guard try identity(fd, directory: false) == loaded.value.candidateIdentity else { throw NativeEnrollmentJournalError.conflict }
            try writeExact(fd, loaded.value.targetPayload); try event(.candidate, .written)
            try sync(fd); try event(.candidate, .fileSynced)
            try publish(d, parent: d.frames, temporary: name, name: ref.name, kind: .candidate, expected: loaded.value.candidateIdentity)
        }
        if ref.index == state.refs.count { return try qualify(d, ref: ref, generation: generation) }
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
            let a = try loadAttempt(d, item)
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
    private func loadAttempt(_ d: Disk, _ ref: Ref) throws -> (node: NativeJournalNode, value: NativeJournalAttempt) {
        guard let node = try readFile(d.attempts, ref.name, limit: NativeJournalCodec.attemptLimit), node.identity == ref.identity else { throw NativeEnrollmentJournalError.conflict }
        let value = try NativeJournalCodec.attempt(node.bytes)
        guard value.ownIdentity == node.identity, value.attemptID == ref.attemptID else { throw NativeEnrollmentJournalError.conflict }; return (node, value)
    }
    private func scan(_ d: Disk, visit: (Diagnostic) throws -> Void = { _ in }) throws -> Scan {
        guard let binding = d.binding else { throw NativeEnrollmentJournalError.unsafeRoot }
        let attemptNames = try names(d.attempts).sorted(), frameNames = Set(try names(d.frames))
        guard attemptNames.allSatisfy({ !$0.hasSuffix(".pending") }), attemptNames.count <= 448 else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let boundNames = Set(attemptNames.flatMap { [$0, $0 + ".pending"] })
        guard frameNames.isSubset(of: boundNames) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        var usedFrames = Set<String>(), refs: [Ref] = [], tip: NativeJournalNode?
        var context = NativePreparationReconstructionContext.empty(), intent: Data?, intentAttemptID: UUID?
        var preparationID: UUID?, phase = -1, count = 0, reserved = 0, installed = true
        for (offset, name) in attemptNames.enumerated() {
            guard let node = try readFile(d.attempts, name, limit: NativeJournalCodec.attemptLimit) else { throw NativeEnrollmentJournalError.conflict }
            let a = try NativeJournalCodec.attempt(node.bytes), f = try NativeJournalCodec.frame(a.targetPayload)
            guard name == filename(offset + 1, a.attemptID), a.index == offset + 1,
                a.cloudRootID == cloudRootID, a.rootBindingIdentity == binding.identity, a.ownIdentity == node.identity,
                a.predecessor == tip, f.cloudRootID == cloudRootID, f.preparationID == a.preparationID,
                f.attemptID == a.attemptID, f.index == a.index,
                !refs.contains(where: { $0.attemptID == a.attemptID }) else { throw NativeEnrollmentJournalError.conflict }
            if a.method == .prepareIntent {
                guard intent == nil, f.phase == 0, f.intentAttemptID == a.attemptID,
                    !refs.contains(where: { $0.preparationID == a.preparationID }), let initial = a.intentPayload else { throw NativeEnrollmentJournalError.conflict }
                let step = try NativeEnrollmentPreparationCodec.decodeReconstructionProposal(initial, context: context)
                guard step.proposal.phase == .intent, step.proposal.preparationId == a.preparationID else { throw NativeEnrollmentJournalError.invalidRecord }
                intent = initial; intentAttemptID = a.attemptID; preparationID = a.preparationID
                count += 1; reserved += a.reservation
                guard count <= 64, reserved <= NativeJournalCodec.totalReservationLimit else { throw NativeEnrollmentJournalError.capacity }
            } else {
                guard intent != nil, a.preparationID == preparationID, f.phase == phase + 1,
                    f.intentAttemptID == intentAttemptID else { throw NativeEnrollmentJournalError.conflict }
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
                try visit(.init(attemptID: a.attemptID, candidateInstalled: installed, step: step))
                if phase == 6 && installed {
                    context = try requireContinuation(step); intent = nil; intentAttemptID = nil; preparationID = nil
                }
            }
        }
        guard usedFrames == frameNames else { throw NativeEnrollmentJournalError.outcomeUncertain }
        try check(d)
        return .init(refs: refs, tip: tip, latestInstalled: installed, preparationCount: count, reservedBytes: reserved, context: context, unfinishedIntent: intent)
    }
    private func requireContinuation(_ step: NativePreparationReconstructionStep) throws -> NativePreparationReconstructionContext {
        guard let continuation = step.continuation else { throw NativeEnrollmentJournalError.invalidRecord }; return continuation
    }
    private func disk<T>(create: Bool = false, _ operation: (Disk) throws -> T) throws -> T {
        guard mutex.try() else { throw NativeEnrollmentJournalError.outcomeUncertain }; defer { mutex.unlock() }
        let path = root.path, excluded = excludedLocalResetRoot.path
        guard path.utf8.count <= 4096, excluded.utf8.count <= 4096,
            path.utf8.elementsEqual(root.resolvingSymlinksInPath().path.utf8),
            excluded.utf8.elementsEqual(excludedLocalResetRoot.resolvingSymlinksInPath().path.utf8),
            path != excluded, !path.hasPrefix(excluded + "/"), !excluded.hasPrefix(path + "/") else { throw NativeEnrollmentJournalError.unsafeRoot }
        let rootFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard rootFD >= 0 else { throw failure() }; defer { close(rootFD) }
        let directory = try identity(rootFD, directory: true)
        let rootNames = Set(try names(rootFD)), allowed: Set<String> = ["journal.lock", "attempts", "frames", "root-binding.json"]
        guard rootNames.isSubset(of: allowed) else { throw NativeEnrollmentJournalError.outcomeUncertain }
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
            attemptsIdentity: try identity(attemptsFD, directory: true), framesIdentity: try identity(framesFD, directory: true), binding: binding)
        try check(d); return try operation(d)
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
        let allowed: Set<String> = ["journal.lock", "attempts", "frames", "root-binding.json", "root-binding.json.pending"]
        guard names.isSubset(of: allowed), d.binding == nil || !names.contains("root-binding.json.pending") else { throw NativeEnrollmentJournalError.outcomeUncertain }
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
    private func event(_ kind: Kind, _ point: Point) throws { try boundary(.init(kind: kind, point: point)) }
    private func failure() -> NativeEnrollmentJournalError { .io(errno) }
}
