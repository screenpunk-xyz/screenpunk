import Foundation
import AppKit
import Darwin
import Security
import ScreenpunkDistribution

/// Independent host-owned evidence for a CLI-only broker. Empty RPC consumer
/// data is not evidence of absence. Every same-user process must be classified,
/// and its PID/start/image/path inventory must stay unchanged across the check.
struct WorkbenchGUIAbsenceProbe {
    struct ProcessIdentity: Equatable {
        let pid: Int32
        let uid: uid_t
        let path: String
        let started: UInt64
        let image: Data
    }
    enum CodeIdentity: Equatable { case approvedGUI, other, unknown }
    private let uid: uid_t
    private let snapshot: () throws -> [ProcessIdentity]
    private let codeIdentity: (ProcessIdentity) -> CodeIdentity
    private let applicationPresent: () -> Bool
    private let uptime: () -> TimeInterval

    // Private fixture seam. Production only supplies libproc/AppKit/Security.
    init(uid: uid_t, snapshot: @escaping () throws -> [ProcessIdentity],
         codeIdentity: @escaping (ProcessIdentity) -> CodeIdentity,
         applicationPresent: @escaping () -> Bool,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uid = uid; self.snapshot = snapshot; self.codeIdentity = codeIdentity
        self.applicationPresent = applicationPresent
        self.uptime = uptime
    }

    func assertAbsent() throws {
        let deadline = uptime() + 2
        guard !applicationPresent() else { throw DistributionError.unavailable }
        let before = try checkedSnapshot()
        for process in before {
            // Known legacy GUI writers may not satisfy the new GUI requirement.
            guard uptime() < deadline,
                  !process.path.contains("/Screenpunk.app/Contents/MacOS/"),
                  codeIdentity(process) == .other else { throw DistributionError.unavailable }
        }
        let after = try checkedSnapshot()
        guard before == after, !applicationPresent(), uptime() < deadline else {
            throw DistributionError.unavailable
        }
    }

    private func checkedSnapshot() throws -> [ProcessIdentity] {
        let values = try snapshot()
        guard !values.isEmpty, values.count <= 16_384,
              Set(values.map(\.pid)).count == values.count,
              values.allSatisfy({ $0.pid > 0 && $0.uid == uid && $0.path.hasPrefix("/")
                  && !$0.path.utf8.contains(0) && $0.started > 0 && $0.image.count == 16 }) else {
            throw DistributionError.unavailable
        }
        return values.sorted { $0.pid < $1.pid }
    }

    static func production() throws -> Self {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(WorkbenchGUIVerifierPolicy.productionRequirement as CFString,
            SecCSFlags(), &parsed) == errSecSuccess, let requirement = parsed else {
            throw DistributionError.unavailable
        }
        let uid = geteuid()
        return Self(uid: uid, snapshot: { try liveSnapshot(uid: uid) }, codeIdentity: { process in
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: process.pid)] as CFDictionary
            var guest: SecCode?
            let copied = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest)
            if copied == errSecCSUnsigned { return .other }
            guard copied == errSecSuccess, let guest else { return .unknown }
            switch SecCodeCheckValidity(guest, SecCSFlags(), requirement) {
            case errSecSuccess: return .approvedGUI
            case errSecCSReqFailed, errSecCSUnsigned: return .other
            default: return .unknown
            }
        }, applicationPresent: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "xyz.screenpunk.macos").isEmpty
        })
    }

    private static func liveSnapshot(uid: uid_t) throws -> [ProcessIdentity] {
        let required = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard required > 0, required <= 16_384 * MemoryLayout<pid_t>.size else {
            throw DistributionError.unavailable
        }
        // Spare capacity detects growth rather than silently accepting truncation.
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.size + 64)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) < capacity,
              Int(bytes) % MemoryLayout<pid_t>.size == 0 else { throw DistributionError.unavailable }
        return try pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == uid else { throw DistributionError.unavailable }
            var path = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0, length < path.count else { throw DistributionError.unavailable }
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { throw DistributionError.unavailable }
            let image = withUnsafeBytes(of: usage.ri_uuid) { Data($0) }
            return ProcessIdentity(pid: pid, uid: info.pbi_uid, path: String(cString: path),
                                   started: usage.ri_proc_start_abstime, image: image)
        }
    }
}
