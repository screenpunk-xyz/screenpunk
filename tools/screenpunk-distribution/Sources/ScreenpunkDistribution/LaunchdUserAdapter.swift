import Foundation
import Darwin

public protocol LaunchctlRunning {
    func run(_ arguments: [String]) throws -> String
}

public enum OwnedLaunchdJobState: Equatable, Sendable {
    case absent, registeredWithoutProcess, running, unknown
}

public protocol OwnedLaunchdJobProbing {
    func ownedJobState(expectedExecutable: URL, expectedPlist: URL,
                       expectedArguments: [String]) throws -> OwnedLaunchdJobState
}

public protocol WorkbenchServiceObservation {
    func drainAndReportInterruptedJobs() throws -> [String]
    func healthy(expectedVersion: String) throws -> Bool
    func stopAndReportInterruptedJobs() throws -> [String]
    func compatibleGUIConsumers() throws -> [String]
}

public struct UnconfiguredServiceObservation: WorkbenchServiceObservation {
    public init() {}
    public func drainAndReportInterruptedJobs() throws -> [String] { throw DistributionError.unavailable }
    public func healthy(expectedVersion: String) throws -> Bool { throw DistributionError.unavailable }
    public func stopAndReportInterruptedJobs() throws -> [String] { throw DistributionError.unavailable }
    public func compatibleGUIConsumers() throws -> [String] { throw DistributionError.unavailable }
}

public final class LaunchdUserAdapter: InstallationServiceLifecycle {
    public static let label = "com.screenpunk.workbench"
    private let launchctl: any LaunchctlRunning
    private let observation: any WorkbenchServiceObservation
    private let uid: uid_t
    private let paths: InstallationPaths
    private let controllerHome: URL
    private let runtimeDirectory: URL
    private let logDirectory: URL
    private let serviceExecutable: URL
    public init(observation: any WorkbenchServiceObservation, paths: InstallationPaths,
                controllerHome: URL, runtimeDirectory: URL,
                uid: uid_t = geteuid(), logDirectory: URL,
                launchctl: (any LaunchctlRunning)? = nil,
                serviceExecutable: URL? = nil) {
        self.launchctl = launchctl ?? BoundedUserLaunchctl(uid: uid, paths: paths)
        self.observation = observation; self.paths = paths
        self.controllerHome = controllerHome; self.runtimeDirectory = runtimeDirectory
        self.uid = uid; self.logDirectory = logDirectory
        self.serviceExecutable = serviceExecutable ?? paths.current.appendingPathComponent("libexec/screenpunk-service")
    }
    public var domain: String { "gui/\(uid)" }
    public var serviceTarget: String { domain + "/" + Self.label }
    public func drain() throws -> [String] { try observation.drainAndReportInterruptedJobs() }
    public func health(version: String) throws -> Bool { try observation.healthy(expectedVersion: version) }
    public func compatibleGUIConsumers() throws -> [String] { try observation.compatibleGUIConsumers() }

    private func ownedPlist(serviceExecutable: URL, plist: URL) throws -> [String: Any] {
        guard plist.path == paths.launchAgent.path,
              serviceExecutable.path == self.serviceExecutable.path,
              controllerHome.path.hasPrefix(paths.machineState.path + "/"),
              runtimeDirectory.path.hasPrefix(paths.machineState.path + "/"),
              !controllerHome.pathComponents.contains(".."),
              !runtimeDirectory.pathComponents.contains(".."),
              logDirectory.path.hasPrefix(paths.home.path + "/") else {
            throw DistributionError.invalidPath
        }
        let log = logDirectory.appendingPathComponent("service.log").path
        return [
            "Label": Self.label,
            "ProgramArguments": [serviceExecutable.path, "--foreground",
                                 "--home", controllerHome.path,
                                 "--runtime-directory", runtimeDirectory.path],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Background",
            "EnvironmentVariables": ["HOME": paths.home.path, "PATH": "/usr/bin:/bin"],
            "StandardOutPath": log,
            "StandardErrorPath": log
        ]
    }

    private func ownedAgentDirectory(create: Bool) throws -> Int32? {
        let home = open(paths.home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard home >= 0 else { throw DistributionError.conflict }
        defer { close(home) }
        func checkedDirectory(_ fd: Int32) throws {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & mode_t(0o022) == 0 else {
                throw DistributionError.conflict
            }
        }
        func child(_ parent: Int32, _ name: String) throws -> Int32? {
            var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(parent, name, 0o700) == 0 else { throw DistributionError.conflict }
                fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw DistributionError.conflict }
            do { try checkedDirectory(fd) }
            catch { close(fd); throw error }
            return fd
        }
        try checkedDirectory(home)
        guard let library = try child(home, "Library") else { return nil }
        defer { close(library) }
        return try child(library, "LaunchAgents")
    }

    private func verifyAgentDirectory(_ held: Int32) throws {
        guard let current = try ownedAgentDirectory(create: false) else { throw DistributionError.conflict }
        defer { close(current) }
        var left = stat(), right = stat()
        guard fstat(held, &left) == 0, fstat(current, &right) == 0,
              left.st_dev == right.st_dev, left.st_ino == right.st_ino else {
            throw DistributionError.conflict
        }
    }

    private func verifyOwnedPlist(in directory: Int32, expected: [String: Any]) throws {
        let file = openat(directory, Self.label + ".plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw DistributionError.conflict }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o022) == 0,
              (1...16_384).contains(metadata.st_size) else {
            throw DistributionError.conflict
        }
        var prior = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while prior.count < 16_384 {
            let count = Darwin.read(file, &chunk, min(chunk.count, 16_384 - prior.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DistributionError.unavailable }
            if count == 0 { break }
            prior.append(contentsOf: chunk.prefix(count))
        }
        guard prior.count == metadata.st_size else { throw DistributionError.conflict }
        guard let value = try PropertyListSerialization.propertyList(from: prior,
            options: [], format: nil) as? [String: Any],
              NSDictionary(dictionary: value).isEqual(to: expected) else {
            throw DistributionError.conflict
        }
    }

    private func plistExists(in directory: Int32) throws -> Bool {
        var metadata = stat()
        if fstatat(directory, Self.label + ".plist", &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw DistributionError.unavailable }
        return false
    }

    private func writeOwnedPlist(_ data: Data, in directory: Int32) throws {
        let temporary = ".screenpunk-plist-" + UUID().uuidString.lowercased()
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw DistributionError.unavailable }
        defer { _ = unlinkat(directory, temporary, 0) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), data.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw DistributionError.unavailable }
                    offset += count
                }
            }
            guard fsync(file) == 0 else { throw DistributionError.unavailable }
        } catch { close(file); throw error }
        close(file)
        try verifyAgentDirectory(directory)
        guard renameat(directory, temporary, directory, Self.label + ".plist") == 0,
              fsync(directory) == 0 else { throw DistributionError.unavailable }
    }

    public func register(serviceExecutable: URL, plist: URL) throws {
        let contents = try ownedPlist(serviceExecutable: serviceExecutable, plist: plist)
        guard let directory = try ownedAgentDirectory(create: true) else { throw DistributionError.conflict }
        defer { close(directory) }
        try FileManager.default.createDirectory(at: logDirectory,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        if try plistExists(in: directory) {
            try verifyOwnedPlist(in: directory, expected: contents)
            try verifyAgentDirectory(directory)
            if let probe = launchctl as? any OwnedLaunchdJobProbing,
               let arguments = contents["ProgramArguments"] as? [String] {
                // The legacy installer has drained before re-registration.
                // Replace only a positively owned job, and prove removal before
                // rewriting its plist or bootstrapping the selected version.
                switch try probe.ownedJobState(expectedExecutable: serviceExecutable, expectedPlist: plist,
                    expectedArguments: arguments) {
                case .absent: break
                case .running, .registeredWithoutProcess:
                    _ = try launchctl.run(["bootout", domain, plist.path])
                case .unknown: throw DistributionError.conflict
                }
                guard try probe.ownedJobState(expectedExecutable: serviceExecutable, expectedPlist: plist,
                    expectedArguments: arguments) == .absent else { throw DistributionError.conflict }
                try verifyOwnedPlist(in: directory, expected: contents)
                try verifyAgentDirectory(directory)
            } else {
                _ = try launchctl.run(["bootout", domain, plist.path])
            }
        }
        try writeOwnedPlist(data, in: directory)
        try verifyAgentDirectory(directory)
        _ = try launchctl.run(["bootstrap", domain, plist.path])
        _ = try launchctl.run(["kickstart", "-k", serviceTarget])
    }

    public func status() throws -> String { try launchctl.run(["print", serviceTarget]) }
    public func start() throws { _ = try launchctl.run(["kickstart", "-k", serviceTarget]) }
    public func ownedState() throws -> OwnedLaunchdJobState {
        guard let probe = launchctl as? any OwnedLaunchdJobProbing else { throw DistributionError.unavailable }
        let expected = try ownedPlist(serviceExecutable: serviceExecutable, plist: paths.launchAgent)
        var exists = false
        if let directory = try ownedAgentDirectory(create: false) {
            defer { close(directory) }
            exists = try plistExists(in: directory)
            if exists { try verifyOwnedPlist(in: directory, expected: expected) }
        }
        guard let arguments = expected["ProgramArguments"] as? [String] else { throw DistributionError.conflict }
        let state = try probe.ownedJobState(expectedExecutable: serviceExecutable,
            expectedPlist: paths.launchAgent, expectedArguments: arguments)
        return !exists && state != .absent ? .unknown : state
    }
    public func startOwned(serviceExecutable: URL) throws {
        switch try ownedState() {
        case .absent: try register(serviceExecutable: serviceExecutable, plist: paths.launchAgent)
        case .registeredWithoutProcess:
            try verifyRegisteredService()
            try start()
        case .running: break
        case .unknown: throw DistributionError.conflict
        }
    }
    private func verifyRegisteredService() throws {
        let expected = try ownedPlist(serviceExecutable: serviceExecutable, plist: paths.launchAgent)
        guard let directory = try ownedAgentDirectory(create: false) else {
            throw DistributionError.conflict
        }
        defer { close(directory) }
        try verifyOwnedPlist(in: directory, expected: expected)
        try verifyAgentDirectory(directory)
    }
    public func enable() throws {
        try verifyRegisteredService()
        _ = try launchctl.run(["enable", serviceTarget])
    }
    public func disable() throws {
        try verifyRegisteredService()
        _ = try launchctl.run(["disable", serviceTarget])
    }
    public func logPath() -> URL { logDirectory.appendingPathComponent("service.log") }
    public func verifiedLogPath() throws -> URL {
        try verifyRegisteredService()
        return logPath()
    }
    /// Idle exit belongs to the service process: KeepAlive=false permits exit
    /// after its own drained idle timeout; launchd does not invent that policy.
    public func idlePolicy() -> String { "Service exits after its own drained idle timeout; launchd KeepAlive is false." }

    public func stopAndUnregister(plist: URL) throws -> [String] {
        let expected = try ownedPlist(serviceExecutable: serviceExecutable, plist: plist)
        let directory = try ownedAgentDirectory(create: false)
        defer { if let directory { close(directory) } }
        if let directory, try plistExists(in: directory) {
            try verifyOwnedPlist(in: directory, expected: expected)
        }
        let interrupted = try observation.stopAndReportInterruptedJobs()
        if let directory, try plistExists(in: directory) {
            try verifyOwnedPlist(in: directory, expected: expected)
            try verifyAgentDirectory(directory)
            _ = try launchctl.run(["bootout", domain, plist.path])
            if let probe = launchctl as? any OwnedLaunchdJobProbing {
                guard let arguments = expected["ProgramArguments"] as? [String],
                      try probe.ownedJobState(expectedExecutable: serviceExecutable, expectedPlist: plist,
                          expectedArguments: arguments) == .absent else { throw DistributionError.unavailable }
            }
            try verifyAgentDirectory(directory)
            guard unlinkat(directory, Self.label + ".plist", 0) == 0,
                  fsync(directory) == 0 else { throw DistributionError.unavailable }
        }
        return interrupted
    }

    /// A failed fresh activation may never expose a broker. Only an owned,
    /// exact plist plus positive launchd evidence of no process authorizes
    /// unregistering without broker drain. Unknown/live state keeps the normal
    /// verified broker shutdown path or fails closed.
    public func recoverFailedActivation(plist: URL) throws -> [String] {
        guard let probe = launchctl as? any OwnedLaunchdJobProbing else {
            return try stopAndUnregister(plist: plist)
        }
        let expected = try ownedPlist(serviceExecutable: serviceExecutable, plist: plist)
        let directory = try ownedAgentDirectory(create: false)
        defer { if let directory { close(directory) } }
        let exists = try directory.map { try plistExists(in: $0) } ?? false
        if exists, let directory { try verifyOwnedPlist(in: directory, expected: expected) }
        guard let arguments = expected["ProgramArguments"] as? [String] else { throw DistributionError.conflict }
        switch try probe.ownedJobState(expectedExecutable: serviceExecutable, expectedPlist: plist,
                                      expectedArguments: arguments) {
        case .running:
            guard exists else { throw DistributionError.conflict }
            return try stopAndUnregister(plist: plist)
        case .unknown: throw DistributionError.unavailable
        case .registeredWithoutProcess:
            guard exists, let directory else { throw DistributionError.conflict }
            try verifyAgentDirectory(directory)
            _ = try launchctl.run(["bootout", domain, plist.path])
        case .absent: break
        }
        guard try probe.ownedJobState(expectedExecutable: serviceExecutable, expectedPlist: plist,
                                     expectedArguments: arguments) == .absent else { throw DistributionError.unavailable }
        if exists, let directory {
            try verifyOwnedPlist(in: directory, expected: expected)
            try verifyAgentDirectory(directory)
            guard unlinkat(directory, Self.label + ".plist", 0) == 0,
                  fsync(directory) == 0 else { throw DistributionError.unavailable }
        }
        return []
    }
}
