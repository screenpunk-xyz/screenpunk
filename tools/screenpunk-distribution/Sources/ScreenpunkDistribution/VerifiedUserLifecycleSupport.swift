import Foundation
import Darwin

public struct BoundedProcessResult: Sendable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data
}

public protocol ArgumentProcessRunning {
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval, maximumOutputBytes: Int) throws -> BoundedProcessResult
}

/// Process execution for fixed installed executables and /bin/launchctl only.
/// Both pipes are drained while the child runs; timeout terminates the child.
public struct BoundedArgumentProcess: ArgumentProcessRunning {
    public init() {}
    public func run(executable: URL, arguments: [String], environment: [String: String],
                    timeout: TimeInterval, maximumOutputBytes: Int) throws -> BoundedProcessResult {
        guard executable.path.hasPrefix("/"), timeout > 0, timeout <= 30,
              (1...262_144).contains(maximumOutputBytes) else { throw DistributionError.invalidPath }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let outBox = CapturedPipe(limit: maximumOutputBytes)
        let errBox = CapturedPipe(limit: maximumOutputBytes)
        let readers = DispatchGroup()
        for (handle, box) in [(output.fileHandleForReading, outBox),
                              (errors.fileHandleForReading, errBox)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while true {
                    let chunk = handle.readData(ofLength: 4096)
                    if chunk.isEmpty { break }
                    box.append(chunk)
                }
            }
        }
        do { try process.run() }
        catch { try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); throw error }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = readers.wait(timeout: .now() + 1)
            throw DistributionError.unavailable
        }
        process.waitUntilExit()
        guard readers.wait(timeout: .now() + 1) == .success,
              !outBox.truncated, !errBox.truncated else { throw DistributionError.unavailable }
        return .init(exitStatus: process.terminationStatus, stdout: outBox.bytes, stderr: errBox.bytes)
    }
}

private final class CapturedPipe: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var overflow = false
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if chunk.count > limit - data.count { overflow = true }
        data.append(chunk.prefix(max(0, limit - data.count)))
    }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
}

/// Closed per-user launchctl grammar. This can be injected into the existing
/// LaunchdUserAdapter in place of its unbounded default process runner.
public final class BoundedUserLaunchctl: LaunchctlRunning, OwnedLaunchdJobProbing {
    private let runner: any ArgumentProcessRunning
    private let domain: String
    private let target: String
    private let plist: String
    private let home: String
    public init(runner: any ArgumentProcessRunning = BoundedArgumentProcess(),
                uid: uid_t = geteuid(), paths: InstallationPaths) {
        self.runner = runner; domain = "gui/\(uid)"
        target = domain + "/" + LaunchdUserAdapter.label
        plist = paths.launchAgent.path; home = paths.home.path
    }
    public func run(_ arguments: [String]) throws -> String {
        let valid: Bool
        switch arguments.first {
        case "bootstrap", "bootout": valid = arguments.count == 3 && arguments[1] == domain && arguments[2] == plist
        case "kickstart": valid = arguments == ["kickstart", "-k", target]
        case "enable", "disable", "print": valid = arguments.count == 2 && arguments[1] == target
        default: valid = false
        }
        guard valid else { throw DistributionError.invalidPath }
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments, environment: ["HOME": home, "PATH": "/usr/bin:/bin"],
            timeout: 5, maximumOutputBytes: 65_536)
        guard result.exitStatus == 0, let text = String(data: result.stdout, encoding: .utf8) else {
            throw DistributionError.unavailable
        }
        return text
    }

    public func ownedJobState(expectedExecutable: URL, expectedPlist: URL,
                              expectedArguments: [String]) throws -> OwnedLaunchdJobState {
        guard expectedPlist.path == plist, expectedArguments.first == expectedExecutable.path else {
            return .unknown
        }
        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", target], environment: ["HOME": home, "PATH": "/usr/bin:/bin"],
            timeout: 5, maximumOutputBytes: 65_536)
        guard let output = String(data: result.stdout, encoding: .utf8),
              let errors = String(data: result.stderr, encoding: .utf8) else { return .unknown }
        if result.exitStatus != 0 {
            // launchctl's missing-service response; any permission,
            // domain or transport failure remains unknown.
            return result.exitStatus == 113 && output.isEmpty && errors.contains(
                "Could not find service \"\(LaunchdUserAdapter.label)\" in domain for user gui: \(domain.dropFirst(4))")
                ? .absent : .unknown
        }
        guard output.hasPrefix(target + " = {") else { return .unknown }
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ $0.hasPrefix("path = ") }) == ["path = " + expectedPlist.path],
              lines.filter({ $0.hasPrefix("program = ") }) == ["program = " + expectedExecutable.path],
              let argumentsStart = lines.firstIndex(of: "arguments = {"),
              let argumentsEnd = lines[(argumentsStart + 1)...].firstIndex(of: "}"),
              Array(lines[(argumentsStart + 1)..<argumentsEnd]) == expectedArguments else { return .unknown }
        let pid = try NSRegularExpression(pattern: "(?m)^\\s*pid = [1-9][0-9]*\\s*$")
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        if pid.firstMatch(in: output, range: range) != nil { return .running }
        let stopped = try NSRegularExpression(pattern: "(?m)^\\s*state = not running\\s*$")
        return stopped.firstMatch(in: output, range: range) != nil ? .registeredWithoutProcess : .unknown
    }
}

public enum ObservedWorkbenchService: Equatable {
    case absent
    case unknown
    case ready(apiVersion: String, controllerHomePath: String)
}

public protocol WorkbenchServiceStatusProbing {
    func status() throws -> ObservedWorkbenchService
}

/// Uses the existing read-only `service status` CLI envelope. It never starts
/// the service or supplies a workspace-selected command path.
public final class WorkbenchCLIStatusProbe: WorkbenchServiceStatusProbing {
    private let runner: any ArgumentProcessRunning
    private let paths: InstallationPaths
    private let controllerHome: URL
    private let runtimeDirectory: URL
    public init(runner: any ArgumentProcessRunning = BoundedArgumentProcess(),
                paths: InstallationPaths, controllerHome: URL, runtimeDirectory: URL) {
        self.runner = runner; self.paths = paths
        self.controllerHome = controllerHome; self.runtimeDirectory = runtimeDirectory
    }
    public func status() throws -> ObservedWorkbenchService {
        guard controllerHome.path.hasPrefix(paths.home.path + "/"),
              runtimeDirectory.path.hasPrefix(paths.home.path + "/") else {
            throw DistributionError.invalidPath
        }
        let result = try runner.run(executable: paths.cli,
            arguments: ["--json", "--no-input", "--timeout", "2",
                        "--home", controllerHome.path,
                        "--runtime-directory", runtimeDirectory.path, "service", "status"],
            environment: ["HOME": paths.home.path, "PATH": "/usr/bin:/bin"],
            timeout: 4, maximumOutputBytes: 65_536)
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              object["apiVersion"] as? String == "1.0",
              let ok = object["ok"] as? Bool else { throw DistributionError.unavailable }
        if result.exitStatus == 9, !ok,
           let error = object["error"] as? [String: Any], error["code"] as? String == "unavailable" {
            // The CLI also uses this envelope for an unreachable broker. It
            // is never proof that launchd has no running service or jobs.
            return .unknown
        }
        guard result.exitStatus == 0, ok,
              let value = object["result"] as? [String: Any],
              value["apiVersion"] as? String == "1.0",
              value["status"] as? String == "ready",
              let home = value["controllerHomePath"] as? String else { throw DistributionError.unavailable }
        return .ready(apiVersion: "1.0", controllerHomePath: home)
    }
}

public protocol InstalledServiceIdentityProbing {
    func runningServiceMatches(version: String) throws -> Bool
}

/// Native process-path binding for a launchd-owned service. The installed
/// unit itself remains subject to DistributionArchive's full inventory/trust.
public final class LaunchdProcessIdentityProbe: InstalledServiceIdentityProbing {
    private let launchctl: any LaunchctlRunning
    private let target: String
    private let paths: InstallationPaths
    private let packageRoot: URL?
    public init(launchctl: any LaunchctlRunning, uid: uid_t = geteuid(), paths: InstallationPaths,
                packageRoot: URL? = nil) {
        self.launchctl = launchctl; target = "gui/\(uid)/" + LaunchdUserAdapter.label
        self.paths = paths; self.packageRoot = packageRoot
    }
    public func runningServiceMatches(version: String) throws -> Bool {
        guard DistributionArchive.validVersion(version) else { throw DistributionError.invalidPath }
        if packageRoot == nil {
            let selected = try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path)
            guard selected == "versions/" + version else { return false }
        }
        let output = try launchctl.run(["print", target])
        let regex = try NSRegularExpression(pattern: "(?m)^\\s*pid = ([1-9][0-9]*)\\s*$")
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: range)
        guard matches.count == 1, let pidRange = Range(matches[0].range(at: 1), in: output),
              let pid = Int32(output[pidRange]) else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let observed = String(cString: buffer)
        let expected = (packageRoot ?? paths.versions.appendingPathComponent(version))
            .appendingPathComponent("libexec/screenpunk-service").resolvingSymlinksInPath().path
        return URL(fileURLWithPath: observed).resolvingSymlinksInPath().path == expected
    }
}

/// Actual broker currently exposes health and stop, but no drain/job ledger,
/// version attestation RPC, GUI-consumer registry, or idle command. A running
/// service cannot be drained or uninstalled through this observation until
/// those local authority contracts exist. Absent service is safe to report.
public final class ConservativeWorkbenchObservation: WorkbenchServiceObservation {
    private let statusProbe: any WorkbenchServiceStatusProbing
    private let identityProbe: any InstalledServiceIdentityProbing
    private let controllerHome: URL
    public init(statusProbe: any WorkbenchServiceStatusProbing,
                identityProbe: any InstalledServiceIdentityProbing, controllerHome: URL) {
        self.statusProbe = statusProbe; self.identityProbe = identityProbe
        self.controllerHome = controllerHome
    }
    public func drainAndReportInterruptedJobs() throws -> [String] {
        switch try statusProbe.status() {
        case .absent: return []
        case .unknown, .ready: throw DistributionError.unavailable
        }
    }
    public func healthy(expectedVersion: String) throws -> Bool {
        guard case let .ready(apiVersion, path) = try statusProbe.status(),
              apiVersion == "1.0", path == controllerHome.resolvingSymlinksInPath().path else {
            return false
        }
        return try identityProbe.runningServiceMatches(version: expectedVersion)
    }
    public func stopAndReportInterruptedJobs() throws -> [String] {
        switch try statusProbe.status() {
        case .absent: return []
        case .unknown, .ready: throw DistributionError.unavailable
        }
    }
    public func compatibleGUIConsumers() throws -> [String] {
        throw DistributionError.unavailable
    }
}
