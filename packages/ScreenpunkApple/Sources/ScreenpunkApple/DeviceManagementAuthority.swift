import Foundation
import ScreenpunkCore

/// In-process authority only. External filesystem/Keychain writers are not excluded.
/// Only internal Local reset bookkeeping writes are provided. Production Cloud writers remain
/// disabled until owner-mediated exact uncertain-write recovery is implemented.
/// All future management callers must share this owner and acquire it before their
/// server lock. Do not wait for asynchronous callbacks from a gated operation.
public final class DeviceManagementAuthority: @unchecked Sendable {
    public struct Lease: Sendable {
        fileprivate let owner: UUID
        fileprivate let generation: UUID
    }
    public enum Failure: Error, Equatable {
        case staleLease, reentrantOperation, resetConflict, noResetAttempt
    }
    private let lock = NSRecursiveLock()
    private let identity = UUID()
    private var generation = UUID()
    private struct Evidence: Equatable {
        let history: DeviceManagementTransitionHistory?
        let references: Set<String>
        let reset: DeviceLocalResetRecord?
    }
    private var quarantined = false
    private var observedHistory: DeviceManagementTransitionHistory?
    private var evidence: Evidence?
    private var permitted = false
    private var executing = false
    private var invalidationObservers: [UUID: () -> Void] = [:]
    private var invalidationActions: [() -> Void] = []
    private let reset: any DeviceLocalResetEvidence
    private struct ResetAttempt { let record: DeviceLocalResetRecord; let beginsNew: Bool }
    private var resetAttempt: ResetAttempt?
    private var resetQuarantined = false
    private var observedReset: DeviceLocalResetRecord?
    private let journal: any CloudInstallationTransitionJournal
    private let credentials: CloudInstallationCredentialStore

    public init(journal: any CloudInstallationTransitionJournal, credentials: CloudInstallationCredentialStore, reset: any DeviceLocalResetEvidence = DeviceLocalResetEvidenceAdapter.production()) {
        self.journal = journal
        self.credentials = credentials
        self.reset = reset
    }

    /// Starts blocked and revokes previous leases even when classification fails.
    public func refresh() throws -> Lease? {
        try serialized {
            invalidate()
            guard let current = verifiedEvidence() else { return nil }
            evidence = current
            permitted = true
            return Lease(owner: identity, generation: generation)
        }
    }

    public func revoke() throws {
        try serialized { invalidate() }
    }

    /// Keep the operation short and synchronous. It may not return an escaping
    /// authority capability, schedule management work, or call this owner again.
    /// Listener setup and request commit must each validate their lease separately.
    public func withLocalAuthority(_ lease: Lease, operation: () throws -> Void) throws {
        try serialized {
            guard permitted, lease.owner == identity, lease.generation == generation else { throw Failure.staleLease }
            guard let current = verifiedEvidence() else {
                invalidate()
                throw Failure.staleLease
            }
            guard current == evidence else {
                quarantined = true
                invalidate()
                throw Failure.staleLease
            }
            try operation()
        }
    }

    // Future in-process transition writes must route through this owner after exact
    // uncertain-write recovery is implemented. This slice exposes no Cloud write API. Fresh entry
    // checks detect external changes, but do not exclude external TOCTOU writers.
    private func verifiedEvidence() -> Evidence? {
        guard !quarantined else { return nil }
        do {
            let history = try journal.load()
            // Conservatively require owner-mediated writes after observing history.
            // This lifetime high-water guard is not persistent rollback protection.
            if let observedHistory, history != observedHistory { quarantined = true; return nil }
            if let history { observedHistory = history }
            guard let resetEvidence = try permittedReset() else { return nil }
            let before = Evidence(history: history, references: try credentials.references(), reset: resetEvidence.record)
            if let evidence, before != evidence { quarantined = true; return nil }
            switch CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials) {
            case .blocked: return nil
            case .legacyLocal, .locallyFenced: break
            }
            guard let resetAfter = try permittedReset() else { return nil }
            let after = Evidence(history: try journal.load(), references: try credentials.references(), reset: resetAfter.record)
            guard before == after else { quarantined = true; return nil }
            return after
        } catch { return nil }
    }

    /// Snapshot only: future reset coordinator must serialize presentation/suspension.
    /// Pending/corrupt reset must suppress retained WebViews as well as management.
    public func resetRenderingAllowed() -> Bool {
        (try? serialized { try permittedReset() != nil }) ?? false
    }
    private struct PermittedReset { let record: DeviceLocalResetRecord? }
    private func permittedReset() throws -> PermittedReset? {
        guard resetAttempt == nil else { return nil }
        let digest = try reset.scopeDigest
        let record = try reset.load()
        if let observedReset, record != observedReset { resetQuarantined = true; quarantined = true; return nil }
        if let evidence, record != evidence.reset { resetQuarantined = true; quarantined = true; return nil }
        if let record { observedReset = record }
        guard !resetQuarantined, record == nil || (record?.scopeDigest == digest && record?.phase == .completed) else { return nil }
        return .init(record: record)
    }

    enum ResetRecoverySnapshot: Equatable {
        case absent, pending(DeviceLocalResetRecord), completed(DeviceLocalResetRecord), uncertain(DeviceLocalResetRecord)
    }
    func configuredResetScopeDigest() throws -> String {
        try serialized { try reset.scopeDigest }
    }
    /// Recovery evidence only, never Local admission or a cleanup capability.
    func resetRecoverySnapshot() throws -> ResetRecoverySnapshot {
        try serialized {
            guard !resetQuarantined else { throw Failure.resetConflict }
            let digest = try reset.scopeDigest
            if let attempt = resetAttempt {
                guard attempt.record.scopeDigest == digest else { throw Failure.resetConflict }
                return .uncertain(attempt.record)
            }
            let record = try reset.load()
            if let observedReset, observedReset != record { resetQuarantined = true; invalidate(); throw Failure.resetConflict }
            guard let record else { return .absent }
            guard record.scopeDigest == digest else { throw Failure.resetConflict }
            observedReset = record
            return record.phase == .pending ? .pending(record) : .completed(record)
        }
    }

    func withPendingResetStep(_ record: DeviceLocalResetRecord, operation: () throws -> Void) throws {
        try serialized {
            guard !resetQuarantined, resetAttempt == nil, record.phase == .pending,
                  record.scopeDigest == (try reset.scopeDigest), try reset.load() == record else { throw Failure.resetConflict }
            try operation()
        }
    }
    /// Internal, explicit Local reset only. No cleanup is executed here.
    func beginLocalReset(_ lease: Lease, record: DeviceLocalResetRecord) throws {
        try serialized {
            defer { invalidate() }
            guard permitted, lease.owner == identity, lease.generation == generation,
                  verifiedEvidence() == evidence, record.phase == .pending,
                  record.scopeDigest == (try reset.scopeDigest), resetAttempt == nil else { throw Failure.resetConflict }
            let previous = try reset.load()
            guard previous == nil || (previous?.phase == .completed && previous?.resetID != record.resetID) else { throw Failure.resetConflict }
            resetAttempt = .init(record: record, beginsNew: previous != nil)
            try writeResetAttempt()
        }
    }
    func recommitResetAttempt() throws {
        try serialized { defer { invalidate() }; try writeResetAttempt() }
    }
    /// Completion is solely the future cleanup caller's assertion; no Cloud meaning.
    func completeLocalReset(expected pending: DeviceLocalResetRecord) throws {
        try serialized {
            defer { invalidate() }
            guard resetAttempt == nil, pending.phase == .pending, pending.scopeDigest == (try reset.scopeDigest),
                  try reset.load() == pending else { throw Failure.resetConflict }
            resetAttempt = .init(record: try pending.completed(), beginsNew: false)
            try writeResetAttempt()
        }
    }
    private func writeResetAttempt() throws {
        guard let attempt = resetAttempt else { throw Failure.noResetAttempt }
        if attempt.beginsNew { try reset.beginNewReset(attempt.record) } else { try reset.save(attempt.record) }
        guard try reset.load() == attempt.record else { throw Failure.resetConflict }
        observedReset = attempt.record
        resetAttempt = nil
        // Owner-mediated reset changes require new classification, never stale contexts.
        evidence = nil
    }

    private func invalidate() {
        permitted = false; generation = UUID()
        invalidationActions.append(contentsOf: invalidationObservers.values)
        invalidationObservers = [:]
    }
    fileprivate func observeInvalidation(_ lease: Lease, _ action: @escaping () -> Void) throws -> UUID {
        try serialized {
            guard permitted, lease.owner == identity, lease.generation == generation else { throw Failure.staleLease }
            let identifier = UUID(); invalidationObservers[identifier] = action; return identifier
        }
    }
    fileprivate func removeInvalidationObserver(_ identifier: UUID) {
        lock.lock(); invalidationObservers.removeValue(forKey: identifier); lock.unlock()
    }

    private func serialized<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        guard !executing else { lock.unlock(); throw Failure.reentrantOperation }
        executing = true
        defer {
            executing = false
            let actions = invalidationActions; invalidationActions = []
            lock.unlock()
            for action in actions { action() }
        }
        return try operation()
    }
}

/// Captured Local admission. A context never refreshes or mints a lease.
public struct DeviceManagementContext: @unchecked Sendable {
    private let authority: DeviceManagementAuthority
    private let lease: DeviceManagementAuthority.Lease
    public init(authority: DeviceManagementAuthority, lease: DeviceManagementAuthority.Lease) {
        self.authority = authority; self.lease = lease
    }
    func belongs(to owner: DeviceManagementAuthority) -> Bool { authority === owner }
    public func validate() throws { try authority.withLocalAuthority(lease) {} }
    public func revoke() throws { try authority.revoke() }
    func beginLocalReset(record: DeviceLocalResetRecord) throws { try authority.beginLocalReset(lease, record: record) }
    func observeInvalidation(_ action: @escaping () -> Void) throws -> UUID { try authority.observeInvalidation(lease, action) }
    func removeInvalidationObserver(_ identifier: UUID) { authority.removeInvalidationObserver(identifier) }
    // The synchronous closure is internal: callers cannot obtain an escaping unchecked capability.
    func withAuthority<T>(_ operation: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        try authority.withLocalAuthority(lease) { result = Result { try operation() } }
        return try result!.get()
    }
}
