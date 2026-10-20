import Foundation
import AppKit
import Darwin
import Security
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
        let guis = NSRunningApplication.runningApplications(withBundleIdentifier: "xyz.screenpunk.macos")
        let guiRunning = guis.contains { !isCompatiblePeer(pid: $0.processIdentifier, gui: true) }
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
            let executable = String(cString: path)
            if isKnownLegacyWriter(path: executable), isCompatiblePeer(pid: pid, gui: executable.hasSuffix("/Screenpunk")) { continue }
            executablePaths.append(executable)
        }
        return Snapshot(guiRunning: guiRunning, executablePaths: executablePaths)
    }

    /// A path or bundle identifier alone never proves a process cooperates.
    /// The protocol declaration is read from the live process's authenticated code signature.
    private static func isCompatiblePeer(pid: pid_t, gui: Bool) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
            SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"77KASWDGM6\""
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signed = information as? [String: Any],
              let plist = signed[kSecCodeInfoPList as String] as? [String: Any] else { return false }
        return acceptsCooperatingCode(identifier: signed[kSecCodeInfoIdentifier as String] as? String,
            team: signed[kSecCodeInfoTeamIdentifier as String] as? String,
            protocolVersion: plist["ScreenpunkWorkbenchOwnershipProtocol"] as? String, gui: gui)
    }

    static func acceptsCooperatingCode(identifier: String?, team: String?, protocolVersion: String?, gui: Bool) -> Bool {
        team == "77KASWDGM6" && protocolVersion == "workbench-owner-lock-v1" &&
            identifier == (gui ? "xyz.screenpunk.macos" : "xyz.screenpunk.workbench.tool")
    }

    static func isKnownLegacyWriter(path: String) -> Bool {
        path.contains("/Screenpunk.app/Contents/MacOS/") ||
        path.contains("/tools/screenpunk-mcp/") ||
        path.contains(".app/Contents/MacOS/screenpunk-mcp") ||
        (path.hasSuffix("/screenpunk-mcp") && !path.contains("/screenpunk-workbench/"))
    }
}
