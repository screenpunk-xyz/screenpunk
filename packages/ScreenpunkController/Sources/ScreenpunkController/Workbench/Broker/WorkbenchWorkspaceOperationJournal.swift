import Foundation
#if os(macOS)
import SQLite3
import Darwin

/// Service-owned machine history for long workspace copies. An interrupted
/// writer is reconciled to unknown, never replayed or presumed unapplied.
final class WorkbenchWorkspaceOperationJournal {
    private let db: OpaquePointer
    private let lock = NSLock()
    private let reservationLimit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String, reservationLimit: Int = 100_000) throws {
        guard path.hasPrefix("/"), !path.contains("/../") else {
            throw WorkbenchIPCError(.invalidConfiguration)
        }
        guard (1...100_000).contains(reservationLimit) else {
            throw WorkbenchIPCError(.invalidConfiguration)
        }
        self.reservationLimit = reservationLimit
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(path, &info) == 0,
           info.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) {
            throw WorkbenchIPCError(.insecureRuntime)
        }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw WorkbenchIPCError(.unavailable)
        }
        db = pointer
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA busy_timeout=5000")
            guard try scalar("PRAGMA journal_mode")?.lowercased() == "wal",
                  try scalar("PRAGMA synchronous") == "2" else {
                throw WorkbenchIPCError(.unavailable)
            }
            try execute("CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, state TEXT NOT NULL, record BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS reservations (operation_id TEXT PRIMARY KEY)")
            try execute("INSERT OR IGNORE INTO reservations (operation_id) SELECT operation_id FROM operations")
            try reconcileInterrupted()
        } catch { sqlite3_close(pointer); throw error }
    }
    deinit { sqlite3_close(db) }

    /// One durable reservation per operation ID, retained even after bounded
    /// detailed history is retired. A duplicate can never start another copy.
    func reserve(_ status: WorkbenchWorkspaceOperationStatus) throws {
        try status.validate()
        guard status.state == "running" else { throw WorkbenchIPCError(.invalidRequest) }
        let data = try encoder.encode(status)
        guard data.count <= 16 * 1024 else { throw WorkbenchIPCError(.resourceLimit) }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard try !reserved(status.operationId) else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            guard try count(table: "reservations") < reservationLimit else {
                throw WorkbenchIPCError(.resourceLimit)
            }
            let reservation = try statement("INSERT INTO reservations (operation_id) VALUES (?)")
            bind(status.operationId, at: 1, to: reservation)
            let reservationStep = sqlite3_step(reservation)
            sqlite3_finalize(reservation)
            guard reservationStep == SQLITE_DONE else {
                throw WorkbenchIPCError(reservationStep == SQLITE_CONSTRAINT ?
                    .workspaceConflict : .unavailable)
            }
            let query = try statement("INSERT INTO operations (operation_id, state, record) VALUES (?, ?, ?)")
            bind(status.operationId, at: 1, to: query)
            bind(status.state, at: 2, to: query)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(query, 3, bytes.baseAddress, Int32(bytes.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            let inserted = sqlite3_step(query) == SQLITE_DONE
            sqlite3_finalize(query)
            guard inserted else { throw WorkbenchIPCError(.unavailable) }
            try trimDetailedHistory()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Progress and terminal writes update only the exact reserved context.
    func upsert(_ status: WorkbenchWorkspaceOperationStatus) throws {
        try status.validate()
        let data = try encoder.encode(status)
        guard data.count <= 16 * 1024 else { throw WorkbenchIPCError(.resourceLimit) }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard let old = try getUnlocked(status.operationId), old.state == "running",
                  old.instanceId == status.instanceId, old.method == status.method,
                  old.destination == status.destination,
                  old.workspaceId == status.workspaceId,
                  old.selectionGeneration == status.selectionGeneration,
                  !old.cancellationRequested || status.cancellationRequested else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            let query = try statement("UPDATE operations SET state = ?, record = ? WHERE operation_id = ? AND state = 'running'")
            bind(status.state, at: 1, to: query)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(query, 2, bytes.baseAddress, Int32(bytes.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            bind(status.operationId, at: 3, to: query)
            let updated = sqlite3_step(query) == SQLITE_DONE && sqlite3_changes(db) == 1
            sqlite3_finalize(query)
            guard updated else { throw WorkbenchIPCError(.workspaceConflict) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func get(_ id: String) throws -> WorkbenchWorkspaceOperationStatus? {
        lock.lock(); defer { lock.unlock() }
        return try getUnlocked(id)
    }

    private func getUnlocked(_ id: String) throws -> WorkbenchWorkspaceOperationStatus? {
        let query = try statement("SELECT record FROM operations WHERE operation_id = ?")
        defer { sqlite3_finalize(query) }
        bind(id, at: 1, to: query)
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw WorkbenchIPCError(.unavailable) }
        return try decode(query)
    }

    func recent(limit: Int = 129) throws -> [WorkbenchWorkspaceOperationStatus] {
        guard (1...129).contains(limit) else { throw WorkbenchIPCError(.invalidRequest) }
        lock.lock(); defer { lock.unlock() }
        let query = try statement("SELECT record FROM operations ORDER BY rowid DESC LIMIT \(limit)")
        defer { sqlite3_finalize(query) }
        var values: [WorkbenchWorkspaceOperationStatus] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw WorkbenchIPCError(.unavailable) }
            values.append(try decode(query))
        }
        return values
    }

    private func reconcileInterrupted() throws {
        let query = try statement("SELECT record FROM operations WHERE state = 'running'")
        var interrupted: [WorkbenchWorkspaceOperationStatus] = []
        do {
            while true {
                let step = sqlite3_step(query)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw WorkbenchIPCError(.unavailable) }
                interrupted.append(try decode(query))
            }
        } catch {
            sqlite3_finalize(query)
            throw error
        }
        sqlite3_finalize(query)
        for status in interrupted { try upsert(status.completed("outcomeUnknown")) }
    }

    private func decode(_ query: OpaquePointer) throws -> WorkbenchWorkspaceOperationStatus {
        guard let bytes = sqlite3_column_blob(query, 0) else { throw WorkbenchIPCError(.unavailable) }
        let count = Int(sqlite3_column_bytes(query, 0))
        guard (1...16 * 1024).contains(count) else { throw WorkbenchIPCError(.unavailable) }
        let value = try decoder.decode(WorkbenchWorkspaceOperationStatus.self,
            from: Data(bytes: bytes, count: count))
        try value.validate()
        return value
    }

    private func count(table: String) throws -> Int {
        guard ["operations", "reservations"].contains(table) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let query = try statement("SELECT COUNT(*) FROM \(table)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw WorkbenchIPCError(.unavailable) }
        return Int(sqlite3_column_int(query, 0))
    }
    private func reserved(_ id: String) throws -> Bool {
        let query = try statement("SELECT 1 FROM reservations WHERE operation_id = ?")
        defer { sqlite3_finalize(query) }
        bind(id, at: 1, to: query)
        let step = sqlite3_step(query)
        if step == SQLITE_ROW { return true }
        if step == SQLITE_DONE { return false }
        throw WorkbenchIPCError(.unavailable)
    }
    private func trimDetailedHistory() throws {
        // Retire only terminal detail. Reservations remain forever until the
        // bounded lifetime admission cap is reached and new work fails closed.
        while try count(table: "operations") > 1024 {
            let oldest = try statement("SELECT operation_id FROM operations WHERE state != 'running' ORDER BY rowid LIMIT 1")
            let id: String?
            if sqlite3_step(oldest) == SQLITE_ROW, let value = sqlite3_column_text(oldest, 0) {
                id = String(cString: value)
            } else { id = nil }
            sqlite3_finalize(oldest)
            guard let id else { throw WorkbenchIPCError(.resourceLimit) }
            let removal = try statement("DELETE FROM operations WHERE operation_id = ?")
            bind(id, at: 1, to: removal)
            let removed = sqlite3_step(removal) == SQLITE_DONE
            sqlite3_finalize(removal)
            guard removed else { throw WorkbenchIPCError(.unavailable) }
        }
    }
    private func scalar(_ sql: String) throws -> String? {
        let query = try statement(sql)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw WorkbenchIPCError(.unavailable) }
        guard let value = sqlite3_column_text(query, 0) else { return nil }
        return String(cString: value)
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK,
              let query else { throw WorkbenchIPCError(.unavailable) }
        return query
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw WorkbenchIPCError(.unavailable)
        }
    }
    private func bind(_ value: String, at index: Int32, to query: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(query, index, $0, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
}
#endif
