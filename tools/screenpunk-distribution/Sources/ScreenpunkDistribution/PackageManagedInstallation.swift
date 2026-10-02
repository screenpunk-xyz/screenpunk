import Foundation
import Darwin
import CryptoKit

/// Homebrew owns the immutable software and command links. This lifecycle
/// only imports verified user kits and manages the exact user LaunchAgent.
/// No persistent process is started by a Homebrew install/postflight hook.
public final class PackageManagedInstallation {
    private let root: URL
    private let paths: InstallationPaths
    private let service: LaunchdUserAdapter
    private let trust: any DistributionReleaseTrust
    private let allowLocalTest: Bool
    private let prepare: (URL, DistributionManifest) throws -> Void
    private let assertUnmanagedServiceAbsent: () throws -> AnyObject?
    private let commit: any PackageCommitChecking
    var beforeFencePublication: () throws -> Void = {}
    public init(root: URL, paths: InstallationPaths, service: LaunchdUserAdapter,
                releaseTrust: any DistributionReleaseTrust,
                allowLocalTest: Bool = false,
                prepare: @escaping (URL, DistributionManifest) throws -> Void,
                assertUnmanagedServiceAbsent: @escaping () throws -> AnyObject?,
                commit: any PackageCommitChecking) {
        self.root = root; self.paths = paths; self.service = service
        self.trust = releaseTrust; self.allowLocalTest = allowLocalTest
        self.prepare = prepare
        self.assertUnmanagedServiceAbsent = assertUnmanagedServiceAbsent
        self.commit = commit
    }

    public func start() throws {
        try withLock { directory in
            let manifest = try verify()
            guard try !removalFenceExists(directory) else { throw PackageNotReady.removalPending }
            do { try commit.assertReady(stateDirectory: directory) }
            catch { throw PackageNotReady.installationIncomplete }
            let state = try service.ownedState()
            if state == .running {
                guard try service.health(version: manifest.version) else { throw DistributionError.unavailable }
                return
            }
            guard state != .unknown else { throw DistributionError.conflict }
            do {
                let lease = try assertUnmanagedServiceAbsent()
                withExtendedLifetime(lease) {}
            }
            do { try prepare(root, manifest) }
            catch { throw PackagePreparationFailure(underlying: error) }
            do {
                try service.startOwned(serviceExecutable: root.appendingPathComponent("libexec/screenpunk-service"))
                guard try service.health(version: manifest.version) else { throw DistributionError.unavailable }
            } catch {
                let original = error
                do { _ = try service.recoverFailedActivation(plist: paths.launchAgent) }
                catch { throw PackageActivationFailure(activation: original, cleanup: error) }
                throw PackageActivationFailure(activation: original, cleanup: nil)
            }
        }
    }

    /// Called before Homebrew unlinks or purges its software. Failure leaves
    /// the installed package available for diagnosis and a later retry.
    public func deactivate() throws -> [String] {
        try withLock { directory in
            _ = try verify()
            let state = try service.ownedState()
            guard state != .unknown else { throw DistributionError.conflict }
            let lease = state == .running ? nil : try assertUnmanagedServiceAbsent()
            let interrupted = try withExtendedLifetime(lease) {
                try service.recoverFailedActivation(plist: paths.launchAgent)
            }
            try writeRemovalFence(directory)
            return interrupted
        }
    }

    /// The vendor Brew install/reinstall command clears this root's removal fence.
    /// This hook starts no process, writes no LaunchAgent, and imports no kit,
    /// so an install rollback can safely purge the staged software.
    public func rearm() throws {
        try withLock { directory in
            _ = try verify()
            guard try service.ownedState() == .absent else { throw DistributionError.conflict }
            try commit.prepareInstall(stateDirectory: directory)
            if try removalFenceExists(directory) {
                guard unlinkat(directory, fenceName, 0) == 0, fsync(directory) == 0 else {
                    throw DistributionError.unavailable
                }
            }
        }
    }

    private var fenceName: String {
        ".package-removal-" + SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined() + ".state"
    }
    private var fenceBytes: Data {
        // A fixed opaque identity record, not a source of paths or commands.
        Data(("screenpunk-homebrew-removal-v1\n" + root.path + "\n").utf8)
    }
    private func removalFenceExists(_ directory: Int32) throws -> Bool {
        let file = openat(directory, fenceName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return false }
        guard file >= 0 else { throw DistributionError.conflict }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o7777 == 0o600,
              info.st_size == fenceBytes.count else { throw DistributionError.conflict }
        var bytes = [UInt8](repeating: 0, count: fenceBytes.count)
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(file, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw DistributionError.unavailable }
            offset += count
        }
        guard Data(bytes) == fenceBytes else { throw DistributionError.conflict }
        return true
    }
    private func writeRemovalFence(_ directory: Int32) throws {
        if try removalFenceExists(directory) { return }
        let temporary = ".package-fence-" + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DistributionError.unavailable }
        defer { close(file); _ = unlinkat(directory, temporary, 0) }
        let bytes = fenceBytes
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DistributionError.unavailable }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw DistributionError.unavailable }
        try beforeFencePublication()
        guard try !removalFenceExists(directory),
              renameat(directory, temporary, directory, fenceName) == 0,
              fsync(directory) == 0 else { throw DistributionError.unavailable }
    }

    private func verify() throws -> DistributionManifest {
        var info = stat()
        // Legacy software ownership must be resolved explicitly, never
        // silently adopted or removed by the package manager.
        if lstat(paths.root.path, &info) == 0 { throw DistributionError.conflict }
        guard errno == ENOENT else { throw DistributionError.unsafeFile }
        let manifest = try DistributionArchive.verify(root: root,
            allowLocalTest: allowLocalTest, releaseTrust: trust)
        guard manifest.protocolVersion == 1 else { throw DistributionError.incompatible }
        return manifest
    }

    private func withLock<T>(_ action: (Int32) throws -> T) throws -> T {
        // Traverse each component without following symlinks. Package
        // lifecycle serialization is independent of the broker owner lock.
        let home = open(paths.home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard home >= 0 else { throw DistributionError.unsafeFile }
        var directory = home
        defer { close(directory) }
        for component in ["Library", "Application Support", "Screenpunk"] {
            var parent = stat()
            guard fstat(directory, &parent) == 0, parent.st_uid == geteuid(),
                  parent.st_mode & mode_t(0o022) == 0 else { throw DistributionError.unsafeFile }
            if mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
                throw DistributionError.unavailable
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DistributionError.unsafeFile }
            close(directory); directory = next
        }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o7777) == 0o700 else { throw DistributionError.unsafeFile }
        let lock = openat(directory, ".package-lifecycle.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw DistributionError.unsafeFile }
        defer { close(lock) }
        guard fstat(lock, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & mode_t(0o7777) == 0o600 else { throw DistributionError.unsafeFile }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DistributionError.conflict }
        defer { _ = flock(lock, LOCK_UN) }
        return try action(directory)
    }
}

/// Retains both causes; presentation must not hide the startup failure behind
/// an unregistration failure as the original installer did.
public struct PackageActivationFailure: Error {
    public let activation: any Error
    public let cleanup: (any Error)?
    public init(activation: any Error, cleanup: (any Error)?) {
        self.activation = activation; self.cleanup = cleanup
    }
}

/// Preparation failed before any launchd activation. Preserve the cause
/// without booting out an absent job or reporting a generic runtime failure.
public struct PackagePreparationFailure: Error {
    public let underlying: any Error
    public init(underlying: any Error) { self.underlying = underlying }
}

public enum PackageNotReady: Error {
    case removalPending, installationIncomplete
}
