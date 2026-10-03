import Foundation
import AppKit
import Darwin
import ScreenpunkController

/// Old GUI and legacy MCP binaries do not honor the Workbench owner lock.
/// Recheck before every service mutation, including selection, so a known
/// incompatible process cannot silently write the same controller authority.
enum WorkbenchLegacyOwnerGate {
    static func assertNoKnownWriter() throws {
        try assertNoKnownWriter(snapshot: liveSnapshot)
    }

    // The snapshot seam lets service tests use a complete, owned process
    // inventory. Production always supplies the live AppKit/libproc snapshot.
    static func assertNoKnownWriter(snapshot: () throws -> Snapshot) throws {
        let observed = try snapshot()
        if observed.guiRunning || observed.executablePaths.contains(where: isKnownLegacyWriter(path:)) {
            throw WorkbenchIPCError(.incompatibleOwner)
        }
    }

    struct Snapshot {
        let guiRunning: Bool
        let executablePaths: [String]
    }

    private static func liveSnapshot() throws -> Snapshot {
        let guiRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "xyz.screenpunk.macos").isEmpty
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0, byteCount <= 4 * 1024 * 1024 else { throw WorkbenchIPCError(.incompatibleOwner) }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { throw WorkbenchIPCError(.incompatibleOwner) }
        var executablePaths: [String] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 && pid != getpid() {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            executablePaths.append(String(cString: path))
        }
        return Snapshot(guiRunning: guiRunning, executablePaths: executablePaths)
    }

    static func isKnownLegacyWriter(path: String) -> Bool {
        path.contains("/Screenpunk.app/Contents/MacOS/") ||
        path.contains("/tools/screenpunk-mcp/") ||
        path.contains(".app/Contents/MacOS/screenpunk-mcp") ||
        (path.hasSuffix("/screenpunk-mcp") && !path.contains("/screenpunk-workbench/"))
    }
}
