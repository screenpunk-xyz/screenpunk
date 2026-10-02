import Foundation
import ScreenpunkCore

/// In-process authority only. External filesystem/Keychain writers are not excluded.
/// No mutation APIs are provided. Production Cloud transition writers must remain
/// disabled until owner-mediated exact uncertain-write recovery is implemented.
/// All future management callers must share this owner and acquire it before their
/// server lock. Do not wait for asynchronous callbacks from a gated operation.
public final class DeviceManagementAuthority: @unchecked Sendable {
    public struct Lease: Sendable {
        fileprivate let owner: UUID
        fileprivate let generation: UUID
    }
    public enum Failure: Error, Equatable {
        case staleLease, reentrantOperation
    }
    private let lock = NSRecursiveLock()
    private let identity = UUID()
    private var generation = UUID()
    private struct Evidence: Equatable {
        let history: DeviceManagementTransitionHistory?
        let references: Set<String>
    }
    private var quarantined = false
    private var observedHistory: DeviceManagementTransitionHistory?
    private var evidence: Evidence?
    private var permitted = false
    private var executing = false
    private let journal: any CloudInstallationTransitionJournal
    private let credentials: CloudInstallationCredentialStore

    public init(journal: any CloudInstallationTransitionJournal, credentials: CloudInstallationCredentialStore) {
        self.journal = journal
        self.credentials = credentials
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
    // uncertain-write recovery is implemented. This slice exposes no write API. Fresh entry
    // checks detect external changes, but do not exclude external TOCTOU writers.
    private func verifiedEvidence() -> Evidence? {
        guard !quarantined else { return nil }
        do {
            let history = try journal.load()
            // Conservatively require owner-mediated writes after observing history.
            // This lifetime high-water guard is not persistent rollback protection.
            if let observedHistory, history != observedHistory { quarantined = true; return nil }
            if let history { observedHistory = history }
            let before = Evidence(history: history, references: try credentials.references())
            if let evidence, before != evidence { quarantined = true; return nil }
            switch CloudInstallationRecovery.localEligibility(journal: journal, credentials: credentials) {
            case .blocked: return nil
            case .legacyLocal, .locallyFenced: break
            }
            let after = Evidence(history: try journal.load(), references: try credentials.references())
            guard before == after else { quarantined = true; return nil }
            return after
        } catch { return nil }
    }

    private func invalidate() { permitted = false; generation = UUID() }

    private func serialized<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !executing else { throw Failure.reentrantOperation }
        executing = true
        defer { executing = false }
        return try operation()
    }
}
