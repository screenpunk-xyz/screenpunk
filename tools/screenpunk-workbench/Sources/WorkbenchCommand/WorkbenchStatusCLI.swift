import Foundation
import Darwin
import Security
import ScreenpunkController
import ScreenpunkDistribution

/// Evidence values are observations, never lifecycle or deployment authority.
struct WorkbenchStatusRelease: Codable, Equatable {
    var evidence: String
    var version: String?
    var packagePath: String?
}
struct WorkbenchStatusProcess: Codable, Equatable {
    var evidence: String
    var state: String
    var releaseVersion: String?
    var pid: Int32?
    var uid: UInt32?
    var executablePath: String?
}
struct WorkbenchStatusReport: Codable {
    struct Service: Codable {
        var health = "unavailable"
        var healthEvidence = "unavailable"
        var process: WorkbenchStatusProcess
        var versionComparison = "not_assessed"
        var controllerHomePath: String?
        var instanceId: String?
        var activeJobCount: Int?
        var lifecycleState: String?
        var lifecycleEvidence = "unavailable"
    }
    struct Workspace: Codable {
        var evidence = "unavailable"
        var state = "unavailable"
        var workspaceId: String?
        var path: String?
    }
    struct Device: Codable {
        var deviceId: String
        var name: String
        var ownerMatchesCurrent: Bool
        var cachedReachability: String?
        var lastSeenAt: String?
        var connectionEvidence = "not_assessed"
    }
    struct Devices: Codable {
        var evidence = "unavailable"
        var pairedCount: Int?
        var items: [Device] = []
    }
    struct MCP: Codable {
        var state = "broker_unavailable"
        var transport = "stdio"
        var installedServerEvidence = "not_assessed"
        var brokerEvidence = "unavailable"
        var clientRegistration = "not_assessed"
        var toolCatalogCount: Int?
    }
    var schemaVersion = 1
    var installedRelease: WorkbenchStatusRelease
    var service: Service
    var workspace = Workspace()
    var devices = Devices()
    var mcp = MCP()

    var human: String {
        func safe(_ text: String?) -> String { TerminalPresentation.safe(text ?? "unavailable") }
        func label(_ text: String) -> String { safe(text.replacingOccurrences(of: "_", with: " ")) }
        let installed = installedRelease.version.map { "\($0) (\(installedRelease.evidence))" }
            ?? "unavailable (\(installedRelease.evidence))"
        let running = service.process.releaseVersion.map { "\($0) (\(service.process.evidence))" }
            ?? "unavailable (\(service.process.evidence))"
        var lines = ["Screenpunk status", "  Installed release: \(safe(installed))",
                     "  Service release:   \(safe(running))"]
        if service.versionComparison == "mismatch" {
            lines.append("  VERSION MISMATCH: installed and running service releases differ")
        }
        lines.append("  Service health:    \(label(service.health)) (\(label(service.healthEvidence)))")
        if let pid = service.process.pid, let uid = service.process.uid {
            lines.append("  Owned process:     PID \(pid), UID \(uid) (\(safe(service.process.evidence)))")
        } else { lines.append("  Owned process:     \(safe(service.process.state)) (\(safe(service.process.evidence)))") }
        if let path = service.controllerHomePath { lines.append("  Controller home:   \(safe(path))") }
        lines.append("  Active jobs:       \(service.activeJobCount.map(String.init) ?? "unavailable")")
        lines.append("  Workspace:         \(safe(workspace.path ?? workspace.state)) (\(safe(workspace.evidence)))")
        lines.append("  Paired devices:    \(devices.pairedCount.map(String.init) ?? "unavailable")")
        for device in devices.items {
            let observed = device.cachedReachability.map { "last observed \($0) (cached)" }
                ?? "connection not assessed"
            lines.append("    \(safe(device.name)) — \(safe(observed))")
            if let seen = device.lastSeenAt { lines.append("      Last seen: \(safe(seen)); current connection not assessed") }
        }
        let tools = mcp.toolCatalogCount.map { "; \($0) tools in CLI catalog" } ?? ""
        lines.append("  MCP:               \(label(mcp.state))\(tools); server \(label(mcp.installedServerEvidence))")
        lines.append("                     Client registration not assessed")
        return lines.joined(separator: "\n")
    }
}

protocol WorkbenchStatusBrokerReading {
    func connect() throws
    func close()
    func health() throws -> WorkbenchBrokerSnapshot
    func serviceLifecycle() throws -> WorkbenchServiceLifecycleResult
    func workspaceStatus() throws -> WorkbenchWorkspaceStatus
    func listDevices() throws -> [WorkbenchDeviceRead]
}
extension WorkbenchBrokerClient: WorkbenchStatusBrokerReading {}

public struct WorkbenchStatusContext {
    let installedRelease: () throws -> WorkbenchStatusRelease
    let process: () throws -> WorkbenchStatusProcess
    let broker: () throws -> any WorkbenchStatusBrokerReading
    let expectedHome: String
    let toolCatalogCount: () -> Int
    let uptime: () -> TimeInterval
    let timeout: TimeInterval

    func collect() -> WorkbenchStatusReport {
        let deadline = uptime() + timeout
        let release = (try? installedRelease()) ?? .init(evidence: "unavailable", version: nil, packagePath: nil)
        let identity = uptime() < deadline ? ((try? process()) ??
            .init(evidence: "unavailable", state: "unavailable", releaseVersion: nil, pid: nil, uid: nil, executablePath: nil)) :
            .init(evidence: "unavailable", state: "timeout", releaseVersion: nil, pid: nil, uid: nil, executablePath: nil)
        var report = WorkbenchStatusReport(installedRelease: release, service: .init(process: identity))
        if release.evidence == "verified", identity.evidence == "verified",
           let installed = release.version, let running = identity.releaseVersion {
            report.service.versionComparison = installed == running ? "match" : "mismatch"
        }
        report.mcp.installedServerEvidence = release.evidence
        guard uptime() < deadline, let client = try? broker() else { return report }
        defer { client.close() }
        do { try client.connect() } catch { return report }
        guard uptime() < deadline, let health = try? client.health() else { return report }
        guard health.apiVersion == "1.0", health.controllerHomePath == expectedHome else {
            report.service.health = "controller_home_mismatch"
            return report
        }
        report.service.health = health.status
        report.service.healthEvidence = "verified_broker_reply"
        report.service.controllerHomePath = health.controllerHomePath
        report.service.instanceId = health.instanceId
        if uptime() < deadline, let lifecycle = try? client.serviceLifecycle() {
            report.service.activeJobCount = lifecycle.activeJobIDs.count
            report.service.lifecycleState = lifecycle.state
            report.service.lifecycleEvidence = "verified_broker_reply"
        }
        if uptime() < deadline, let workspace = try? client.workspaceStatus() {
            report.workspace = .init(evidence: "verified_broker_reply", state: workspace.state,
                                     workspaceId: workspace.workspaceId, path: workspace.path)
        }
        if uptime() < deadline, let devices = try? client.listDevices() {
            report.devices.evidence = "verified_broker_reply"
            report.devices.pairedCount = devices.count
            report.devices.items = devices.map { .init(deviceId: $0.deviceId, name: $0.name,
                ownerMatchesCurrent: $0.ownerMatchesCurrent, cachedReachability: $0.cachedReachability,
                lastSeenAt: $0.lastSeenAt) }
        }
        if health.status == "ready" {
            report.mcp.brokerEvidence = "verified_broker_reply"
            report.mcp.state = report.service.versionComparison == "mismatch"
                ? "service_version_mismatch" : "broker_ready"
            report.mcp.toolCatalogCount = toolCatalogCount()
        }
        return report
    }

    static func production(options: Options) throws -> Self {
        // Resolve the selected Brew command, not a candidate executable that
        // happened to be invoked directly from another version's package.
        let packagedInvocation = WorkbenchProductionTrust.homebrewRoot() != nil
        let root = packagedInvocation ? WorkbenchProductionTrust.homebrewRoot(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/screenpunk")) : nil
        let home = options.homeURL().resolvingSymlinksInPath().path
        let budget = min(options.timeout, 10)
        return .init(installedRelease: {
            guard let root else { return .init(evidence: "not_assessed", version: nil, packagePath: nil) }
            let version = try WorkbenchProductionTrust.verifyPackage(root).version
            return .init(evidence: "verified", version: version, packagePath: root.path)
        }, process: {
            guard packagedInvocation, options.home == nil, options.runtime == nil else {
                return .init(evidence: "not_assessed", state: "not_assessed", releaseVersion: nil,
                             pid: nil, uid: nil, executablePath: nil)
            }
            return try WorkbenchStatusNativeProcess.observe(timeout: min(2, budget))
        }, broker: {
            let runtime = try options.runtimeURL()
            let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: runtime,
                limits: .init(timeout: min(1, budget)))
            return WorkbenchBrokerClient(environment: environment)
        }, expectedHome: home, toolCatalogCount: { WorkbenchMCPBridge.names.count },
           uptime: { ProcessInfo.processInfo.systemUptime }, timeout: budget)
    }
}

/// Reads only the fixed owned launchd label and its PID. No process inventory,
/// launchctl mutation, receipt edit, service start or Keychain operation occurs.
enum WorkbenchStatusNativeProcess {
    static func observe(timeout: TimeInterval) throws -> WorkbenchStatusProcess {
        let paths = InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
        let target = "gui/\(geteuid())/com.screenpunk.workbench"
        let result = try BoundedArgumentProcess().run(executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", target], environment: ["HOME": paths.home.path, "PATH": "/usr/bin:/bin"],
            timeout: timeout, maximumOutputBytes: 65_536)
        guard result.exitStatus == 0, let text = String(data: result.stdout, encoding: .utf8),
              text.hasPrefix(target + " = {") else { throw DistributionError.unavailable }
        return try parse(text: text, paths: paths, readProcess: nativeIdentity,
                         authenticate: { try WorkbenchProductionTrust.verifyPackage($0).version })
    }

    struct Identity: Equatable {
        var pid: Int32
        var uid: UInt32
        var path: String
        var started: UInt64
        var image: Data
    }
    static func parse(text: String, paths: InstallationPaths,
                      readProcess: (Int32) throws -> Identity,
                      authenticate: (URL) throws -> String) throws -> WorkbenchStatusProcess {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ $0.hasPrefix("path = ") }) == ["path = " + paths.launchAgent.path],
              lines.filter({ $0.hasPrefix("program = ") }).count == 1 else { throw DistributionError.conflict }
        let programs = lines.filter { $0.hasPrefix("program = ") }
        let program = String(programs[0].dropFirst("program = ".count))
        let executable = URL(fileURLWithPath: program)
        guard let root = WorkbenchProductionTrust.homebrewRoot(executable: executable),
              program == root.appendingPathComponent("libexec/screenpunk-service").path,
              let start = lines.firstIndex(of: "arguments = {"),
              let end = lines[(start + 1)...].firstIndex(of: "}"),
              Array(lines[(start + 1)..<end]) == [program, "--foreground", "--home",
                paths.machineState.appendingPathComponent("Controller").path, "--runtime-directory",
                paths.machineState.appendingPathComponent("Runtime").path] else { throw DistributionError.conflict }
        let pidLines = lines.filter { $0.hasPrefix("pid = ") }
        if pidLines.isEmpty, lines.contains("state = not running") {
            return .init(evidence: "verified_launchd_reply", state: "stopped", releaseVersion: nil,
                         pid: nil, uid: nil, executablePath: program)
        }
        guard pidLines.count == 1, let pid = Int32(pidLines[0].dropFirst("pid = ".count)), pid > 0 else {
            throw DistributionError.conflict
        }
        let before = try readProcess(pid)
        guard before.pid == pid, before.uid == geteuid(), before.path == program,
              before.started > 0, before.image.count == 16 else { throw DistributionError.conflict }
        let version = try authenticate(root)
        let after = try readProcess(pid)
        guard before == after else { throw DistributionError.conflict }
        return .init(evidence: "verified", state: "running", releaseVersion: version,
                     pid: pid, uid: before.uid, executablePath: program)
    }

    private static func nativeIdentity(_ pid: Int32) throws -> Identity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw DistributionError.unavailable }
        var path = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0, length < path.count else { throw DistributionError.unavailable }
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { throw DistributionError.unavailable }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var requirement: SecRequirement?
        let policy = "anchor apple generic and certificate leaf[subject.OU] = \"77KASWDGM6\" and identifier \"xyz.screenpunk.service\""
        guard SecRequirementCreateWithString(policy as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, SecCSFlags(), requirement) == errSecSuccess else {
            throw DistributionError.untrustedRelease
        }
        return .init(pid: pid, uid: info.pbi_uid, path: String(cString: path),
                     started: usage.ri_proc_start_abstime, image: withUnsafeBytes(of: usage.ri_uuid) { Data($0) })
    }
}
