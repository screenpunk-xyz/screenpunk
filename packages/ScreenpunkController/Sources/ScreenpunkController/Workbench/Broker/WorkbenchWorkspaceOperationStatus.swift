import Foundation
#if os(macOS)

/// Live, broker-process-local evidence for a long workspace copy. A missing
/// record after a restart is not evidence that the operation did not commit.
public struct WorkbenchWorkspaceOperationStatus: Codable, Sendable, Equatable {
    public static let method = "workspace.operationStatus"
    public static let cancelMethod = "workspace.operationCancel"
    public let schemaVersion: Int
    public let operationId: String
    public let instanceId: String
    public let workspaceId: String?
    public let selectionGeneration: Int?
    public let method: String
    public let destination: String
    public let state: String
    public let cancellationRequested: Bool
    public let phase: String
    public let copiedFiles: Int
    public let totalFiles: Int
    public let copiedBytes: Int64
    public let totalBytes: Int64

    init(operationId: String, instanceId: String, method: String, destination: String,
         workspaceId: String? = nil, selectionGeneration: Int? = nil,
         state: String = "running", cancellationRequested: Bool = false,
         phase: String = "waiting",
         copiedFiles: Int = 0, totalFiles: Int = 0,
         copiedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        schemaVersion = 1; self.operationId = operationId; self.instanceId = instanceId
        self.workspaceId = workspaceId; self.selectionGeneration = selectionGeneration
        self.method = method; self.destination = destination; self.state = state
        self.cancellationRequested = cancellationRequested; self.phase = phase
        self.copiedFiles = copiedFiles; self.totalFiles = totalFiles
        self.copiedBytes = copiedBytes; self.totalBytes = totalBytes
    }

    func updated(progress: WorkspaceCopyProgress) -> Self {
        .init(operationId: operationId, instanceId: instanceId, method: method,
              destination: destination, workspaceId: workspaceId,
              selectionGeneration: selectionGeneration, state: state,
              cancellationRequested: cancellationRequested, phase: progress.phase.rawValue,
              copiedFiles: progress.copiedFiles, totalFiles: progress.totalFiles,
              copiedBytes: progress.copiedBytes, totalBytes: progress.totalBytes)
    }

    func completed(_ state: String) -> Self {
        .init(operationId: operationId, instanceId: instanceId, method: method,
              destination: destination, workspaceId: workspaceId,
              selectionGeneration: selectionGeneration, state: state,
              cancellationRequested: cancellationRequested, phase: phase,
              copiedFiles: copiedFiles, totalFiles: totalFiles,
              copiedBytes: copiedBytes, totalBytes: totalBytes)
    }

    func requestingCancellation() -> Self {
        .init(operationId: operationId, instanceId: instanceId, method: method,
              destination: destination, workspaceId: workspaceId,
              selectionGeneration: selectionGeneration, state: state,
              cancellationRequested: true, phase: phase,
              copiedFiles: copiedFiles, totalFiles: totalFiles,
              copiedBytes: copiedBytes, totalBytes: totalBytes)
    }

    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: operationId) != nil,
              UUID(uuidString: instanceId) != nil,
              ((workspaceId == nil && selectionGeneration == nil) ||
               (workspaceId.map(WorkspaceValidation.id) == true &&
                (selectionGeneration ?? 0) > 0)),
              [WorkbenchAuthoringRecoveryMethod.snapshotCreate.rawValue,
               WorkbenchAuthoringRecoveryMethod.workspaceRelocate.rawValue].contains(method),
              WorkspaceValidation.absolute(destination),
              ["running", "applied", "outcomeUnknown", "notStarted"].contains(state),
              ["waiting", "copying", "verifying", "publishing", "switching", "complete"].contains(phase),
              copiedFiles >= 0, totalFiles >= 0, copiedFiles <= totalFiles,
              copiedBytes >= 0, totalBytes >= 0, copiedBytes <= totalBytes else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

/// This inventory is intentionally limited to copy operations observed by the
/// current broker process; it is not a durable cross-domain operation ledger.
public struct WorkbenchWorkspaceOperationList: Codable, Sendable, Equatable {
    public static let method = "workspace.operationList"
    public let schemaVersion: Int
    public let instanceId: String
    public let scope: String
    public let complete: Bool
    public let operations: [WorkbenchWorkspaceOperationStatus]

    init(instanceId: String, operations: [WorkbenchWorkspaceOperationStatus]) {
        schemaVersion = 1; self.instanceId = instanceId
        scope = "process-local-workspace-copy"; complete = false
        self.operations = operations
    }

    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: instanceId) != nil,
              scope == "process-local-workspace-copy", !complete,
              operations.count <= 128,
              Set(operations.map(\.operationId)).count == operations.count,
              operations.allSatisfy({ $0.instanceId == instanceId }) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        for operation in operations { try operation.validate() }
    }
}

final class WorkbenchWorkspaceOperationRegistry {
    private let lock = NSLock()
    private let journal: WorkbenchWorkspaceOperationJournal?
    private var values: [String: WorkbenchWorkspaceOperationStatus] = [:]
    private var order: [String] = []

    init(journalPath: String? = nil) throws {
        journal = try journalPath.map { try WorkbenchWorkspaceOperationJournal(path: $0) }
    }
    var durable: Bool { journal != nil }

    func begin(id: String, instanceId: String, method: String, destination: String,
               workspaceId: String, selectionGeneration: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard WorkspaceValidation.id(workspaceId), selectionGeneration > 0 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        guard values[id] == nil else { throw WorkbenchIPCError(.workspaceConflict) }
        let status = WorkbenchWorkspaceOperationStatus(operationId: id,
            instanceId: instanceId, method: method, destination: destination,
            workspaceId: workspaceId, selectionGeneration: selectionGeneration)
        try journal?.reserve(status)
        if values[id] == nil { order.append(id) }
        values[id] = status
        while order.count > 128 { values.removeValue(forKey: order.removeFirst()) }
    }

    func progress(id: String, value: WorkspaceCopyProgress) {
        lock.lock(); defer { lock.unlock() }
        guard let old = values[id], old.state == "running" else { return }
        let updated = old.updated(progress: value)
        values[id] = updated
        try? journal?.upsert(updated)
    }

    func finish(id: String, state: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let old = values[id], old.state == "running" else { return }
        let completed = old.completed(state)
        try journal?.upsert(completed)
        values[id] = completed
    }

    func get(id: String) -> WorkbenchWorkspaceOperationStatus? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }

    func list(instanceId: String) -> WorkbenchWorkspaceOperationList {
        lock.lock(); defer { lock.unlock() }
        return .init(instanceId: instanceId,
            operations: order.reversed().compactMap { values[$0] })
    }

    func historical(_ id: String) throws -> WorkbenchWorkspaceOperationStatus? {
        if let live = get(id: id) { return live }
        return try journal?.get(id)
    }

    func history() throws -> (operations: [WorkbenchWorkspaceOperationStatus], truncated: Bool) {
        if let journal {
            let rows = try journal.recent()
            return (Array(rows.prefix(128)), rows.count > 128)
        }
        lock.lock(); defer { lock.unlock() }
        return (order.reversed().compactMap { values[$0] }, false)
    }

    func requestCancel(id: String) throws -> WorkbenchWorkspaceOperationStatus? {
        lock.lock(); defer { lock.unlock() }
        guard let old = values[id] else { return nil }
        if old.state == "running" {
            let requested = old.requestingCancellation()
            try journal?.upsert(requested)
            values[id] = requested
        }
        return values[id]
    }

    func isCancelRequested(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[id]?.cancellationRequested == true
    }
}
#endif
