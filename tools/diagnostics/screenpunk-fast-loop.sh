#!/bin/bash
set -euo pipefail
sp_fast_mode=${1:-fixtures}
case "$sp_fast_mode" in fixtures|native) ;; *) echo 'Use fixtures (default) or native.' >&2; exit 64;; esac
if [ "$#" -gt 1 ]; then echo 'Use fixtures (default) or native.' >&2; exit 64; fi
sp_fast_root=${SCREENPUNK_FAST_LOOP_ROOT:-/private/tmp/screenpunk-cli-upgrade-diagnostic-2026-10-05}
# Validate lexical components and the existing physical parent before writing.
if [[ ! "$sp_fast_root" =~ ^/private/tmp/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
    echo 'Scratch needs an unambiguous absolute path under /private/tmp.' >&2; exit 64
fi
sp_fast_relative=${sp_fast_root#/private/tmp/}
IFS=/ read -r -a sp_fast_components <<< "$sp_fast_relative"
for sp_fast_component in "${sp_fast_components[@]}"; do
    case "$sp_fast_component" in .|..) echo 'Dot path components are refused.' >&2; exit 64;; esac
done
sp_fast_parent=${sp_fast_root%/*}
if [ ! -d "$sp_fast_parent" ] || [ "$(cd "$sp_fast_parent" && pwd -P)" != "$sp_fast_parent" ]; then
    echo 'Scratch parent must already exist without symlink components.' >&2; exit 73
fi
sp_fast_owner=01a0ed60-173a-7db3-9a6d-d3ec593130f9
umask 077
if [ -L "$sp_fast_root" ]; then echo 'Refusing symlink scratch root.' >&2; exit 73; fi
if [ -e "$sp_fast_root" ]; then
    if [ ! -d "$sp_fast_root" ] || [ "$(stat -f %u "$sp_fast_root")" != "$(id -u)" ] || [ "$(stat -f %Lp "$sp_fast_root")" != 700 ]; then
        echo 'Scratch ownership/permissions do not match.' >&2; exit 73
    fi
    if [ -e "$sp_fast_root/owner.txt" ] || [ -L "$sp_fast_root/owner.txt" ]; then
        if [ -L "$sp_fast_root/owner.txt" ] || [ ! -f "$sp_fast_root/owner.txt" ] || [ "$(stat -f %u "$sp_fast_root/owner.txt")" != "$(id -u)" ] || [ "$(stat -f %l "$sp_fast_root/owner.txt")" != 1 ] || [ "$(cat "$sp_fast_root/owner.txt")" != "$sp_fast_owner" ]; then
            echo 'Scratch belongs to another task or is unowned.' >&2; exit 73
        fi
    else
        if [ -L "$sp_fast_root/ownership.json" ] || [ ! -f "$sp_fast_root/ownership.json" ] || [ "$(stat -f %u "$sp_fast_root/ownership.json")" != "$(id -u)" ] || [ "$(stat -f %l "$sp_fast_root/ownership.json")" != 1 ] || [ "$(/usr/bin/plutil -extract ownerChat raw -o - "$sp_fast_root/ownership.json" 2>/dev/null || true)" != "$sp_fast_owner" ]; then
            echo 'Scratch belongs to another task or is unowned.' >&2; exit 73
        fi
    fi
    if [ "$(cd "$sp_fast_root" && pwd -P)" != "$sp_fast_root" ]; then
        echo 'Refusing symlink path component.' >&2; exit 73
    fi
fi
for sp_fast_member in fast-loop-source.swift fast-loop fast-loop-ownership.json module-cache evidence run.lock; do
    if [ -L "$sp_fast_root/$sp_fast_member" ]; then echo 'Refusing symlink output member.' >&2; exit 73; fi
done
for sp_fast_member in fast-loop-source.swift fast-loop fast-loop-ownership.json; do
    if [ -e "$sp_fast_root/$sp_fast_member" ]; then
        if [ ! -f "$sp_fast_root/$sp_fast_member" ] || [ "$(stat -f %u "$sp_fast_root/$sp_fast_member")" != "$(id -u)" ] || [ "$(stat -f %l "$sp_fast_root/$sp_fast_member")" != 1 ]; then
            echo 'Refusing unsafe output file.' >&2; exit 73
        fi
    fi
done
# Pure guard is also tested with controlled disk/usage samples; no cleanup.
sp_fast_storage_guard() {
    local available=$1 used=$2 cache=$3 receipts=$4 evidence=$5 reserve=$6 new_receipts=$7 value
    for value in "$available" "$used" "$cache" "$receipts" "$evidence" "$reserve" "$new_receipts"; do
        case "$value" in ''|*[!0-9]*) echo 'Storage measurement unavailable.' >&2; return 75;; esac
        if [ "${#value}" -gt 12 ]; then echo 'Storage measurement out of range.' >&2; return 75; fi
    done
    if (( available < 20971520 )); then
        echo 'Insufficient disk space: at least 20 GiB free is required; no cleanup performed.' >&2; return 75
    fi
    if (( used + reserve > 131072 || cache > 98304 || evidence + new_receipts * 8 > 12288 || receipts + new_receipts > 200 )); then
        echo 'Scratch budget reached: 128 MiB total, 96 MiB cache, 12 MiB evidence, 200 JSON receipts; retain evidence and review exact owned cleanup.' >&2; return 75
    fi
}
sp_fast_measure_storage() {
    sp_fast_available=$(/bin/df -Pk "$sp_fast_parent" | /usr/bin/awk 'NR == 2 { print $4 }')
    sp_fast_used=0; sp_fast_cache=0; sp_fast_evidence=0; sp_fast_receipts=0
    if [ -d "$sp_fast_root" ]; then sp_fast_used=$(du -sk "$sp_fast_root" | /usr/bin/awk '{print $1}'); fi
    if [ -d "$sp_fast_root/module-cache" ]; then sp_fast_cache=$(du -sk "$sp_fast_root/module-cache" | /usr/bin/awk '{print $1}'); fi
    if [ -d "$sp_fast_root/evidence" ]; then
        sp_fast_evidence=$(du -sk "$sp_fast_root/evidence" | /usr/bin/awk '{print $1}')
        local json_files=( "$sp_fast_root/evidence/"*.json )
        if [ -e "${json_files[0]}" ]; then sp_fast_receipts=${#json_files[@]}; fi
    fi
    printf 'Storage KiB: free=%s scratch=%s cache=%s evidence=%s; JSON receipts=%s; budget=131072\n' "$sp_fast_available" "$sp_fast_used" "$sp_fast_cache" "$sp_fast_evidence" "$sp_fast_receipts" >&2
}
sp_fast_measure_storage
# Reserve 32 MiB for this fixed tiny source and two per-run JSON receipts.
sp_fast_storage_guard "$sp_fast_available" "$sp_fast_used" "$sp_fast_cache" "$sp_fast_receipts" "$sp_fast_evidence" 32768 2 || exit $?
if [ ! -e "$sp_fast_root" ]; then
    mkdir "$sp_fast_root"
    printf '%s\n' "$sp_fast_owner" > "$sp_fast_root/owner.txt"
fi
if ! mkdir "$sp_fast_root/run.lock"; then echo 'Another run or retained lock exists; stop.' >&2; exit 75; fi
trap 'rmdir "$sp_fast_root/run.lock"' EXIT
mkdir -p "$sp_fast_root/module-cache" "$sp_fast_root/evidence"
sp_fast_run=$(date -u +%Y%m%dT%H%M%SZ).$$
printf '{"ownerChat":"%s","project":"Screenpunk","purpose":"standalone guard fixture/native diagnostic loop","lifecycle":"active","budgetBytes":134217728,"resources":["fast-loop-source.swift","fast-loop","module-cache","evidence"],"keepList":["owner.txt","fast-loop-ownership.json","fast-loop-source.swift","evidence"],"createdAtUnix":%s,"lastRun":"%s","activeFixtures":[]}\n' "$sp_fast_owner" "$(stat -f %B "$sp_fast_root")" "$sp_fast_run" > "$sp_fast_root/fast-loop-ownership.json"
cat > "$sp_fast_root/fast-loop-source.swift" <<'SCREENPUNK_SWIFT_SOURCE'
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


func runNative() throws {
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

}

func runFixtures() throws {
    typealias Identity = WorkbenchGUIAbsenceProbe.ProcessIdentity
    func identity(_ pid: Int32 = 20, uid: uid_t = 503, path: String = "/fixture/cli", started: UInt64 = 100) -> Identity {
        .init(pid: pid, uid: uid, path: path, started: started, image: Data(repeating: 1, count: 16))
    }
    var cases: [[String: Any]] = []
    func check(_ name: String, expectedAbsent: Bool, _ body: () throws -> Void) {
        var absent = false
        do { try body(); absent = true } catch { }
        cases.append(["case": name, "expected": expectedAbsent ? "absence_verified" : "refusal",
                      "observed": absent ? "absence_verified" : "refusal", "passed": absent == expectedAbsent])
    }
    check("idle_complete_stable_inventory", expectedAbsent: true) {
        let values = [identity(), identity(21)]
        var reads = 0
        let probe = WorkbenchGUIAbsenceProbe(uid: 503, snapshot: {
            reads += 1; return reads == 1 ? values : values.reversed()
        }, codeIdentity: { _ in .other }, applicationPresent: { false }, uptime: { 100 })
        try probe.assertAbsent()
        guard reads == 2 else { throw DistributionError.unavailable }
    }
    check("unknown_code_identity", expectedAbsent: false) {
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { [identity()] },
            codeIdentity: { _ in .unknown }, applicationPresent: { false }, uptime: { 100 }).assertAbsent()
    }
    check("approved_gui_identity", expectedAbsent: false) {
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { [identity()] },
            codeIdentity: { _ in .approvedGUI }, applicationPresent: { false }, uptime: { 100 }).assertAbsent()
    }
    check("legacy_gui_path", expectedAbsent: false) {
        try WorkbenchGUIAbsenceProbe(uid: 503,
            snapshot: { [identity(path: "/Applications/Screenpunk.app/Contents/MacOS/Screenpunk")] },
            codeIdentity: { _ in .other }, applicationPresent: { false }, uptime: { 100 }).assertAbsent()
    }
    check("appkit_gui_present", expectedAbsent: false) {
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { [identity()] },
            codeIdentity: { _ in .other }, applicationPresent: { true }, uptime: { 100 }).assertAbsent()
    }
    check("process_exits_during_metadata_read", expectedAbsent: false) {
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { throw DistributionError.unavailable },
            codeIdentity: { _ in .other }, applicationPresent: { false }, uptime: { 100 }).assertAbsent()
    }
    check("pid_reuse_between_inventories", expectedAbsent: false) {
        var reads = 0
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: {
            reads += 1; return [identity(started: reads == 1 ? 100 : 101)]
        }, codeIdentity: { _ in .other }, applicationPresent: { false }, uptime: { 100 }).assertAbsent()
    }
    check("foreign_uid", expectedAbsent: false) {
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { [identity(uid: 504)] },
            codeIdentity: { _ in .other }, applicationPresent: { false }, uptime: { 100 }).assertAbsent()
    }
    check("classification_consumes_deadline", expectedAbsent: false) {
        var now: TimeInterval = 100
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { [identity()] },
            codeIdentity: { _ in now = 103; return .other }, applicationPresent: { false }, uptime: { now }).assertAbsent()
    }
    check("snapshot_consumes_deadline", expectedAbsent: false) {
        var now: TimeInterval = 100
        try WorkbenchGUIAbsenceProbe(uid: 503, snapshot: { now = 103; return [identity()] },
            codeIdentity: { _ in .other }, applicationPresent: { false }, uptime: { now }).assertAbsent()
    }
    let failures = cases.filter { $0["passed"] as? Bool != true }.count
    let result: [String: Any] = ["schemaVersion": 1, "mode": "fixtures", "probeVersion": "1.0.5",
        "cases": cases, "passed": failures == 0, "failureCount": failures,
        "nativeProcessInventoryRead": false, "lifecycleMutations": false,
        "scope": "actual_guard_with_synthetic_readers", "homebrewUpgradeQualified": false]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(failures == 0 ? 0 : 1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["fixtures"] { try runFixtures() }
else if arguments == ["native"] { try runNative() }
else {
    FileHandle.standardError.write(Data("Use fixtures (default) or native.\n".utf8))
    exit(64)
}
SCREENPUNK_SWIFT_SOURCE
printf '41732a1e8f99a629e476b03a216ecb8a772a47199f07df3b0acd715000276db0  %s\n' "$sp_fast_root/fast-loop-source.swift" | shasum -a 256 -c - >&2
xcrun --find swiftc > "$sp_fast_root/evidence/$sp_fast_run.toolchain.txt"
xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path "$sp_fast_root/module-cache" \
    "$sp_fast_root/fast-loop-source.swift" -o "$sp_fast_root/fast-loop" > "$sp_fast_root/evidence/$sp_fast_run.compile.log" 2>&1
sp_fast_measure_storage
printf '{"availableKiB":%s,"scratchKiB":%s,"moduleCacheKiB":%s,"evidenceKiB":%s,"jsonReceiptCount":%s,"budgetKiB":131072,"cleanupPerformed":false}\n' "$sp_fast_available" "$sp_fast_used" "$sp_fast_cache" "$sp_fast_evidence" "$sp_fast_receipts" > "$sp_fast_root/evidence/$sp_fast_run.storage.json"
sp_fast_storage_guard "$sp_fast_available" "$sp_fast_used" "$sp_fast_cache" "$sp_fast_receipts" "$sp_fast_evidence" 16 2 || exit $?
if "$sp_fast_root/fast-loop" "$sp_fast_mode" > "$sp_fast_root/evidence/$sp_fast_run.$sp_fast_mode.json"; then
    sp_fast_exit=0
else
    sp_fast_exit=$?
fi
cat "$sp_fast_root/evidence/$sp_fast_run.$sp_fast_mode.json"
printf 'Evidence: %s; exit=%s\n' "$sp_fast_root/evidence/$sp_fast_run.$sp_fast_mode.json" "$sp_fast_exit" >&2
exit "$sp_fast_exit"
