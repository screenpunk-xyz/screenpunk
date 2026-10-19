import Foundation
@_spi(NativeFilesystem) import ScreenpunkCore
import Darwin

/// Legacy Cloud operation evidence is never interpreted or moved by Local reset.
/// Absence alone permits cleanup. Same-UID concurrent writers remain outside the reset model.
enum DeviceLocalResetLegacyCloudGuard {
    enum Failure: Error { case evidencePresent, lookup(Int32) }
    static func requireAbsent(deviceRoot: URL) throws {
        try inspect(deviceRoot: deviceRoot, beforeLookup: {})
    }
    // Fault seam for isolated tests; production always uses requireAbsent.
    static func inspect(deviceRoot: URL, beforeLookup: () throws -> Void) throws {
        guard deviceRoot.isFileURL, deviceRoot.path.hasPrefix("/") else { throw Failure.lookup(EINVAL) }
        let traversal: DeviceFilesystemTraversal
        do { traversal = try .plan(for: deviceRoot.path) } catch { throw Failure.lookup(EINVAL) }
        var descriptor = open(traversal.rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.lookup(errno) }
        defer { close(descriptor) }
        for component in traversal.components {
            guard component != ".", component != ".." else { throw Failure.lookup(EINVAL) }
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0 {
                let code = errno
                if code == ENOENT { return }
                throw Failure.lookup(code)
            }
            close(descriptor); descriptor = next
        }
        try beforeLookup()
        var info = stat()
        if fstatat(descriptor, "native-workspace-setup.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw Failure.evidencePresent
        }
        let code = errno
        guard code == ENOENT else { throw Failure.lookup(code) }
    }
}
