import Foundation
import ScreenpunkCore

/// One process/root only. No filesystem exclusion against other processes.
/// Registry retains exact owner/operation/actions across coordinator reconstruction.
/// No production cleanup adapters or presentation callers are installed yet.
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
        var retired = false
        var driverActive = false
        var cleanupFinished = false
        var ownsCompletion = false
        init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
             suspend: @escaping (DeviceLocalResetRecord) async throws -> Void,
             cleanup: @escaping (DeviceLocalResetRecord) async throws -> Void) {
            digest = scope.digest; roots = [scope.deviceRoot.path, scope.preferencesRoot.path, scope.resetDirectory.path, scope.managementDirectory.path]
            self.authority = authority; self.suspend = suspend; self.cleanup = cleanup
        }
    }
    private static var sessions: [Session] = []
    private let session: Session
    var state: State { session.state }

    init(scope: DeviceLocalResetScope, authority: DeviceManagementAuthority,
         suspend: @escaping (DeviceLocalResetRecord) async throws -> Void,
         cleanup: @escaping (DeviceLocalResetRecord) async throws -> Void) throws {
        try scope.validateCurrentPaths()
        guard try authority.configuredResetScopeDigest() == scope.digest else { throw Failure.configurationConflict }
        let roots = [scope.deviceRoot.path, scope.preferencesRoot.path, scope.resetDirectory.path, scope.managementDirectory.path]
        let overlaps = Self.sessions.filter { existing in
            existing.roots.contains { a in roots.contains { b in a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") } }
        }
        if let existing = overlaps.first {
            guard overlaps.count == 1, existing.digest == scope.digest, existing.roots == roots else { throw Failure.configurationConflict }
            session = existing
        } else {
            let created = Session(scope: scope, authority: authority, suspend: suspend, cleanup: cleanup)
            Self.sessions.append(created); session = created
        }
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
                try await drive()
            case .uncertain(let record):
                if let expected = session.record { guard expected.resetID == record.resetID, expected.scopeDigest == record.scopeDigest else { throw Failure.invalidOperation } }
                if session.record == nil {
                    guard record.phase == .pending else { throw Failure.invalidOperation }
                    session.record = record
                }
                if record.phase == .completed { guard session.cleanupFinished && session.ownsCompletion else { throw Failure.invalidOperation } }
                try session.authority.recommitResetAttempt()
                if record.phase == .completed { session.state = .completed(record) }
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
    }
    private func releaseDriver() {
        session.driverActive = false
        if case .completed = session.state {
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
            session.state = .suspending(record)
            try await session.suspend(record)
            try Task.checkCancellation()
            guard try session.authority.resetRecoverySnapshot() == .pending(record) else { throw Failure.invalidOperation }
        } catch { session.state = .failed(record, Task.isCancelled ? .cancelled : .suspension); throw error }
        do {
            session.state = .cleaning(record)
            try await session.cleanup(record)
            // A cancellation-ignoring callback must return before driver releases.
            try Task.checkCancellation()
            session.cleanupFinished = true
        } catch { session.state = .failed(record, Task.isCancelled ? .cancelled : .cleanup); throw error }
        do {
            session.ownsCompletion = true
            try session.authority.completeLocalReset(expected: record)
            guard try session.authority.resetRecoverySnapshot() == .completed(record.completed()) else { throw Failure.invalidOperation }
            session.state = .completed(try record.completed())
        } catch { session.state = .completionUncertain(record); throw error }
    }
}
