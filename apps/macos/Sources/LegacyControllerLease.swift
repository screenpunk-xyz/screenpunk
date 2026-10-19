import Darwin
import Foundation

/// Transitional old-writer exclusion until the full GUI forwards to the broker.
/// Uses the broker host's controller-home lock file, not socket path presence.
final class LegacyControllerLease {
    private let descriptor: Int32

    init(home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let directory = Darwin.open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LegacyControllerLeaseError.unsafeHome }
        defer { Darwin.close(directory) }
        let file = openat(directory, "workbench-owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw LegacyControllerLeaseError.unsafeHome }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o7777 == 0o600, metadata.st_nlink == 1 else {
            Darwin.close(file); throw LegacyControllerLeaseError.unsafeHome
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(file); throw LegacyControllerLeaseError.brokerActive
        }
        descriptor = file
    }

    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

enum LegacyControllerLeaseError: LocalizedError {
    case unsafeHome, brokerActive
    var errorDescription: String? {
        switch self {
        case .unsafeHome: "The controller home or owner lock is unsafe; the legacy workbench did not start."
        case .brokerActive: "Another Screenpunk controller owns this home. The legacy workbench cannot start a second controller; use the compatible service setup if this is the Screenpunk broker."
        }
    }
}
