import Foundation
import ScreenpunkCore

/// One-use process-local permission; never constructed from a caller-supplied completed record.
@MainActor final class DeviceLocalResetReopeningCapability {
    private let retirement: DeviceLocalResetWriterRetirement
    private let validateCompletion: () throws -> Void
    private var consumed = false
    private var consuming = false
    fileprivate init(retirement: DeviceLocalResetWriterRetirement, validateCompletion: @escaping () throws -> Void) {
        self.retirement = retirement; self.validateCompletion = validateCompletion
    }
    func isConsuming(_ retirement: DeviceLocalResetWriterRetirement) -> Bool { consuming && self.retirement === retirement }
    func consume(retirement: DeviceLocalResetWriterRetirement, operation: () throws -> Void) throws {
        guard !consumed, !consuming, self.retirement === retirement else { throw DeviceLocalResetCoordinator.Failure.invalidOperation }
        try validateCompletion()
        consuming = true
        defer { consuming = false }
        try operation()
        consumed = true
    }
}

/// Minted only during the synchronous qualified callback; cannot authorize async work.
@MainActor final class DeviceLocalResetCleanupPermit {
    private var active = true
    let scopeDigest: String
    let resetID: UUID
    let driverID: UUID
    private let authorize: (() throws -> Void) throws -> Void
    fileprivate init(scopeDigest: String, resetID: UUID, driverID: UUID, authorize: @escaping (() throws -> Void) throws -> Void) {
        self.scopeDigest = scopeDigest; self.resetID = resetID; self.driverID = driverID; self.authorize = authorize
    }
    fileprivate func expire() { active = false }
    func withStep(scopeDigest: String, operation: () throws -> Void) throws {
        guard active, self.scopeDigest == scopeDigest else { throw DeviceLocalResetCoordinator.Failure.invalidOperation }
        try authorize(operation)
    }
}

/// One process/root only. No filesystem exclusion against other processes.
/// Registry retains exact owner/operation/actions across coordinator reconstruction.
/// Qualified adapters exist, but no production presentation callers are installed yet.
@MainActor
final class DeviceLocalResetCoordinator {
    enum State: Equatable {
        case idle, pending(DeviceLocalResetRecord), suspending(DeviceLocalResetRecord), cleaning(DeviceLocalResetRecord)
        case completionUncertain(DeviceLocalResetRecord), completed(DeviceLocalResetRecord)
        case failed(DeviceLocalResetRecord?, Stage)
    }
    enum Stage: Equatable { case intent, recovery, suspension, cleanup, completion, cancelled }
    enum Failure: Error, Equatable { case configurationConflict, driverActive, invalidOperation }
    private final class Session {
        let digest: String
        let roots: [String]
        let authority: DeviceManagementAuthority
        let suspend: (DeviceLocalResetRecord) async throws -> Void
        let cleanup: (DeviceLocalResetRecord) async throws -> Void
        var state: State = .idle
        var record: DeviceLocalResetRecord?
        let qualifiedCleanup: ((DeviceLocalResetCleanupPermit) throws -> Void)?
        let retireWriters: ((DeviceLocalResetRecord) async throws -> DeviceLocalResetWriterRetirement)?
        let receiptCleanup: ((DeviceLocalResetCleanupPermit) throws -> DeviceLocalResetCleanupReceipt)?
        var retirement: DeviceLocalResetWriterRetirement?
        var receipt: DeviceLocalResetCleanupReceipt?
        var capability: DeviceLocalResetReopeningCapability?
        var driverID: UUID?
        var suspensionConfirmed = false
        var retired = false
        var driverActive = false
        var cleanupFinished = false
        var ownsCompletion = false
        init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
             suspend: @escaping (DeviceLocalResetRecord) async throws -> Void,
             cleanup: @escaping (DeviceLocalResetRecord) async throws -> Void,
             qualifiedCleanup: ((DeviceLocalResetCleanupPermit) throws -> Void)?,
             retireWriters: ((DeviceLocalResetRecord) async throws -> DeviceLocalResetWriterRetirement)?,
             receiptCleanup: ((DeviceLocalResetCleanupPermit) throws -> DeviceLocalResetCleanupReceipt)?) {
            digest = scope.digest; roots = [scope.deviceRoot.path, scope.preferencesRoot.path, scope.resetDirectory.path, scope.managementDirectory.path]
            self.authority = authority; self.suspend = suspend; self.cleanup = cleanup; self.qualifiedCleanup = qualifiedCleanup; self.retireWriters = retireWriters; self.receiptCleanup = receiptCleanup
        }
    }
    private static var sessions: [Session] = []
    private let session: Session
    var state: State { session.state }
    var reopeningCapability: DeviceLocalResetReopeningCapability? { session.capability }

    convenience init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
         suspend: @escaping (DeviceLocalResetRecord) async throws -> Void,
         cleanup: @escaping (DeviceLocalResetRecord) async throws -> Void) throws {
        try self.init(scope: scope, authority: authority, suspend: suspend, cleanup: cleanup, qualifiedCleanup: nil)
    }

    private init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
                 suspend: @escaping (DeviceLocalResetRecord) async throws -> Void,
                 cleanup: @escaping (DeviceLocalResetRecord) async throws -> Void,
                 qualifiedCleanup: ((DeviceLocalResetCleanupPermit) throws -> Void)?,
                 retireWriters: ((DeviceLocalResetRecord) async throws -> DeviceLocalResetWriterRetirement)? = nil,
                 receiptCleanup: ((DeviceLocalResetCleanupPermit) throws -> DeviceLocalResetCleanupReceipt)? = nil) throws {
        try scope.validateCurrentPaths()
        guard try authority.configuredResetScopeDigest() == scope.digest else { throw Failure.configurationConflict }
        let roots = [scope.deviceRoot.path, scope.preferencesRoot.path, scope.resetDirectory.path, scope.managementDirectory.path]
        let overlaps = Self.sessions.filter { existing in
            existing.roots.contains { a in roots.contains { b in a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") } }
        }
        if let existing = overlaps.first {
            guard overlaps.count == 1, existing.digest == scope.digest, existing.roots == roots, (existing.qualifiedCleanup != nil) == (qualifiedCleanup != nil), (existing.receiptCleanup != nil) == (receiptCleanup != nil) else { throw Failure.configurationConflict }
            session = existing
        } else {
            let created = Session(scope: scope, authority: authority, suspend: suspend, cleanup: cleanup, qualifiedCleanup: qualifiedCleanup, retireWriters: retireWriters, receiptCleanup: receiptCleanup)
            Self.sessions.append(created); session = created
        }
    }

    convenience init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
                     suspend: @escaping (DeviceLocalResetRecord) async throws -> Void,
                     qualifiedCleanup: @escaping (DeviceLocalResetCleanupPermit) throws -> Void) throws {
        try self.init(scope: scope, authority: authority, suspend: suspend,
                      cleanup: { _ in throw Failure.invalidOperation }, qualifiedCleanup: qualifiedCleanup)
    }

    convenience init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
                     retireWriters: @escaping (DeviceLocalResetRecord) async throws -> DeviceLocalResetWriterRetirement,
                     receiptCleanup: @escaping (DeviceLocalResetCleanupPermit) throws -> DeviceLocalResetCleanupReceipt) throws {
        try self.init(scope: scope, authority: authority, suspend: { _ in throw Failure.invalidOperation },
                      cleanup: { _ in throw Failure.invalidOperation }, qualifiedCleanup: nil,
                      retireWriters: retireWriters, receiptCleanup: receiptCleanup)
    }

    /// UUID comes solely from the explicit future human action, never recovery.
    func begin(context: DeviceManagementContext, resetID: UUID) async throws {
        try takeDriver()
        defer { releaseDriver() }
        guard context.belongs(to: session.authority), session.record == nil || isCompleted else { throw Failure.invalidOperation }
        try Task.checkCancellation()
        try context.validate()
        let record = try DeviceLocalResetRecord(resetID: resetID, scopeDigest: session.digest)
        session.record = record; session.cleanupFinished = false; session.ownsCompletion = false
        session.retirement = nil; session.receipt = nil
        do { try context.beginLocalReset(record: record) }
        catch {
            if (try? session.authority.resetRecoverySnapshot()) == .absent { session.record = nil }
            session.state = .failed(session.record, .intent); throw error
        }
        try await drive()
    }

    /// Confirmed completion on fresh recovery is no work; no services are resumed.
    func recover() async throws {
        try takeDriver()
        defer { releaseDriver() }
        do {
            switch try session.authority.resetRecoverySnapshot() {
            case .absent:
                guard session.record == nil else { throw Failure.invalidOperation }
                session.state = .idle
            case .completed(let record):
                if let expected = session.record { guard session.ownsCompletion, try expected.completed() == record else { throw Failure.invalidOperation } }
                session.state = .completed(record)
            case .pending(let record):
                if let expected = session.record { guard expected == record else { throw Failure.invalidOperation } }
                session.record = record
                if session.cleanupFinished { try finishCompletion(record) }
                else { try await drive() }
            case .uncertain(let record):
                if let expected = session.record { guard expected.resetID == record.resetID, expected.scopeDigest == record.scopeDigest else { throw Failure.invalidOperation } }
                if session.record == nil {
                    guard record.phase == .pending else { throw Failure.invalidOperation }
                    session.record = record
                }
                if record.phase == .completed { guard session.cleanupFinished && session.ownsCompletion else { throw Failure.invalidOperation } }
                try session.authority.recommitResetAttempt()
                if record.phase == .completed {
                    guard try session.authority.resetRecoverySnapshot() == .completed(record) else { throw Failure.invalidOperation }
                    session.state = .completed(record)
                }
                else { try await drive() }
            }
        } catch {
            switch session.state {
            case .completionUncertain, .failed: break
            default: session.state = .failed(session.record, .recovery)
            }
            throw error
        }
    }
    func retry() async throws { try await recover() }

    private var isCompleted: Bool { if case .completed = session.state { return true }; return false }
    private func takeDriver() throws {
        guard !session.retired else { throw Failure.invalidOperation }
        guard !session.driverActive else { throw Failure.driverActive }
        session.driverActive = true
        session.driverID = UUID()
    }
    private func releaseDriver() {
        session.driverActive = false
        session.driverID = nil
        session.suspensionConfirmed = false
        if case .completed(let completed) = session.state {
            if session.cleanupFinished, session.ownsCompletion,
               let retirement = session.retirement, let receipt = session.receipt,
               retirement.scopeDigest == session.digest, receipt.scopeDigest == session.digest,
               receipt.resetID == completed.resetID {
                // A cancellation arriving during synchronous completion must leave a recoverable
                // session, not strand retired writers without their one-use capability.
                guard !Task.isCancelled,
                      (try? session.authority.resetRecoverySnapshot()) == .completed(completed) else { return }
                session.capability = DeviceLocalResetReopeningCapability(retirement: retirement) { [authority = session.authority] in
                    guard try authority.resetRecoverySnapshot() == .completed(completed) else { throw Failure.invalidOperation }
                }
            }
            // Exact completed readback already succeeded; stale handles stay terminal.
            session.retired = true
            Self.sessions.removeAll { $0 === session }
        }
    }
    private func drive() async throws {
        guard let record = session.record,
              try session.authority.resetRecoverySnapshot() == .pending(record) else { throw Failure.invalidOperation }
        session.state = .pending(record)
        do {
            session.suspensionConfirmed = false
            session.state = .suspending(record)
            if let retire = session.retireWriters {
                let retirement = try await retire(record)
                guard retirement.scopeDigest == session.digest else { throw Failure.configurationConflict }
                session.retirement = retirement
            } else { try await session.suspend(record) }
            try Task.checkCancellation()
            guard try session.authority.resetRecoverySnapshot() == .pending(record) else { throw Failure.invalidOperation }
            session.suspensionConfirmed = true
        } catch { session.state = .failed(record, Task.isCancelled ? .cancelled : .suspension); throw error }
        do {
            session.state = .cleaning(record)
            if session.qualifiedCleanup != nil || session.receiptCleanup != nil, let driver = session.driverID {
                let permit = DeviceLocalResetCleanupPermit(scopeDigest: session.digest, resetID: record.resetID, driverID: driver) { [session] operation in
                    guard session.driverActive, session.driverID == driver, session.suspensionConfirmed,
                          session.record == record else { throw Failure.invalidOperation }
                    try session.authority.withPendingResetStep(record, operation: operation)
                }
                defer { permit.expire() }
                if let cleanup = session.receiptCleanup {
                    let receipt = try cleanup(permit)
                    guard receipt.scopeDigest == session.digest, receipt.resetID == record.resetID,
                          receipt.driverID == driver else { throw Failure.invalidOperation }
                    session.receipt = receipt
                } else { try session.qualifiedCleanup?(permit) }
            } else { try await session.cleanup(record) }
            // A cancellation-ignoring callback must return before driver releases.
            session.cleanupFinished = true
            try Task.checkCancellation()
        } catch { session.state = .failed(record, Task.isCancelled ? .cancelled : .cleanup); throw error }
        try finishCompletion(record)
    }
    private func finishCompletion(_ record: DeviceLocalResetRecord) throws {
        do {
            session.ownsCompletion = true
            try session.authority.completeLocalReset(expected: record)
            guard try session.authority.resetRecoverySnapshot() == .completed(record.completed()) else { throw Failure.invalidOperation }
            session.state = .completed(try record.completed())
        } catch { session.state = .completionUncertain(record); throw error }
    }
}
