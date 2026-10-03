import Foundation
#if os(macOS)
import SQLite3
import Darwin

enum WorkbenchDeploymentError: Error, Equatable {
    case invalidPlan, invalidApproval, staleContext, expired, clockUncertain, conflict
    case cancelled, alreadySent, missing, storage, unsupportedIntegration, unknownRemoteOutcome
}

struct WorkbenchDeploymentClock: Equatable {
    let wallSeconds: Int64
    let monotonicMilliseconds: Int64
    let bootId: String
}

struct WorkbenchDeploymentPlanRecord: Codable, Equatable {
    var planId: String
    var planHash: String
    var workspaceId: String
    var deviceId: String
    var authorizationContextHash: String
    var immutableBodyHash: String
    var materialJSON: Data
    var reviewJSON: Data
    var expiresWallSeconds: Int64
    var deadlineMonotonicMilliseconds: Int64
    var bootId: String
    var cancelled: Bool = false
}

struct WorkbenchDeploymentApprovalRecord: Codable, Equatable {
    enum State: String, Codable { case approved, consumed, cancelled, invalidated }
    var approvalId: String
    var planId: String
    var planHash: String
    var authorizationContextHash: String
    var consentSource: String
    var expiresWallSeconds: Int64
    var deadlineMonotonicMilliseconds: Int64
    var bootId: String
    var state: State = .approved
    var consumedOperationId: String? = nil
}

public struct WorkbenchDeploymentOperationRecord: Codable, Equatable {
    public enum State: String, Codable { case admitted, sending, received, active, failed, cancelled, unknown }
    public var operationId: String
    public var approvalId: String
    public var planId: String
    public var planHash: String
    public var authorizationContextHash: String
    public var idempotencyKey: String
    public var bodyHash: String
    public var state: State = .admitted
    public var sendAttempted: Bool = false
    public var cancelRequested: Bool = false
    public var receiptJSON: Data? = nil
}

private enum WorkbenchClockDecision<T> {
    case accepted(T)
    case rejected(WorkbenchDeploymentError)
}

/// This database is machine-local authority, not portable workspace history.
/// Every decision and transition runs under BEGIN IMMEDIATE with FULL sync.
final class WorkbenchDeploymentLedger {
    private let database: OpaquePointer
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("/../") else { throw WorkbenchDeploymentError.storage }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else { throw WorkbenchDeploymentError.storage }
        database = pointer
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=5000")
            guard try scalar("PRAGMA journal_mode")?.lowercased() == "wal",
                  try scalar("PRAGMA synchronous") == "2",
                  try scalar("PRAGMA foreign_keys") == "1" else {
                throw WorkbenchDeploymentError.storage
            }
            try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS plans (plan_id TEXT PRIMARY KEY, record BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS approvals (approval_id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES plans(plan_id), record BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, plan_id TEXT NOT NULL UNIQUE REFERENCES plans(plan_id), approval_id TEXT NOT NULL UNIQUE REFERENCES approvals(approval_id), record BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS retry_keys (idempotency_key TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(operation_id), body_hash TEXT NOT NULL)")
        } catch { sqlite3_close(pointer); throw error }
    }
    /// Inventory-only view. Never creates a database, checkpoint, or device
    /// owner; callers must use the service-owned machine path.
    init(readOnlyPath path: String) throws {
        guard path.hasPrefix("/"), !path.contains("/../") else {
            throw WorkbenchDeploymentError.storage
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WorkbenchDeploymentError.missing
        }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw WorkbenchDeploymentError.storage
        }
        database = pointer
    }
    deinit { sqlite3_close(database) }

    func observeClock(_ clock: WorkbenchDeploymentClock) throws {
        let decision: WorkbenchClockDecision<Void> = try transaction {
            do { try clockGate(clock); return .accepted(()) }
            catch let error as WorkbenchDeploymentError where error == .clockUncertain {
                try recordRejectedClock(clock, approvalId: nil)
                return .rejected(error)
            }
        }
        if case .rejected(let error) = decision { throw error }
    }

    func createPlan(_ plan: WorkbenchDeploymentPlanRecord, clock: WorkbenchDeploymentClock) throws {
        let decision: WorkbenchClockDecision<Void> = try transaction {
            do { try clockGate(clock) }
            catch let error as WorkbenchDeploymentError where error == .clockUncertain {
                try recordRejectedClock(clock, approvalId: nil)
                return .rejected(error)
            }
            guard try count(table: "plans") < 10_000,
                  !plan.planId.isEmpty, plan.materialJSON.count <= 50 * 1024 * 1024,
                  plan.reviewJSON.count <= 256 * 1024, plan.bootId == clock.bootId,
                  plan.expiresWallSeconds > clock.wallSeconds,
                  plan.expiresWallSeconds - clock.wallSeconds <= 86_400,
                  plan.deadlineMonotonicMilliseconds > clock.monotonicMilliseconds,
                  plan.deadlineMonotonicMilliseconds - clock.monotonicMilliseconds <= 86_400_000,
                  fetch(WorkbenchDeploymentPlanRecord.self, table: "plans", keyColumn: "plan_id", key: plan.planId) == nil else {
                return .rejected(.invalidPlan)
            }
            try put(plan, table: "plans", keyColumn: "plan_id", key: plan.planId, extra: nil)
            return .accepted(())
        }
        if case .rejected(let error) = decision { throw error }
    }

    /// Persist a sampled clock before domain-level expiry and arithmetic
    /// checks. An expired frozen plan retires its unconsumed consent in the
    /// same durable decision; a failed business precheck cannot erase time.
    func observePlanClock(planId: String, planHash: String,
                          clock: WorkbenchDeploymentClock) throws -> WorkbenchDeploymentPlanRecord {
        let decision: WorkbenchClockDecision<WorkbenchDeploymentPlanRecord> = try transaction {
            do { try clockGate(clock) }
            catch let error as WorkbenchDeploymentError where error == .clockUncertain {
                try recordRejectedClock(clock, approvalId: nil)
                return .rejected(error)
            }
            guard let plan = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans",
                                   keyColumn: "plan_id", key: planId),
                  plan.planHash == planHash, !plan.cancelled else { return .rejected(.invalidPlan) }
            guard valid(plan, at: clock) else {
                try recordRejectedClock(clock, approvalId: nil, planId: planId)
                return .rejected(.expired)
            }
            return .accepted(plan)
        }
        switch decision {
        case .accepted(let plan): return plan
        case .rejected(let error): throw error
        }
    }

    func approve(_ approval: WorkbenchDeploymentApprovalRecord, clock: WorkbenchDeploymentClock,
                 validateCurrent: () throws -> Void) throws {
        try approve(approval, clockProvider: { clock }, validateCurrent: validateCurrent)
    }

    func approve(_ approval: WorkbenchDeploymentApprovalRecord,
                 clockProvider: () -> WorkbenchDeploymentClock,
                 validateCurrent: () throws -> Void) throws {
        let decision: WorkbenchClockDecision<Void> = try transaction {
            var observed = clockProvider()
            do {
                try clockGate(observed)
                guard try count(table: "approvals") < 20_000,
                      let plan = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans", keyColumn: "plan_id", key: approval.planId),
                      !plan.cancelled, plan.planHash == approval.planHash,
                      plan.authorizationContextHash == approval.authorizationContextHash,
                      approval.bootId == observed.bootId, approval.state == .approved,
                      approval.consumedOperationId == nil,
                      approval.expiresWallSeconds <= plan.expiresWallSeconds,
                      approval.deadlineMonotonicMilliseconds <= plan.deadlineMonotonicMilliseconds,
                      fetch(WorkbenchDeploymentApprovalRecord.self, table: "approvals", keyColumn: "approval_id", key: approval.approvalId) == nil else {
                    throw WorkbenchDeploymentError.invalidApproval
                }
                guard valid(plan, at: observed), valid(approval, at: observed) else {
                    throw WorkbenchDeploymentError.expired
                }
                try validateCurrent()
                observed = clockProvider()
                try clockGate(observed)
                guard valid(plan, at: observed), valid(approval, at: observed) else {
                    throw WorkbenchDeploymentError.expired
                }
                try put(approval, table: "approvals", keyColumn: "approval_id", key: approval.approvalId,
                        extra: ("plan_id", approval.planId))
                return .accepted(())
            } catch let error as WorkbenchDeploymentError where error == .expired || error == .clockUncertain {
                try recordRejectedClock(observed, approvalId: nil, planId: approval.planId)
                return .rejected(error)
            }
        }
        if case .rejected(let error) = decision { throw error }
    }

    /// Existing-operation lookup precedes time/context checks. A retry can
    /// inspect the same operation after expiry, but never send it again.
    func admit(planId: String, planHash: String, contextHash: String, approvalId: String,
               idempotencyKey: String, approved: Bool, clock: WorkbenchDeploymentClock,
               validateCurrent: () throws -> Void) throws -> WorkbenchDeploymentOperationRecord {
        try admit(planId: planId, planHash: planHash, contextHash: contextHash,
                  approvalId: approvalId, idempotencyKey: idempotencyKey, approved: approved,
                  clockProvider: { clock }, validateCurrent: validateCurrent)
    }

    func admit(planId: String, planHash: String, contextHash: String, approvalId: String,
               idempotencyKey: String, approved: Bool,
               clockProvider: () -> WorkbenchDeploymentClock,
               validateCurrent: () throws -> Void) throws -> WorkbenchDeploymentOperationRecord {
        guard approved else { throw WorkbenchDeploymentError.invalidApproval }
        let bodyHash = try WorkbenchDeploymentHash.operationBody(planHash: planHash, contextHash: contextHash)
        let decision: WorkbenchClockDecision<WorkbenchDeploymentOperationRecord> = try transaction {
            if let binding = try retryBinding(idempotencyKey) {
                guard binding.bodyHash == bodyHash,
                      let existing = fetch(WorkbenchDeploymentOperationRecord.self, table: "operations",
                                           keyColumn: "operation_id", key: binding.operationId),
                      existing.planId == planId, existing.planHash == planHash,
                      existing.authorizationContextHash == contextHash else { throw WorkbenchDeploymentError.conflict }
                return .accepted(existing)
            }
            if let existing = try operation(for: planId) {
                guard existing.planHash == planHash, existing.bodyHash == bodyHash,
                      existing.authorizationContextHash == contextHash else { throw WorkbenchDeploymentError.conflict }
                try addRetryKey(idempotencyKey, operationId: existing.operationId, bodyHash: bodyHash)
                return .accepted(existing)
            }
            var observed = clockProvider()
            guard let plan = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans", keyColumn: "plan_id", key: planId),
                  let approval = fetch(WorkbenchDeploymentApprovalRecord.self, table: "approvals", keyColumn: "approval_id", key: approvalId),
                  !plan.cancelled, plan.planHash == planHash, plan.authorizationContextHash == contextHash,
                  approval.planId == planId, approval.planHash == planHash,
                  approval.authorizationContextHash == contextHash, approval.state == .approved,
                  approval.consumedOperationId == nil else {
                throw WorkbenchDeploymentError.invalidApproval
            }
            do {
                try clockGate(observed)
                guard valid(plan, at: observed), valid(approval, at: observed) else {
                    throw WorkbenchDeploymentError.expired
                }
                try validateCurrent()
                observed = clockProvider()
                try clockGate(observed)
                guard valid(plan, at: observed), valid(approval, at: observed) else {
                    throw WorkbenchDeploymentError.expired
                }
                let operation = WorkbenchDeploymentOperationRecord(operationId: UUID().uuidString.lowercased(),
                    approvalId: approvalId, planId: planId, planHash: planHash,
                    authorizationContextHash: contextHash, idempotencyKey: idempotencyKey, bodyHash: bodyHash)
                try put(operation, table: "operations", keyColumn: "operation_id", key: operation.operationId,
                        extra: ("plan_id", planId), second: ("approval_id", approvalId))
                try addRetryKey(idempotencyKey, operationId: operation.operationId, bodyHash: bodyHash)
                var consumed = approval; consumed.state = .consumed; consumed.consumedOperationId = operation.operationId
                try put(consumed, table: "approvals", keyColumn: "approval_id", key: approvalId,
                        extra: ("plan_id", planId))
                return .accepted(operation)
            } catch let error as WorkbenchDeploymentError where error == .expired || error == .clockUncertain {
                try recordRejectedClock(observed, approvalId: approvalId)
                return .rejected(error)
            }
        }
        switch decision {
        case .accepted(let operation): return operation
        case .rejected(let error): throw error
        }
    }

    /// Persist intent before invoking transport; this transition is never undone.
    func markSending(operationId: String, clock: WorkbenchDeploymentClock,
                     validateCurrent: () throws -> Void) throws -> WorkbenchDeploymentOperationRecord {
        try markSending(operationId: operationId, clockProvider: { clock }, validateCurrent: validateCurrent)
    }

    func markSending(operationId: String, clockProvider: () -> WorkbenchDeploymentClock,
                     validateCurrent: () throws -> Void) throws -> WorkbenchDeploymentOperationRecord {
        try transaction {
            guard var operation = fetch(WorkbenchDeploymentOperationRecord.self, table: "operations",
                keyColumn: "operation_id", key: operationId), operation.state == .admitted,
                  !operation.sendAttempted, !operation.cancelRequested,
                  let plan = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans", keyColumn: "plan_id", key: operation.planId),
                  let approval = fetch(WorkbenchDeploymentApprovalRecord.self, table: "approvals", keyColumn: "approval_id", key: operation.approvalId),
                  !plan.cancelled else { throw WorkbenchDeploymentError.alreadySent }
            var observed = clockProvider()
            do {
                try clockGate(observed)
                guard valid(plan, at: observed), valid(approval, at: observed) else { throw WorkbenchDeploymentError.expired }
                try validateCurrent()
                observed = clockProvider()
                try clockGate(observed)
                guard valid(plan, at: observed), valid(approval, at: observed) else { throw WorkbenchDeploymentError.expired }
            } catch {
                if let failure = error as? WorkbenchDeploymentError,
                   failure == .expired || failure == .clockUncertain {
                    try recordRejectedClock(observed, approvalId: nil)
                }
                operation.state = .cancelled; operation.cancelRequested = true
                try put(operation, table: "operations", keyColumn: "operation_id", key: operationId,
                        extra: ("plan_id", operation.planId), second: ("approval_id", operation.approvalId))
                // Commit the cancellation rather than rolling it back with an error.
                return operation
            }
            operation.state = .sending; operation.sendAttempted = true
            try put(operation, table: "operations", keyColumn: "operation_id", key: operationId,
                    extra: ("plan_id", operation.planId), second: ("approval_id", operation.approvalId))
            return operation
        }
    }

    /// Called on the authenticated transport immediately before its first
    /// deploy frame. Preparation and capability queries may have blocked after
    /// markSending, so the earlier clock sample is insufficient.
    func validateFirstSend(operationId: String,
                           clockProvider: () -> WorkbenchDeploymentClock,
                           validateCurrent: () throws -> Void) throws -> Bool {
        try transaction {
            guard var operation = fetch(WorkbenchDeploymentOperationRecord.self,
                table: "operations", keyColumn: "operation_id", key: operationId),
                  operation.state == .sending, operation.sendAttempted,
                  let plan = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans",
                    keyColumn: "plan_id", key: operation.planId),
                  let approval = fetch(WorkbenchDeploymentApprovalRecord.self, table: "approvals",
                    keyColumn: "approval_id", key: operation.approvalId) else {
                throw WorkbenchDeploymentError.alreadySent
            }
            var observed = clockProvider()
            do {
                try clockGate(observed)
                guard !plan.cancelled, !operation.cancelRequested,
                      valid(plan, at: observed), valid(approval, at: observed) else {
                    throw WorkbenchDeploymentError.expired
                }
                try validateCurrent()
                observed = clockProvider()
                try clockGate(observed)
                guard valid(plan, at: observed), valid(approval, at: observed) else {
                    throw WorkbenchDeploymentError.expired
                }
                return true
            } catch {
                if let failure = error as? WorkbenchDeploymentError,
                   failure == .expired || failure == .clockUncertain {
                    try recordRejectedClock(observed, approvalId: nil)
                }
                operation.state = .failed
                operation.sendAttempted = false
                operation.cancelRequested = true
                try put(operation, table: "operations", keyColumn: "operation_id", key: operationId,
                        extra: ("plan_id", operation.planId), second: ("approval_id", operation.approvalId))
                return false
            }
        }
    }

    func cancelPlan(_ planId: String) throws -> WorkbenchDeploymentOperationRecord? {
        try transaction {
            guard var plan = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans", keyColumn: "plan_id", key: planId) else {
                throw WorkbenchDeploymentError.missing
            }
            plan.cancelled = true
            try put(plan, table: "plans", keyColumn: "plan_id", key: planId, extra: nil)
            if var operation = try operation(for: planId) {
                operation.cancelRequested = true
                if !operation.sendAttempted && operation.state == .admitted { operation.state = .cancelled }
                else if operation.state == .sending { operation.state = .unknown }
                try put(operation, table: "operations", keyColumn: "operation_id", key: operation.operationId,
                        extra: ("plan_id", planId), second: ("approval_id", operation.approvalId))
                return operation
            }
            for var approval in try approvals(for: planId) where approval.state == .approved {
                approval.state = .cancelled
                try put(approval, table: "approvals", keyColumn: "approval_id", key: approval.approvalId,
                        extra: ("plan_id", planId))
            }
            return nil
        }
    }

    func updateOutcome(operationId: String, state: WorkbenchDeploymentOperationRecord.State,
                       receiptJSON: Data? = nil) throws -> WorkbenchDeploymentOperationRecord {
        try transaction {
            guard var operation = fetch(WorkbenchDeploymentOperationRecord.self, table: "operations",
                keyColumn: "operation_id", key: operationId), operation.sendAttempted,
                  [.sending, .received, .unknown].contains(operation.state),
                  [.received, .active, .unknown].contains(state),
                  state != .active || operation.receiptJSON != nil else { throw WorkbenchDeploymentError.conflict }
            operation.state = state
            if let receiptJSON { operation.receiptJSON = receiptJSON }
            try put(operation, table: "operations", keyColumn: "operation_id", key: operationId,
                    extra: ("plan_id", operation.planId), second: ("approval_id", operation.approvalId))
            return operation
        }
    }

    func status(_ operationId: String) throws -> WorkbenchDeploymentOperationRecord {
        lock.lock(); defer { lock.unlock() }
        guard let value = fetch(WorkbenchDeploymentOperationRecord.self, table: "operations",
            keyColumn: "operation_id", key: operationId) else { throw WorkbenchDeploymentError.missing }
        return value
    }

    func recentOperations(limit: Int = 128) throws -> [WorkbenchDeploymentOperationRecord] {
        guard (1...129).contains(limit) else { throw WorkbenchDeploymentError.storage }
        lock.lock(); defer { lock.unlock() }
        let query = try statement("SELECT record FROM operations ORDER BY rowid DESC LIMIT \(limit)")
        defer { sqlite3_finalize(query) }
        var results: [WorkbenchDeploymentOperationRecord] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else {
                throw WorkbenchDeploymentError.storage
            }
            let count = Int(sqlite3_column_bytes(query, 0))
            guard count > 0, count <= 64 * 1024 else { throw WorkbenchDeploymentError.storage }
            results.append(try decoder.decode(WorkbenchDeploymentOperationRecord.self,
                from: Data(bytes: bytes, count: count)))
        }
        return results
    }

    /// Read an already admitted operation when a caller retained only its plan
    /// ID after losing the apply response. This does not approve or send.
    func operationForPlan(_ planId: String) throws -> WorkbenchDeploymentOperationRecord {
        lock.lock(); defer { lock.unlock() }
        guard let value = try operation(for: planId) else { throw WorkbenchDeploymentError.missing }
        return value
    }

    func approval(_ approvalId: String) throws -> WorkbenchDeploymentApprovalRecord {
        lock.lock(); defer { lock.unlock() }
        guard let value = fetch(WorkbenchDeploymentApprovalRecord.self, table: "approvals",
            keyColumn: "approval_id", key: approvalId) else { throw WorkbenchDeploymentError.missing }
        return value
    }

    func plan(_ planId: String) throws -> WorkbenchDeploymentPlanRecord {
        lock.lock(); defer { lock.unlock() }
        guard let value = fetch(WorkbenchDeploymentPlanRecord.self, table: "plans",
            keyColumn: "plan_id", key: planId) else { throw WorkbenchDeploymentError.missing }
        return value
    }

    private func valid(_ plan: WorkbenchDeploymentPlanRecord, at clock: WorkbenchDeploymentClock) -> Bool {
        plan.bootId == clock.bootId && clock.wallSeconds < plan.expiresWallSeconds &&
        clock.monotonicMilliseconds < plan.deadlineMonotonicMilliseconds
    }
    private func valid(_ approval: WorkbenchDeploymentApprovalRecord, at clock: WorkbenchDeploymentClock) -> Bool {
        approval.bootId == clock.bootId && clock.wallSeconds < approval.expiresWallSeconds &&
        clock.monotonicMilliseconds < approval.deadlineMonotonicMilliseconds
    }
    private func clockGate(_ clock: WorkbenchDeploymentClock) throws {
        guard clock.wallSeconds > 0, clock.monotonicMilliseconds >= 0, !clock.bootId.isEmpty else {
            throw WorkbenchDeploymentError.clockUncertain
        }
        let savedWall = meta("wall_high_water")
        let savedBoot = meta("boot_id")
        let savedMonotonic = meta("last_monotonic")
        if let uncertainBoot = meta("clock_uncertain_boot"), uncertainBoot == clock.bootId {
            throw WorkbenchDeploymentError.clockUncertain
        }
        if savedWall != nil || savedBoot != nil || savedMonotonic != nil {
            guard let savedWall, Int64(savedWall) != nil,
                  let savedBoot, !savedBoot.isEmpty,
                  let savedMonotonic, Int64(savedMonotonic) != nil else {
                throw WorkbenchDeploymentError.clockUncertain
            }
        } else {
            let query = try statement("SELECT 1 FROM plans LIMIT 1")
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_DONE else { throw WorkbenchDeploymentError.clockUncertain }
        }
        let high = Int64(savedWall ?? "0") ?? 0
        guard clock.wallSeconds >= high else { throw WorkbenchDeploymentError.clockUncertain }
        if let priorBoot = savedBoot, priorBoot == clock.bootId,
           let priorMono = Int64(savedMonotonic ?? ""),
           clock.monotonicMilliseconds < priorMono { throw WorkbenchDeploymentError.clockUncertain }
        try setMeta("wall_high_water", String(clock.wallSeconds))
        try setMeta("boot_id", clock.bootId)
        try setMeta("last_monotonic", String(clock.monotonicMilliseconds))
        if meta("clock_uncertain_boot") != nil { try setMeta("clock_uncertain_boot", "") }
    }
    /// Called inside a transaction that will commit a rejected decision. The
    /// high-water mark and the affected unconsumed consent must survive errors.
    private func recordRejectedClock(_ clock: WorkbenchDeploymentClock,
                                     approvalId: String?, planId: String? = nil) throws {
        let priorWall = Int64(meta("wall_high_water") ?? "0") ?? 0
        if clock.wallSeconds > priorWall { try setMeta("wall_high_water", String(clock.wallSeconds)) }
        let priorBoot = meta("boot_id")
        let priorMono = Int64(meta("last_monotonic") ?? "0") ?? 0
        if priorBoot == clock.bootId, clock.monotonicMilliseconds > priorMono {
            try setMeta("last_monotonic", String(clock.monotonicMilliseconds))
        }
        if clock.wallSeconds < priorWall ||
           (priorBoot == clock.bootId && clock.monotonicMilliseconds < priorMono) {
            try setMeta("clock_uncertain_boot", clock.bootId)
        }
        if let approvalId,
           var approval = fetch(WorkbenchDeploymentApprovalRecord.self, table: "approvals",
                                keyColumn: "approval_id", key: approvalId),
           approval.state == .approved {
            approval.state = .invalidated
            try put(approval, table: "approvals", keyColumn: "approval_id", key: approvalId,
                    extra: ("plan_id", approval.planId))
        }
        if let planId {
            for var approval in try approvals(for: planId) where approval.state == .approved {
                approval.state = .invalidated
                try put(approval, table: "approvals", keyColumn: "approval_id", key: approval.approvalId,
                        extra: ("plan_id", planId))
            }
        }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw WorkbenchDeploymentError.storage }
    }
    private func scalar(_ sql: String) throws -> String? {
        let query = try statement(sql)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else {
            return nil
        }
        return String(cString: value)
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw WorkbenchDeploymentError.storage
        }
        return result
    }
    private func bind(_ string: String, to statement: OpaquePointer, at index: Int32) {
        _ = string.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func fetch<T: Decodable>(_ type: T.Type, table: String, keyColumn: String, key: String) -> T? {
        guard let query = try? statement("SELECT record FROM \(table) WHERE \(keyColumn)=? LIMIT 1") else { return nil }
        defer { sqlite3_finalize(query) }
        bind(key, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        return try? decoder.decode(T.self, from: data)
    }
    private func put<T: Encodable>(_ value: T, table: String, keyColumn: String, key: String,
                                   extra: (String, String)?, second: (String, String)? = nil) throws {
        let data = try encoder.encode(value)
        let columns = [keyColumn, "record"] + [extra?.0, second?.0].compactMap { $0 }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
        let sql = "INSERT INTO \(table)(\(columns.joined(separator: ","))) VALUES(\(placeholders)) ON CONFLICT(\(keyColumn)) DO UPDATE SET record=excluded.record"
        let query = try statement(sql); defer { sqlite3_finalize(query) }
        bind(key, to: query, at: 1); bind(data, to: query, at: 2)
        if let extra { bind(extra.1, to: query, at: 3) }
        if let second { bind(second.1, to: query, at: 4) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkbenchDeploymentError.storage }
    }
    private func meta(_ key: String) -> String? {
        guard let query = try? statement("SELECT value FROM meta WHERE key=?") else { return nil }
        defer { sqlite3_finalize(query) }
        bind(key, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW, let pointer = sqlite3_column_text(query, 0) else { return nil }
        return String(cString: pointer)
    }
    private func setMeta(_ key: String, _ value: String) throws {
        let query = try statement("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(query) }
        bind(key, to: query, at: 1); bind(value, to: query, at: 2)
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkbenchDeploymentError.storage }
    }
    private func retryBinding(_ key: String) throws -> (operationId: String, bodyHash: String)? {
        let query = try statement("SELECT operation_id,body_hash FROM retry_keys WHERE idempotency_key=?")
        defer { sqlite3_finalize(query) }
        bind(key, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW,
              let op = sqlite3_column_text(query, 0), let body = sqlite3_column_text(query, 1) else { return nil }
        return (String(cString: op), String(cString: body))
    }
    private func addRetryKey(_ key: String, operationId: String, bodyHash: String) throws {
        guard !key.isEmpty, key.utf8.count <= 128 else { throw WorkbenchDeploymentError.conflict }
        guard try count(table: "retry_keys") < 50_000 else { throw WorkbenchDeploymentError.storage }
        let existing = try statement("SELECT COUNT(*) FROM retry_keys WHERE operation_id=?")
        defer { sqlite3_finalize(existing) }
        bind(operationId, to: existing, at: 1)
        guard sqlite3_step(existing) == SQLITE_ROW, sqlite3_column_int(existing, 0) < 16 else {
            throw WorkbenchDeploymentError.storage
        }
        let query = try statement("INSERT INTO retry_keys(idempotency_key,operation_id,body_hash) VALUES(?,?,?)")
        defer { sqlite3_finalize(query) }
        bind(key, to: query, at: 1); bind(operationId, to: query, at: 2); bind(bodyHash, to: query, at: 3)
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkbenchDeploymentError.conflict }
    }
    private func operation(for planId: String) throws -> WorkbenchDeploymentOperationRecord? {
        let query = try statement("SELECT record FROM operations WHERE plan_id=? LIMIT 1")
        defer { sqlite3_finalize(query) }
        bind(planId, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { return nil }
        return try decoder.decode(WorkbenchDeploymentOperationRecord.self,
            from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
    }
    private func approvals(for planId: String) throws -> [WorkbenchDeploymentApprovalRecord] {
        let query = try statement("SELECT record FROM approvals WHERE plan_id=?")
        defer { sqlite3_finalize(query) }
        bind(planId, to: query, at: 1)
        var results: [WorkbenchDeploymentApprovalRecord] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(query, 0) else { throw WorkbenchDeploymentError.storage }
            results.append(try decoder.decode(WorkbenchDeploymentApprovalRecord.self,
                from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))))
        }
        return results
    }
    private func count(table: String) throws -> Int {
        let query = try statement("SELECT COUNT(*) FROM \(table)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw WorkbenchDeploymentError.storage }
        return Int(sqlite3_column_int(query, 0))
    }
}
#endif
