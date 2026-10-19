import Foundation
import Darwin
import ScreenpunkCore

/// Serializes suspension with complete synchronous accesses, including read-created
/// archives. Process-local only; external filesystem writers are not excluded.
private final class ScreenPreferenceResetGate: @unchecked Sendable {
    private let lock = NSLock()
    private final class Domain {
        let generation: UUID
        var suspended = false
        var attempt: ScreenPreferenceAtomicWriter.Attempt?
        init(generation: UUID = UUID(), suspended: Bool = false) { self.generation = generation; self.suspended = suspended }
    }
    private var domains: [String: Domain] = [:]
    func generation(_ root: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        if domains[root] == nil { domains[root] = Domain() }
        return domains[root]!.generation
    }
    func suspend(_ root: String, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard domains[root]?.generation == generation else { return }
        domains[root]?.suspended = true
    }
    func isCurrent(_ root: String, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return domains[root]?.generation == generation
    }
    func isRetired(_ root: String, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return domains[root]?.generation == generation && domains[root]?.suspended == true
    }
    @MainActor func reopen(_ root: String, generation: UUID, capability: DeviceLocalResetReopeningCapability,
                retirement: DeviceLocalResetWriterRetirement, nextGeneration: UUID, commitOtherDomain: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard capability.isConsuming(retirement), retirement.preferenceRoot.path == root, retirement.preferenceGeneration == generation, domains[root]?.generation == generation,
              domains[root]?.suspended == true else { throw ConnectionFailure.permissionRequired }
        // No throwing work, IO, await or external callback after this boundary.
        let next = Domain(generation: nextGeneration, suspended: false)
        commitOtherDomain()
        domains[root] = next
    }
    func access<T>(_ root: String, generation: UUID, recovery: Bool = false, operation: (inout ScreenPreferenceAtomicWriter.Attempt?) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard domains[root]?.generation == generation, domains[root]?.suspended == false else { throw ConnectionFailure.permissionRequired }
        guard let domain = domains[root] else { throw ConnectionFailure.permissionRequired }
        guard recovery || domain.attempt == nil else { throw ScreenPreferenceAtomicWriter.Failure.writeOutcomeUncertain }
        return try operation(&domain.attempt)
    }
}

/// Device-local preferences, scoped by native manifest identity, never revision.
/// A lock plus atomic replacement also coordinates the Mac preview helper.
@MainActor
public final class ScreenPreferenceStore {
    private static var currentShared = ScreenPreferenceStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("xyz.screenpunk.preferences", isDirectory: true))
    public static var shared: ScreenPreferenceStore { currentShared }
    static func installShared(_ store: ScreenPreferenceStore, capability: DeviceLocalResetReopeningCapability, retirement: DeviceLocalResetWriterRetirement) {
        precondition(capability.isConsuming(retirement) && currentShared.canonicalRoot == retirement.preferenceRoot && currentShared.writerGeneration == retirement.preferenceGeneration)
        currentShared = store
    }
    static let valueLimit = 16 * 1024
    static let screenLimit = 128 * 1024
    static let totalLimit = 4 * 1024 * 1024
    private nonisolated static let resetGate = ScreenPreferenceResetGate()
    private nonisolated let root: URL
    nonisolated let writerGeneration: UUID
    nonisolated var canonicalRoot: URL { root }
    private let beforeMutation: (() -> Void)?
    private let persistenceBoundary: (ScreenPreferenceAtomicWriter.Boundary) throws -> Void
    private struct Archive: Codable {
        var version = 1
        var generation = UUID()
        var screens: [String: [String: String]] = [:]
    }
    private static func canonicalPreferenceRoot(_ root: URL) -> URL { ScreenPreferenceAtomicWriter.canonicalRoot(root) }
    public init(root: URL) {
        self.root = Self.canonicalPreferenceRoot(root); beforeMutation = nil
        persistenceBoundary = { _ in }
        writerGeneration = Self.resetGate.generation(self.root.path)
    }
    init(root: URL, beforeMutation: @escaping () -> Void) {
        self.root = Self.canonicalPreferenceRoot(root); self.beforeMutation = beforeMutation
        persistenceBoundary = { _ in }
        writerGeneration = Self.resetGate.generation(self.root.path)
    }
    /// Terminal for this generation, including stores constructed before qualified reopening.
    public nonisolated func suspendForReset() { Self.resetGate.suspend(root.path, generation: writerGeneration) }

    init(root: URL, persistenceBoundary: @escaping (ScreenPreferenceAtomicWriter.Boundary) throws -> Void) {
        self.root = Self.canonicalPreferenceRoot(root); beforeMutation = nil
        self.persistenceBoundary = persistenceBoundary; writerGeneration = Self.resetGate.generation(self.root.path)
    }
    /// Recommits only the exact process-retained attempt. Normal accesses cannot clear uncertainty.
    func retryPendingWrite() throws {
        try Self.resetGate.access(root.path, generation: writerGeneration, recovery: true) { attempt in
            guard let retained = attempt else { return }
            try ScreenPreferenceAtomicWriter(root: root, boundary: persistenceBoundary).withSession { try $0.commit(retained) }
            attempt = nil
        }
    }
    private init(canonicalRoot: URL, generation: UUID) {
        root = canonicalRoot; writerGeneration = generation; beforeMutation = nil; persistenceBoundary = { _ in }
    }
    func preparedFreshStore() -> ScreenPreferenceStore { .init(canonicalRoot: root, generation: UUID()) }
    nonisolated var isCurrentWriter: Bool { Self.resetGate.isCurrent(root.path, generation: writerGeneration) }
    nonisolated var isRetired: Bool { Self.resetGate.isRetired(root.path, generation: writerGeneration) }
    func reopen(capability: DeviceLocalResetReopeningCapability, retirement: DeviceLocalResetWriterRetirement, nextGeneration: UUID, commitCalendar: () -> Void) throws {
        try Self.resetGate.reopen(root.path, generation: writerGeneration, capability: capability, retirement: retirement, nextGeneration: nextGeneration, commitOtherDomain: commitCalendar)
    }

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
        try Self.resetGate.access(root.path, generation: writerGeneration) { attempt in
            beforeMutation?()
            return try ScreenPreferenceAtomicWriter(root: root, boundary: persistenceBoundary).withSession { session in
                let baseline = try session.read()
                var archive: Archive
                if let bytes = baseline.data, !reset {
                    archive = try JSONDecoder().decode(Archive.self, from: bytes)
                    guard archive.version == 1 else { throw ConnectionFailure.deviceOffline }
                } else { archive = Archive() }
                let result = try operation(&archive)
                if write || baseline.data == nil {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let bytes = try encoder.encode(archive)
                    guard bytes.count <= Self.totalLimit else { throw ConnectionFailure.sizeLimit }
                    let retained = try session.attempt(bytes: bytes, baseline: baseline)
                    attempt = retained // Before any pending cleanup, creation or replacement.
                    try session.commit(retained)
                    attempt = nil
                }
                return result
            }
        }
    }
}
