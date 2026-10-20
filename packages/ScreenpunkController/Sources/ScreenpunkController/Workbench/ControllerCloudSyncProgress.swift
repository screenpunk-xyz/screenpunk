import Foundation
#if os(macOS)
import CryptoKit

public struct ControllerCloudScreenSyncLocalStatus: Codable, Sendable {
    public let screenSyncEnabled: Bool
    public let selectedWorkspaceId: String?
    public let screenSyncScreens: [String: ControllerCloudScreenSyncStatus]
}

public struct ControllerCloudScreenSyncStatus: Codable, Sendable, Equatable {
    public let state: String
    public let message: String
    public let lastSuccessfulSyncAt: String?
    public let updatedAt: String
}

/// Small identity/hash evidence only. Source bytes and transport errors never enter this file.
struct ControllerCloudSyncProgressStore {
    struct Scope: Codable, Equatable { let accountId: String; let workspaceId: String; let localWorkspaceId: String }
    struct Record: Codable {
        var status: ControllerCloudScreenSyncStatus
        var acknowledgedSignature: String?
        var observedSignature: String?
    }
    struct Snapshot: Codable {
        let scope: Scope
        var cycleState: String?
        var cycleMessage: String?
        var cycleEpoch: String?
        var cycleUpdatedAt: String?
        var entries: [String: Record] = [:]
    }
    let root: URL
    let scope: Scope
    var file: URL {
        let key = SHA256.hash(data: Data((scope.accountId + "\n" + scope.workspaceId).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("sync-progress/\(scope.localWorkspaceId)/\(key).json")
    }
    func read() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(scope: scope) }
        let data = try Data(contentsOf: file)
        guard data.count <= 2 * 1024 * 1024 else { throw ControllerCloudError.invalidSource }
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        guard value.scope == scope else { throw ControllerCloudError.accountMismatch }
        return value
    }
    private func write(_ value: Snapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ControllerCloudPersistence.write(JSONEncoder().encode(value), to: file)
    }
    func cycle(_ state: String, message: String, epoch: String) throws {
        var value = try read(); value.cycleState = state; value.cycleMessage = message; value.cycleEpoch = epoch; value.cycleUpdatedAt = Self.now
        if state != "syncing" {
            for (id, record) in value.entries where record.status.state == "syncing" {
                var row = record
                row.status = .init(state: state == "error" ? "error" : "pending", message: message,
                    lastSuccessfulSyncAt: record.status.lastSuccessfulSyncAt, updatedAt: Self.now)
                value.entries[id] = row
            }
        }
        try write(value)
    }
    func screen(_ dashboard: String, state: String, signature: String? = nil, acknowledge: Bool = false, resourceLimited: Bool = false) throws {
        var value = try read()
        var row = value.entries[dashboard] ?? .init(status: .init(state: "pending", message: Self.message("pending"), lastSuccessfulSyncAt: nil, updatedAt: Self.now))
        let successfulAt = acknowledge && signature != nil && row.acknowledgedSignature != signature ? Self.now : row.status.lastSuccessfulSyncAt
        if acknowledge { row.acknowledgedSignature = signature }
        if let signature { row.observedSignature = signature }
        row.status = .init(state: state, message: resourceLimited ? Self.quotaMessage : Self.message(state), lastSuccessfulSyncAt: successfulAt, updatedAt: Self.now)
        value.entries[dashboard] = row; value.cycleUpdatedAt = Self.now; try write(value)
    }
    static var now: String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static let quotaMessage = "Cloud Screen limit reached. Your local copy is preserved."
    static func message(_ state: String) -> String {
        switch state {
        case "off": return "Screen sync is off."
        case "syncing": return "Syncing this Screen…"
        case "synced": return "This Screen is synced."
        case "error": return "This Screen could not sync. Your copies are preserved."
        default: return "This Screen has changes waiting to sync."
        }
    }
    static func signature(_ digests: [String]) -> String {
        SHA256.hash(data: Data(digests.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// A read never manufactures success or changes a persisted timestamp.
    static func display(_ record: Record?, signature: String?, enabled: Bool, active: Bool) -> ControllerCloudScreenSyncStatus {
        let state: String
        if !enabled { state = "off" }
        else if active && record?.status.state == "syncing" { state = "syncing" }
        else if signature == nil { state = "pending" }
        else if record?.status.state == "error" && record?.observedSignature == signature { state = "error" }
        else if let signature, record?.acknowledgedSignature == signature { state = "synced" }
        else { state = "pending" }
        return .init(state: state, message: state == "error" && record?.status.message == quotaMessage ? quotaMessage : message(state), lastSuccessfulSyncAt: record?.status.lastSuccessfulSyncAt,
            updatedAt: record?.status.updatedAt ?? now)
    }
}
#endif
