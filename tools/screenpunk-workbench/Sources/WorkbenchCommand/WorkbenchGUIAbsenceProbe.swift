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
    // Only complete-inventory churn or definite vanished-process metadata errors retry.
    enum InventoryFailure: Error { case changed }
    private let snapshot: (TimeInterval) throws -> [ProcessIdentity]
    private let codeIdentity: (ProcessIdentity) -> CodeIdentity
    private let applicationPresent: () -> Bool
    private let uptime: () -> TimeInterval

    // Private fixture seam. Production only supplies libproc/AppKit/Security.
    init(uid: uid_t, snapshot: @escaping () throws -> [ProcessIdentity],
         codeIdentity: @escaping (ProcessIdentity) -> CodeIdentity,
         applicationPresent: @escaping () -> Bool,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uid = uid; self.snapshot = { _ in try snapshot() }; self.codeIdentity = codeIdentity
        self.applicationPresent = applicationPresent
        self.uptime = uptime
    }

    private init(uid: uid_t, deadlineSnapshot: @escaping (TimeInterval) throws -> [ProcessIdentity],
                 codeIdentity: @escaping (ProcessIdentity) -> CodeIdentity,
                 applicationPresent: @escaping () -> Bool) {
        self.uid = uid; self.snapshot = deadlineSnapshot; self.codeIdentity = codeIdentity
        self.applicationPresent = applicationPresent
        self.uptime = { ProcessInfo.processInfo.systemUptime }
    }

    func assertAbsent() throws {
        // Each attempt discards all evidence from the previous one. Retain the
        // released two-second proof budget, with at most two attempts/four seconds.
        // Native calls are synchronous: expiration prevents further reads but
        // cannot interrupt an in-flight AppKit, libproc or Security call.
        let overallDeadline = uptime() + 4
        for attempt in 0..<2 {
            let deadline = min(overallDeadline, uptime() + 2)
            do {
                try assertAbsent(deadline: deadline)
                return
            } catch is InventoryFailure {
                guard attempt == 0, uptime() < deadline, uptime() < overallDeadline else {
                    throw DistributionError.unavailable
                }
            }
        }
        throw DistributionError.unavailable
    }

    private func assertAbsent(deadline: TimeInterval) throws {
        guard uptime() < deadline, !applicationPresent(), uptime() < deadline else {
            throw DistributionError.unavailable
        }
        let before = try checkedSnapshot(deadline: deadline)
        for process in before {
            // Known legacy GUI writers may not satisfy the new GUI requirement.
            guard uptime() < deadline,
                  !process.path.contains("/Screenpunk.app/Contents/MacOS/"),
                  codeIdentity(process) == .other else { throw DistributionError.unavailable }
        }
        guard uptime() < deadline else { throw DistributionError.unavailable }
        let after = try checkedSnapshot(deadline: deadline)
        // Known GUI evidence or expiry is terminal, even if inventory also changed.
        guard uptime() < deadline, !applicationPresent(), uptime() < deadline else {
            throw DistributionError.unavailable
        }
        guard before == after else { throw InventoryFailure.changed }
    }

    private func checkedSnapshot(deadline: TimeInterval) throws -> [ProcessIdentity] {
        guard uptime() < deadline else { throw DistributionError.unavailable }
        let values = try snapshot(deadline)
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
        return Self(uid: uid, deadlineSnapshot: { try liveSnapshot(uid: uid, deadline: $0) }, codeIdentity: { process in
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

    private static func liveSnapshot(uid: uid_t, deadline: TimeInterval) throws -> [ProcessIdentity] {
        try checkDeadline(deadline)
        let required = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard required > 0, required <= 16_384 * MemoryLayout<pid_t>.size else {
            throw DistributionError.unavailable
        }
        // Spare capacity detects growth rather than silently accepting truncation.
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.size + 64)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        try checkDeadline(deadline)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) <= capacity,
              Int(bytes) % MemoryLayout<pid_t>.size == 0 else { throw DistributionError.unavailable }
        guard Int(bytes) < capacity else { throw InventoryFailure.changed }
        return try pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            try checkDeadline(deadline)
            errno = 0
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                throw metadataFailure(errno)
            }
            guard info.pbi_uid == uid else { throw DistributionError.unavailable }
            var path = [CChar](repeating: 0, count: 4096)
            try checkDeadline(deadline)
            errno = 0
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { throw metadataFailure(errno) }
            guard length < path.count else { throw DistributionError.unavailable }
            var usage = rusage_info_v2()
            try checkDeadline(deadline)
            errno = 0
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { throw metadataFailure(errno) }
            let image = withUnsafeBytes(of: usage.ri_uuid) { Data($0) }
            return ProcessIdentity(pid: pid, uid: info.pbi_uid, path: String(cString: path),
                                   started: usage.ri_proc_start_abstime, image: image)
        }
    }
    private static func checkDeadline(_ deadline: TimeInterval) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw DistributionError.unavailable
        }
    }

    static func metadataFailure(_ error: Int32) -> Error {
        if error == ESRCH || error == ENOENT { return InventoryFailure.changed }
        return DistributionError.unavailable
    }

}
