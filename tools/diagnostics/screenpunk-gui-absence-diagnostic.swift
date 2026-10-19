// Read-only diagnostic for the immutable Screenpunk CLI 1.0.5 GUI-absence guard.
// This program never controls a service, changes configuration, or authorizes removal.
// Native API and guard order match the recorded 1.0.5 release; only diagnostic fields differ.

import Foundation
import Darwin

enum DistributionError: Error { case unavailable }
enum WorkbenchGUIVerifierPolicy {
    // Exact fixed1.0.5 production team/identifier requirement. No argument,
    // environment, caller PID or wire data can override it.
    static var productionRequirement: String {
        #"anchor apple generic and certificate leaf[subject.OU] = "77KASWDGM6" and identifier "xyz.screenpunk.macos""#
    }
}
enum ProbeDiagnostics {
    static var stage = "not_started"
    static var phase = "initialization"
    static var pid: Int32 = 0
    static var initialCount = 0
    static var finalCount = 0
    static var inventoriesMatch: Bool? = nil
    static var applicationPresent = false
    static var approvedGUI = false
    static var legacyPathCandidate = false
    static var securityStatus = 0
    static var nativeResult = 0
    static var nativeErrno = 0
    static var observedUID: Int? = nil
    static var deadlineExpired: Bool? = nil
    static func withinDeadline(_ now: TimeInterval, _ deadline: TimeInterval) -> Bool {
        deadlineExpired = now >= deadline
        return now < deadline
    }
}

import Foundation
import AppKit
import Darwin
import Security

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
        ProbeDiagnostics.stage = "application_presence"
        let deadline = uptime() + 2
        guard !applicationPresent() else { throw DistributionError.unavailable }
        ProbeDiagnostics.phase = "initial_snapshot"
        let before = try checkedSnapshot()
        ProbeDiagnostics.initialCount = before.count
        for process in before {
            ProbeDiagnostics.stage = "process_classification"
            ProbeDiagnostics.pid = process.pid
            ProbeDiagnostics.legacyPathCandidate = process.path.contains("/Screenpunk.app/Contents/MacOS/")
            // Known legacy GUI writers may not satisfy the new GUI requirement.
            guard ProbeDiagnostics.withinDeadline(uptime(), deadline),
                  !process.path.contains("/Screenpunk.app/Contents/MacOS/"),
                  codeIdentity(process) == .other else { throw DistributionError.unavailable }
        }
        ProbeDiagnostics.phase = "final_snapshot"
        let after = try checkedSnapshot()
        ProbeDiagnostics.finalCount = after.count
        ProbeDiagnostics.inventoriesMatch = before == after
        ProbeDiagnostics.stage = "final_inventory_application_deadline_check"
        guard before == after, !applicationPresent(), ProbeDiagnostics.withinDeadline(uptime(), deadline) else {
            throw DistributionError.unavailable
        }
    }

    private func checkedSnapshot() throws -> [ProcessIdentity] {
        let values = try snapshot()
        ProbeDiagnostics.stage = "inventory_validation"
        guard !values.isEmpty, values.count <= 16_384,
              Set(values.map(\.pid)).count == values.count,
              values.allSatisfy({ $0.pid > 0 && $0.uid == uid && $0.path.hasPrefix("/")
                  && !$0.path.utf8.contains(0) && $0.started > 0 && $0.image.count == 16 }) else {
            throw DistributionError.unavailable
        }
        return values.sorted { $0.pid < $1.pid }
    }

    static func production() throws -> Self {
        ProbeDiagnostics.stage = "requirement_parse"
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(WorkbenchGUIVerifierPolicy.productionRequirement as CFString,
            SecCSFlags(), &parsed) == errSecSuccess, let requirement = parsed else {
            throw DistributionError.unavailable
        }
        let uid = geteuid()
        return Self(uid: uid, snapshot: { try liveSnapshot(uid: uid) }, codeIdentity: { process in
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: process.pid)] as CFDictionary
            var guest: SecCode?
            ProbeDiagnostics.stage = "security_guest_copy"
            let copied = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest)
            ProbeDiagnostics.securityStatus = Int(copied)
            if copied == errSecCSUnsigned { return .other }
            guard copied == errSecSuccess, let guest else { return .unknown }
            ProbeDiagnostics.stage = "security_requirement_check"
            let checked = SecCodeCheckValidity(guest, SecCSFlags(), requirement)
            ProbeDiagnostics.securityStatus = Int(checked)
            switch checked {
            case errSecSuccess: ProbeDiagnostics.approvedGUI = true; return .approvedGUI
            case errSecCSReqFailed, errSecCSUnsigned: return .other
            default: return .unknown
            }
        }, applicationPresent: {
            let present = !NSRunningApplication.runningApplications(withBundleIdentifier: "xyz.screenpunk.macos").isEmpty
            ProbeDiagnostics.applicationPresent = present
            return present
        })
    }

    private static func liveSnapshot(uid: uid_t) throws -> [ProcessIdentity] {
        ProbeDiagnostics.stage = "process_list_capacity"
        let required = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        ProbeDiagnostics.nativeResult = Int(required)
        ProbeDiagnostics.nativeErrno = Int(errno)
        guard required > 0, required <= 16_384 * MemoryLayout<pid_t>.size else {
            throw DistributionError.unavailable
        }
        // Spare capacity detects growth rather than silently accepting truncation.
        var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.size + 64)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        ProbeDiagnostics.stage = "process_list_snapshot"
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        ProbeDiagnostics.nativeResult = Int(bytes)
        ProbeDiagnostics.nativeErrno = Int(errno)
        guard bytes > 0, Int(bytes) < capacity,
              Int(bytes) % MemoryLayout<pid_t>.size == 0 else { throw DistributionError.unavailable }
        return try pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { pid in
            ProbeDiagnostics.pid = pid
            ProbeDiagnostics.stage = "process_bsd_info"
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let copiedInfo = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            ProbeDiagnostics.nativeResult = Int(copiedInfo)
            ProbeDiagnostics.nativeErrno = Int(errno)
            ProbeDiagnostics.observedUID = copiedInfo == size ? Int(info.pbi_uid) : nil
            guard copiedInfo == size,
                  info.pbi_uid == uid else { throw DistributionError.unavailable }
            ProbeDiagnostics.stage = "process_executable_path"
            var path = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            ProbeDiagnostics.nativeResult = Int(length)
            ProbeDiagnostics.nativeErrno = Int(errno)
            guard length > 0, length < path.count else { throw DistributionError.unavailable }
            ProbeDiagnostics.stage = "process_usage_identity"
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            ProbeDiagnostics.nativeResult = Int(result)
            ProbeDiagnostics.nativeErrno = Int(errno)
            guard result == 0 else { throw DistributionError.unavailable }
            let image = withUnsafeBytes(of: usage.ri_uuid) { Data($0) }
            return ProcessIdentity(pid: pid, uid: info.pbi_uid, path: String(cString: path),
                                   started: usage.ri_proc_start_abstime, image: image)
        }
    }
}

import Foundation
import Darwin

let start = ProcessInfo.processInfo.systemUptime
var passed = false
do { try WorkbenchGUIAbsenceProbe.production().assertAbsent(); passed = true }
catch { }
let value: [String: Any] = [
    "diagnosticOnly": true,
    "releasedProbeVersion": "1.0.5",
    "nativeAbsenceProbePassed": passed,
    "stage": ProbeDiagnostics.stage,
    "phase": ProbeDiagnostics.phase,
    "pid": ProbeDiagnostics.pid,
    "initialCount": ProbeDiagnostics.initialCount,
    "finalCount": ProbeDiagnostics.finalCount,
    "inventoriesMatch": ProbeDiagnostics.inventoriesMatch.map { $0 as Any } ?? NSNull(),
    "applicationPresent": ProbeDiagnostics.applicationPresent,
    "approvedGUI": ProbeDiagnostics.approvedGUI,
    "legacyPathCandidate": ProbeDiagnostics.legacyPathCandidate,
    "lastSecurityStatus": ProbeDiagnostics.securityStatus,
    "lastNativeResult": ProbeDiagnostics.nativeResult,
    "lastNativeErrno": ProbeDiagnostics.nativeErrno,
    "lastObservedUID": ProbeDiagnostics.observedUID.map { $0 as Any } ?? NSNull(),
    "deadlineExpired": ProbeDiagnostics.deadlineExpired.map { $0 as Any } ?? NSNull(),
    "elapsedMilliseconds": Int((ProcessInfo.processInfo.systemUptime-start)*1000),
    "authorizesLifecycleMutation": false
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value,options:[.sortedKeys]))
FileHandle.standardOutput.write(Data("\n".utf8))
exit(passed ? 0 : 8)
