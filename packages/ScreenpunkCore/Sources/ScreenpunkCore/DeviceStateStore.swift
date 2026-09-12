import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Device-side state that must survive an app relaunch: the single owner, the
/// active revision, and the last deployment record. Package bytes live next to
/// it in an atomically swapped directory. No credentials are stored here; the
/// TLS identity stays in the keychain and the owner is a public-key pin.
public struct DevicePersistedState: Sendable, Equatable, Codable {
    public var owner: PairingIdentity?
    public var activeRevision: String?
    public var activeStoredRevision: StoredRevision?
    public var lastDeployment: DeploymentRecord?
    public var savedAt: Date

    public init(
        owner: PairingIdentity?,
        activeRevision: String?,
        activeStoredRevision: StoredRevision?,
        lastDeployment: DeploymentRecord?,
        savedAt: Date = Date()
    ) {
        self.owner = owner
        self.activeRevision = activeRevision
        self.activeStoredRevision = activeStoredRevision
        self.lastDeployment = lastDeployment
        self.savedAt = savedAt
    }

    public init(runtime: DeviceRuntime, activeStoredRevision: StoredRevision?, savedAt: Date = Date()) {
        self.init(
            owner: runtime.pairing.owner,
            activeRevision: runtime.activeRevision,
            activeStoredRevision: activeStoredRevision,
            lastDeployment: runtime.lastDeployment,
            savedAt: savedAt
        )
    }
}

public enum DeviceStateStoreError: Error, Equatable {
    case invalidPath(String)
    case swapFailed
}

/// File layout under `root`:
/// - `device-state.json` — `DevicePersistedState`, replaced with `rename(2)`.
/// - `package/` — files of `activeRevision`; staged as `package.staging-*` and
///   swapped in only after the transfer activated, so a failed transfer never
///   touches the current package.
public struct DeviceStateStore: Sendable {
    public let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["SCREENPUNK_DEVICE_HOME"], override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("xyz.screenpunk.device", isDirectory: true)
    }

    public var stateURL: URL { root.appendingPathComponent("device-state.json") }
    public var packageURL: URL { root.appendingPathComponent("package", isDirectory: true) }

    public var hasState: Bool { fileManager.fileExists(atPath: stateURL.path) }
    public var hasPackage: Bool { fileManager.fileExists(atPath: packageURL.path) }

    // MARK: State

    public func load() -> DevicePersistedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DevicePersistedState.self, from: data)
    }

    public func save(_ state: DevicePersistedState) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let temp = root.appendingPathComponent("device-state.json.tmp-\(UUID().uuidString)")
        try encoder.encode(state).write(to: temp, options: .atomic)
        try atomicReplace(from: temp, to: stateURL)
    }

    // MARK: Package

    /// Writes `files` into a fresh staging directory. Paths must already be
    /// package-relative; traversal is rejected here as a second line of defense.
    public func stagePackage(_ files: [(path: String, data: Data)]) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("package.staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                let path = try PackagePath.normalize(file.path)
                guard path.isEmpty == false, path.hasSuffix("/") == false else {
                    throw DeviceStateStoreError.invalidPath(file.path)
                }
                let destination = staging.appendingPathComponent(path)
                guard destination.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
                    throw DeviceStateStoreError.invalidPath(file.path)
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Swaps the staged directory in as `package/`. The previous package is
    /// moved aside first and restored if the swap fails, so the device never
    /// ends up without its current package.
    public func activatePackage(staged: URL) throws {
        let previous = root.appendingPathComponent("package.previous-\(UUID().uuidString)", isDirectory: true)
        let hadPackage = hasPackage
        if hadPackage {
            try fileManager.moveItem(at: packageURL, to: previous)
        }
        do {
            try fileManager.moveItem(at: staged, to: packageURL)
        } catch {
            if hadPackage {
                try? fileManager.moveItem(at: previous, to: packageURL)
            }
            throw DeviceStateStoreError.swapFailed
        }
        if hadPackage {
            try? fileManager.removeItem(at: previous)
        }
    }

    public func discardStaged(_ staged: URL) {
        try? fileManager.removeItem(at: staged)
    }

    /// Relative path → bytes for the active package, sorted by path.
    public func loadPackageFiles() throws -> [(path: String, data: Data)] {
        guard hasPackage else { return [] }
        let base = packageURL.standardizedFileURL.path
        var files: [(path: String, data: Data)] = []
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            files.append((relative, try Data(contentsOf: item)))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Unlink: everything under `root` goes, including leftovers from
    /// interrupted transfers.
    public func erase() throws {
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    // MARK: Helpers

    private func atomicReplace(from source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let sourcePath, let destinationPath else { return -1 }
                return rename(sourcePath, destinationPath)
            }
        }
        if status != 0 {
            try? fileManager.removeItem(at: source)
            throw DeviceStateStoreError.swapFailed
        }
    }
}

extension DeviceRuntime {
    /// Rebuilds owner, active revision, and last deployment from disk. Any
    /// in-flight pairing session or staged revision is dropped; those never persist.
    public mutating func restore(_ state: DevicePersistedState) {
        pairing = DevicePairingState(owner: state.owner)
        activeRevision = state.activeRevision
        stagedRevision = nil
        lastDeployment = state.lastDeployment
    }
}
