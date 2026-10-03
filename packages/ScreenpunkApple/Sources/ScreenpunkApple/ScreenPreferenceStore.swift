import Foundation
import Darwin
import ScreenpunkCore

/// Serializes suspension with complete synchronous accesses, including read-created
/// archives. Process-local only; external filesystem writers are not excluded.
private final class ScreenPreferenceResetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var suspended: Set<String> = []
    func suspend(_ root: String) { lock.lock(); defer { lock.unlock() }; suspended.insert(root) }
    func access<T>(_ root: String, operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !suspended.contains(root) else { throw ConnectionFailure.permissionRequired }
        return try operation()
    }
}

/// Device-local preferences, scoped by native manifest identity, never revision.
/// A lock plus atomic replacement also coordinates the Mac preview helper.
@MainActor
public final class ScreenPreferenceStore {
    public static let shared = ScreenPreferenceStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("xyz.screenpunk.preferences", isDirectory: true))
    static let valueLimit = 16 * 1024
    static let screenLimit = 128 * 1024
    static let totalLimit = 4 * 1024 * 1024
    private nonisolated static let resetGate = ScreenPreferenceResetGate()
    private nonisolated let root: URL
    private let beforeMutation: (() -> Void)?
    private struct Archive: Codable {
        var version = 1
        var generation = UUID()
        var screens: [String: [String: String]] = [:]
    }
    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); beforeMutation = nil
    }
    init(root: URL, beforeMutation: @escaping () -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.beforeMutation = beforeMutation
    }
    /// Terminal for every current/new store sharing this canonical root. No resume.
    public nonisolated func suspendForReset() { Self.resetGate.suspend(root.path) }

    func generation() throws -> UUID { try access { $0.generation } }
    func get(dashboard: String, key: String, generation: UUID) throws -> Any {
        try validate(dashboard); try validate(key)
        return try access { archive in
            guard archive.generation == generation else { throw ConnectionFailure.permissionRequired }
            guard let json = archive.screens[dashboard]?[key] else { return NSNull() }
            return try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        }
    }
    func set(dashboard: String, key: String, value: Any, generation: UUID) throws {
        try validate(dashboard); try validate(key); try validateValue(value, depth: 0)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard data.count <= Self.valueLimit else { throw ConnectionFailure.sizeLimit }
        try access(write: true) { archive in
            guard archive.generation == generation else { throw ConnectionFailure.permissionRequired }
            var screen = archive.screens[dashboard] ?? [:]
            screen[key] = String(decoding: data, as: UTF8.self)
            guard screen.count <= 128, try JSONEncoder().encode(screen).count <= Self.screenLimit else { throw ConnectionFailure.sizeLimit }
            archive.screens[dashboard] = screen
            guard archive.screens.count <= 128 else { throw ConnectionFailure.sizeLimit }
        }
    }
    func remove(dashboard: String, key: String, generation: UUID) throws {
        try validate(dashboard); try validate(key)
        try access(write: true) { archive in
            guard archive.generation == generation else { throw ConnectionFailure.permissionRequired }
            archive.screens[dashboard]?.removeValue(forKey: key)
            if archive.screens[dashboard]?.isEmpty == true { archive.screens.removeValue(forKey: dashboard) }
        }
    }
    /// Confirmed device disconnect resets all screen preferences and invalidates
    /// existing bridge leases, so a retiring WebView cannot restore old data.
    public func erase() throws {
        try access(write: true, reset: true) { $0 = Archive() }
    }
    private func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 256, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ConnectionFailure.validationFailed }
    }
    private func validateValue(_ value: Any, depth: Int) throws {
        guard depth <= 16 else { throw ConnectionFailure.sizeLimit }
        if let object = value as? [String: Any] {
            for nested in object.values { try validateValue(nested, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for nested in array { try validateValue(nested, depth: depth + 1) }
        } else if value is NSNull || value is String { return }
        else if let number = value as? NSNumber, number.doubleValue.isFinite { return }
        else { throw ConnectionFailure.validationFailed }
    }
    private func access<T>(write: Bool = false, reset: Bool = false, _ operation: (inout Archive) throws -> T) throws -> T {
        try Self.resetGate.access(root.path) {
            beforeMutation?()
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var directory = root
            var properties = URLResourceValues(); properties.isExcludedFromBackup = true
            try directory.setResourceValues(properties)
            let descriptor = Darwin.open(root.appendingPathComponent("preferences.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw ConnectionFailure.deviceOffline }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw ConnectionFailure.deviceOffline }
            defer { flock(descriptor, LOCK_UN) }
            let file = root.appendingPathComponent("preferences-v1.json")
            let exists = fm.fileExists(atPath: file.path)
            var archive: Archive
            if exists && !reset {
                let size = try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                guard (size?.intValue ?? Int.max) <= Self.totalLimit else { throw ConnectionFailure.sizeLimit }
                archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1 else { throw ConnectionFailure.deviceOffline }
            } else { archive = Archive() }
            let result = try operation(&archive)
            if write || !exists {
                let bytes = try JSONEncoder().encode(archive)
                guard bytes.count <= Self.totalLimit else { throw ConnectionFailure.sizeLimit }
                #if os(iOS)
                try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try bytes.write(to: file, options: .atomic)
                #endif
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            return result
        }
    }
}
