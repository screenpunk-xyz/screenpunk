import Foundation
#if os(macOS)
import SQLite3
import Darwin

public struct WorkbenchDeviceEvent: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let eventId: String
    public let deviceId: String
    public let kind: String
    public let outcome: String
    public let recordedAtSeconds: Int64

    static let kinds: Set<String> = ["pairingBegan", "pairingConfirmed", "deviceForgotten",
        "settingsUpdated", "screenSetObserved", "connectionIntentStaged",
        "connectionApplied", "deploymentObserved"]
    init(deviceId: String, kind: String, outcome: String) {
        schemaVersion = 1; eventId = UUID().uuidString.lowercased()
        self.deviceId = deviceId; self.kind = kind; self.outcome = outcome
        recordedAtSeconds = Int64(Date().timeIntervalSince1970)
    }
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: eventId) != nil,
              WorkspaceValidation.id(deviceId), Self.kinds.contains(kind),
              ["acknowledged", "observed"].contains(outcome),
              recordedAtSeconds > 0 else { throw WorkbenchIPCError(.invalidRequest) }
    }
}

public struct WorkbenchDeviceLogRead: Codable, Sendable, Equatable {
    public static let method = "device.logs"
    public let schemaVersion: Int
    public let deviceId: String
    public let scope: String
    public let complete: Bool
    public let truncated: Bool
    public let events: [WorkbenchDeviceEvent]

    init(deviceId: String, events: [WorkbenchDeviceEvent], truncated: Bool) {
        schemaVersion = 1; self.deviceId = deviceId
        scope = "broker-observed-device-events"; complete = false
        self.truncated = truncated; self.events = events
    }
    public func validate() throws {
        guard schemaVersion == 1, WorkspaceValidation.id(deviceId),
              scope == "broker-observed-device-events", !complete,
              events.count <= 128,
              Set(events.map(\.eventId)).count == events.count,
              events.allSatisfy({ $0.deviceId == deviceId }) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        for event in events { try event.validate() }
    }
}

/// Only closed broker event labels enter this service-owned journal. Failure
/// to append cannot turn a completed device mutation into a safe retry.
final class WorkbenchDeviceEventJournal {
    private let db: OpaquePointer
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("/../") else {
            throw WorkbenchIPCError(.invalidConfiguration)
        }
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
            try execute("CREATE TABLE IF NOT EXISTS events (event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, record BLOB NOT NULL)")
        } catch { sqlite3_close(pointer); throw error }
    }
    deinit { sqlite3_close(db) }

    func append(deviceId: String, kind: String, outcome: String) throws {
        let event = WorkbenchDeviceEvent(deviceId: deviceId, kind: kind, outcome: outcome)
        try event.validate()
        let data = try encoder.encode(event)
        guard data.count <= 2048 else { throw WorkbenchIPCError(.resourceLimit) }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let query = try statement("INSERT INTO events (event_id, device_id, record) VALUES (?, ?, ?)")
            bind(event.eventId, at: 1, to: query)
            bind(event.deviceId, at: 2, to: query)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(query, 3, bytes.baseAddress, Int32(bytes.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            let inserted = sqlite3_step(query) == SQLITE_DONE
            sqlite3_finalize(query)
            guard inserted else { throw WorkbenchIPCError(.unavailable) }
            try execute("DELETE FROM events WHERE rowid NOT IN (SELECT rowid FROM events ORDER BY rowid DESC LIMIT 4096)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func read(deviceId: String) throws -> WorkbenchDeviceLogRead {
        guard WorkspaceValidation.id(deviceId) else { throw WorkbenchIPCError(.invalidRequest) }
        lock.lock(); defer { lock.unlock() }
        let query = try statement("SELECT record FROM events WHERE device_id = ? ORDER BY rowid DESC LIMIT 129")
        defer { sqlite3_finalize(query) }
        bind(deviceId, at: 1, to: query)
        var events: [WorkbenchDeviceEvent] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else {
                throw WorkbenchIPCError(.unavailable)
            }
            let count = Int(sqlite3_column_bytes(query, 0))
            guard (1...2048).contains(count) else { throw WorkbenchIPCError(.unavailable) }
            events.append(try decoder.decode(WorkbenchDeviceEvent.self,
                from: Data(bytes: bytes, count: count)))
        }
        let result = WorkbenchDeviceLogRead(deviceId: deviceId,
            events: Array(events.prefix(128)), truncated: events.count > 128)
        try result.validate()
        return result
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
