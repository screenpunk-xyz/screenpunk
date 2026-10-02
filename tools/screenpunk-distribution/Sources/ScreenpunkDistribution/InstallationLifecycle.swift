import Foundation
import CryptoKit
import Darwin

public struct InstallationPaths: Sendable {
    public let home: URL
    public var root: URL { home.appendingPathComponent(".local/share/screenpunk") }
    public var versions: URL { root.appendingPathComponent("versions") }
    public var current: URL { root.appendingPathComponent("current") }
    public var bin: URL { home.appendingPathComponent(".local/bin") }
    public var cli: URL { bin.appendingPathComponent("screenpunk") }
    public var mcp: URL { bin.appendingPathComponent("screenpunk-mcp") }
    public var launchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/com.screenpunk.workbench.plist") }
    public var machineState: URL { home.appendingPathComponent("Library/Application Support/Screenpunk") }
    public init(home: URL) { self.home = home }
}

public protocol InstallationServiceLifecycle {
    func drain() throws -> [String] // interrupted job IDs; empty means drained
    func register(serviceExecutable: URL, plist: URL) throws
    func health(version: String) throws -> Bool
    func stopAndUnregister(plist: URL) throws -> [String]
    func recoverFailedActivation(plist: URL) throws -> [String]
    func compatibleGUIConsumers() throws -> [String]
}

extension InstallationServiceLifecycle {
    public func recoverFailedActivation(plist: URL) throws -> [String] {
        try stopAndUnregister(plist: plist)
    }
}

public struct InstallationPlan: Sendable {
    public enum Action: String, Sendable { case install, update, rollback }
    public let action: Action
    public let version: String
    public let previousVersion: String?
    public let archive: URL
    public let manifestHash: String
    public let workspaceSchema: Int
    public let protocolVersion: Int
    public let requiredBytes: Int64
    public let confirmation: String
    public let effects: [String]
}

public struct InstallationOutcome: Sendable {
    public let selectedVersion: String
    public let interruptedJobs: [String]
    public let retainedPreviousVersion: String?
    public let pathGuidance: String
}

public struct UninstallPlan: Sendable {
    public let versionNames: [String]
    public let preservedWorkspacePaths: [String]
    public let preservedExternalPaths: [String]
    public let purgeMachineState: Bool
    public let sharedGUIConsumers: [String]
    public let confirmation: String
    public let effects: [String]
}

public struct UninstallOutcome: Sendable {
    public let interruptedJobs: [String]
    public let preservedWorkspacePaths: [String]
    public let preservedExternalPaths: [String]
    public let preservedMachineState: Bool
    public let sharedGUIConsumers: [String]
    public let agentConfigurationNotice: String
}

public protocol InstallationMachineStatePurger {
    /// Production implementation must verify the exact local state scope and
    /// enumerate Keychain labels under current local authority before deletion.
    func preflightExactMachineState(at path: URL) throws
    func purgeExactMachineState(at path: URL) throws
}
public struct RejectUnconfiguredPurge: InstallationMachineStatePurger {
    public init() {}
    public func preflightExactMachineState(at path: URL) throws { throw DistributionError.unavailable }
    public func purgeExactMachineState(at path: URL) throws { throw DistributionError.unavailable }
}

private struct InstallationMarker: Codable {
    let schemaVersion: Int
    let owner: String
    let canonicalRoot: String
}

/// Installation state lives only under fixed, injected per-user paths. The
/// workspace is observed for compatibility but is never a source of commands,
/// executable paths, release channels, or deletion targets.
public final class ScreenpunkInstaller {
    private let paths: InstallationPaths
    private let service: any InstallationServiceLifecycle
    private let trust: any DistributionReleaseTrust
    private let allowLocalTest: Bool
    private let purger: any InstallationMachineStatePurger
    private let prepareVerifiedPayload: (URL, DistributionManifest) throws -> Void
    private let fm = FileManager.default
    public init(paths: InstallationPaths, service: any InstallationServiceLifecycle,
                releaseTrust: any DistributionReleaseTrust = RejectUnconfiguredReleaseTrust(),
                allowLocalTest: Bool = false,
                purger: any InstallationMachineStatePurger = RejectUnconfiguredPurge(),
                prepareVerifiedPayload: @escaping (URL, DistributionManifest) throws -> Void = { _, _ in }) {
        self.paths = paths; self.service = service; self.trust = releaseTrust
        self.allowLocalTest = allowLocalTest; self.purger = purger
        self.prepareVerifiedPayload = prepareVerifiedPayload
    }

    public func plan(archive: URL, workspaceSchema: Int, protocolVersion: Int,
                     rollback: Bool = false) throws -> InstallationPlan {
        try verifyHome()
        let manifest = try DistributionArchive.verify(root: archive,
            allowLocalTest: allowLocalTest, releaseTrust: trust)
        guard (manifest.minimumWorkspaceSchema...manifest.maximumWorkspaceSchema).contains(workspaceSchema),
              manifest.protocolVersion == protocolVersion else { throw DistributionError.incompatible }
        let previous = try selectedVersion()
        if let previous {
            _ = try DistributionArchive.verify(root: paths.versions.appendingPathComponent(previous),
                                                allowLocalTest: allowLocalTest, releaseTrust: trust)
        }
        if rollback {
            guard previous != nil, fm.fileExists(atPath: paths.versions.appendingPathComponent(manifest.version).path)
            else { throw DistributionError.incompatible }
        } else if let previous, manifest.version.compare(previous, options: .numeric) == .orderedAscending {
            throw DistributionError.incompatible // no implicit downgrade
        }
        try checkLauncher(paths.cli, expected: paths.current.appendingPathComponent("bin/screenpunk"))
        try checkLauncher(paths.mcp, expected: paths.current.appendingPathComponent("bin/screenpunk-mcp"))
        let bytes = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
        let hash = SHA256.hash(data: try DistributionArchive.canonical(manifest))
            .map { String(format: "%02x", $0) }.joined()
        let action: InstallationPlan.Action = rollback ? .rollback : (previous == nil ? .install : .update)
        let token = fingerprint([action.rawValue, manifest.version, previous ?? "none", hash,
                                 String(workspaceSchema), String(protocolVersion), paths.root.path])
        return .init(action: action, version: manifest.version, previousVersion: previous,
            archive: archive, manifestHash: hash, workspaceSchema: workspaceSchema,
            protocolVersion: protocolVersion, requiredBytes: bytes, confirmation: token,
            effects: ["Stage and verify \(manifest.version) under \(paths.versions.path)",
                      "Drain installation-owned service and atomically select current version",
                      "Health-check service; retain prior version for rollback",
                      "Preserve workspace, external projects, machine state and installed kits"])
    }

    public func execute(_ plan: InstallationPlan, confirming token: String) throws -> InstallationOutcome {
        guard token == plan.confirmation else { throw DistributionError.conflict }
        let fresh = try self.plan(archive: plan.archive, workspaceSchema: plan.workspaceSchema,
                                  protocolVersion: plan.protocolVersion, rollback: plan.action == .rollback)
        guard fresh.confirmation == token else { throw DistributionError.conflict }
        let manifest = try DistributionArchive.verify(root: plan.archive,
            allowLocalTest: allowLocalTest, releaseTrust: trust)
        guard manifest.version == plan.version else { throw DistributionError.conflict }
        try prepareDirectories()
        try ensureMarker()
        let destination = paths.versions.appendingPathComponent(plan.version)
        if !fm.fileExists(atPath: destination.path) {
            try checkSpace(required: plan.requiredBytes)
            let stage = paths.versions.appendingPathComponent(".stage-" + UUID().uuidString)
            try copyUnit(from: plan.archive, to: stage, manifest: manifest)
            do {
                _ = try DistributionArchive.verify(root: stage,
                    allowLocalTest: allowLocalTest, releaseTrust: trust)
                try prepareVerifiedPayload(stage, manifest)
                guard rename(stage.path, destination.path) == 0 else { throw DistributionError.unavailable }
            } catch {
                try? fm.removeItem(at: stage)
                throw error
            }
        } else {
            let installed = try DistributionArchive.verify(root: destination,
                allowLocalTest: allowLocalTest, releaseTrust: trust)
            guard installed == manifest else { throw DistributionError.conflict }
            try prepareVerifiedPayload(destination, manifest)
        }
        let interrupted = try service.drain()
        try switchCurrent(to: plan.version)
        do {
            try installLauncher(paths.cli, target: paths.current.appendingPathComponent("bin/screenpunk"))
            try installLauncher(paths.mcp, target: paths.current.appendingPathComponent("bin/screenpunk-mcp"))
            try service.register(serviceExecutable: paths.current.appendingPathComponent("libexec/screenpunk-service"),
                                 plist: paths.launchAgent)
            guard try service.health(version: plan.version) else { throw DistributionError.unavailable }
        } catch {
            do {
                if let previous = plan.previousVersion {
                    try switchCurrent(to: previous)
                    try service.register(serviceExecutable: paths.current.appendingPathComponent(
                        "libexec/screenpunk-service"), plist: paths.launchAgent)
                    guard try service.health(version: previous) else {
                        throw DistributionError.recoveryRequired
                    }
                } else {
                    _ = try service.recoverFailedActivation(plist: paths.launchAgent)
                    try removeExactLauncher(paths.cli,
                        target: paths.current.appendingPathComponent("bin/screenpunk"))
                    try removeExactLauncher(paths.mcp,
                        target: paths.current.appendingPathComponent("bin/screenpunk-mcp"))
                    if fm.fileExists(atPath: paths.current.path) { try fm.removeItem(at: paths.current) }
                }
            } catch { throw DistributionError.recoveryRequired }
            throw error
        }
        return .init(selectedVersion: plan.version, interruptedJobs: interrupted,
            retainedPreviousVersion: plan.previousVersion,
            pathGuidance: "Add \(paths.bin.path) to PATH if needed; shell startup files and agent configuration were not edited.")
    }

    public func planUninstall(workspaces: [String], externalProjects: [String],
                              purgeMachineState: Bool = false) throws -> UninstallPlan {
        try verifyHome()
        try verifyMarker()
        try verifyRootShape()
        let versions = try installedVersions()
        for name in versions {
            _ = try DistributionArchive.verify(root: paths.versions.appendingPathComponent(name),
                                                allowLocalTest: allowLocalTest, releaseTrust: trust)
        }
        let consumers = try service.compatibleGUIConsumers()
        let checkedWorkspaces = try workspaces.map { try retainedDataPath($0) }
        let checkedExternal = try externalProjects.map { try retainedDataPath($0) }
        try checkLauncher(paths.cli, expected: paths.current.appendingPathComponent("bin/screenpunk"))
        try checkLauncher(paths.mcp, expected: paths.current.appendingPathComponent("bin/screenpunk-mcp"))
        if purgeMachineState { try purger.preflightExactMachineState(at: paths.machineState) }
        let token = fingerprint(["uninstall", versions.joined(separator: ","),
            checkedWorkspaces.joined(separator: ","), checkedExternal.joined(separator: ","),
            String(purgeMachineState), consumers.joined(separator: ","), paths.root.path])
        return .init(versionNames: versions, preservedWorkspacePaths: checkedWorkspaces,
            preservedExternalPaths: checkedExternal, purgeMachineState: purgeMachineState,
            sharedGUIConsumers: consumers, confirmation: token,
            effects: ["Stop and unregister only Screenpunk's per-user service",
                      "Remove exact owned launchers and installation units unless a compatible GUI consumes the runtime",
                      purgeMachineState ? "Purge enumerated machine-local state under current local authority" : "Retain local config and credentials",
                      "Retain every visible workspace and external project; leave agent config untouched"])
    }

    public func executeUninstall(_ plan: UninstallPlan, confirming token: String) throws -> UninstallOutcome {
        guard token == plan.confirmation else { throw DistributionError.conflict }
        let fresh = try planUninstall(workspaces: plan.preservedWorkspacePaths,
            externalProjects: plan.preservedExternalPaths, purgeMachineState: plan.purgeMachineState)
        guard fresh.confirmation == token else { throw DistributionError.conflict }
        for name in plan.versionNames {
            _ = try DistributionArchive.verify(root: paths.versions.appendingPathComponent(name),
                                                allowLocalTest: allowLocalTest, releaseTrust: trust)
        }
        let interrupted = plan.sharedGUIConsumers.isEmpty
            ? try service.stopAndUnregister(plist: paths.launchAgent) : []
        try removeExactLauncher(paths.cli, target: paths.current.appendingPathComponent("bin/screenpunk"))
        try removeExactLauncher(paths.mcp, target: paths.current.appendingPathComponent("bin/screenpunk-mcp"))
        if plan.sharedGUIConsumers.isEmpty {
            // Only known, fully verified units and marker/selector may be removed.
            for name in plan.versionNames {
                let unit = paths.versions.appendingPathComponent(name)
                let manifest = try DistributionArchive.verify(root: unit,
                    allowLocalTest: allowLocalTest, releaseTrust: trust)
                try removeVerifiedUnit(unit, manifest: manifest)
            }
            var selectorInfo = stat()
            if lstat(paths.current.path, &selectorInfo) == 0,
               unlink(paths.current.path) != 0 {
                throw DistributionError.unavailable
            }
            guard unlink(paths.root.appendingPathComponent("installation.json").path) == 0,
                  rmdir(paths.versions.path) == 0,
                  rmdir(paths.root.path) == 0 else { throw DistributionError.unavailable }
        }
        if plan.purgeMachineState {
            try purger.purgeExactMachineState(at: paths.machineState)
        }
        return .init(interruptedJobs: interrupted,
            preservedWorkspacePaths: plan.preservedWorkspacePaths,
            preservedExternalPaths: plan.preservedExternalPaths,
            preservedMachineState: !plan.purgeMachineState,
            sharedGUIConsumers: plan.sharedGUIConsumers,
            agentConfigurationNotice: "Agent configuration was not edited; remove the stable screenpunk-mcp entry manually if no longer wanted.")
    }

    private func verifyHome() throws {
        guard paths.home.path.hasPrefix("/"), !paths.home.path.contains("/../") else { throw DistributionError.invalidPath }
        var info = stat()
        guard lstat(paths.home.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 else { throw DistributionError.unsafeFile }
    }
    private func prepareDirectories() throws {
        for path in [paths.home.appendingPathComponent(".local"),
                     paths.home.appendingPathComponent(".local/share"), paths.root, paths.versions, paths.bin] {
            if !fm.fileExists(atPath: path.path) {
                try fm.createDirectory(at: path, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            }
            try verifyPrivateDirectory(path)
        }
    }
    private func verifyPrivateDirectory(_ path: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw DistributionError.unsafeFile }
    }
    private func ensureMarker() throws {
        let path = paths.root.appendingPathComponent("installation.json")
        if fm.fileExists(atPath: path.path) { try verifyMarker(); return }
        let marker = InstallationMarker(schemaVersion: 1, owner: "screenpunk-workbench-v1",
                                        canonicalRoot: paths.root.path)
        try JSONEncoder().encode(marker).write(to: path, options: .atomic)
    }
    private func verifyMarker() throws {
        let path = paths.root.appendingPathComponent("installation.json")
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1,
              let value = try? JSONDecoder().decode(InstallationMarker.self, from: Data(contentsOf: path)),
              value.schemaVersion == 1, value.owner == "screenpunk-workbench-v1",
              value.canonicalRoot == paths.root.path else { throw DistributionError.conflict }
    }
    private func verifyRootShape() throws {
        try verifyPrivateDirectory(paths.root)
        let names = Set(try fm.contentsOfDirectory(atPath: paths.root.path))
        guard names.subtracting(["installation.json", "versions", "current"]).isEmpty,
              names.contains("installation.json"), names.contains("versions") else {
            throw DistributionError.conflict
        }
    }
    private func selectedVersion() throws -> String? {
        guard fm.fileExists(atPath: paths.root.path) else { return nil }
        try verifyMarker()
        var info = stat()
        guard lstat(paths.current.path, &info) == 0 else {
            if errno == ENOENT { return nil }; throw DistributionError.unsafeFile
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
              let destination = try? fm.destinationOfSymbolicLink(atPath: paths.current.path),
              destination.hasPrefix("versions/") else { throw DistributionError.conflict }
        let version = String(destination.dropFirst("versions/".count))
        guard DistributionArchive.validVersion(version), destination == "versions/" + version else {
            throw DistributionError.conflict
        }
        return version
    }
    private func installedVersions() throws -> [String] {
        try verifyPrivateDirectory(paths.versions)
        return try fm.contentsOfDirectory(atPath: paths.versions.path).sorted().map { name in
            guard DistributionArchive.validVersion(name) else { throw DistributionError.conflict }
            return name
        }
    }
    private func copyUnit(from source: URL, to stage: URL, manifest: DistributionManifest) throws {
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            for file in manifest.files {
                let destination = stage.appendingPathComponent(file.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: source.appendingPathComponent(file.path), to: destination)
            }
            try fm.copyItem(at: source.appendingPathComponent("release-manifest.json"),
                            to: stage.appendingPathComponent("release-manifest.json"))
            if manifest.provenance == "authenticated-release" {
                try fm.copyItem(at: source.appendingPathComponent(DistributionArchive.authenticationFile),
                                to: stage.appendingPathComponent(DistributionArchive.authenticationFile))
            }
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }
    private func removeVerifiedUnit(_ unit: URL, manifest: DistributionManifest) throws {
        let unitFD = open(unit.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard unitFD >= 0 else { throw DistributionError.unsafeFile }
        defer { close(unitFD) }
        var directories = Set<String>()
        let paths = manifest.files.map(\.path) + [DistributionArchive.manifestFile] +
            (manifest.provenance == "authenticated-release" ? [DistributionArchive.authenticationFile] : [])
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for count in 1..<parts.count { directories.insert(parts.prefix(count).joined(separator: "/")) }
            let parent = try openRelativeDirectory(unitFD, Array(parts.dropLast()))
            defer { close(parent) }
            var info = stat()
            guard fstatat(parent, parts.last!, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
                  info.st_nlink == 1, unlinkat(parent, parts.last!, 0) == 0 else {
                throw DistributionError.unsafeFile
            }
        }
        for directory in directories.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let parts = directory.split(separator: "/").map(String.init)
            let parent = try openRelativeDirectory(unitFD, Array(parts.dropLast()))
            defer { close(parent) }
            guard unlinkat(parent, parts.last!, AT_REMOVEDIR) == 0 else { throw DistributionError.conflict }
        }
        let versionsFD = open(self.paths.versions.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard versionsFD >= 0 else { throw DistributionError.unsafeFile }
        defer { close(versionsFD) }
        guard unlinkat(versionsFD, unit.lastPathComponent, AT_REMOVEDIR) == 0 else {
            throw DistributionError.conflict
        }
    }
    private func openRelativeDirectory(_ root: Int32, _ parts: [String]) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw DistributionError.unavailable }
        for part in parts {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw DistributionError.unsafeFile }
            current = next
        }
        return current
    }
    private func checkSpace(required: Int64) throws {
        var info = statfs()
        guard statfs(paths.versions.path, &info) == 0 else { throw DistributionError.unavailable }
        let available = Double(info.f_bavail) * Double(info.f_bsize)
        guard available >= Double(required) * 1.1 + Double(16 * 1024 * 1024) else {
            throw DistributionError.insufficientSpace
        }
    }
    private func switchCurrent(to version: String) throws {
        guard DistributionArchive.validVersion(version) else { throw DistributionError.invalidPath }
        let temp = paths.root.appendingPathComponent(".selector-" + UUID().uuidString)
        guard symlink("versions/" + version, temp.path) == 0 else { throw DistributionError.unavailable }
        guard rename(temp.path, paths.current.path) == 0 else {
            _ = unlink(temp.path); throw DistributionError.unavailable
        }
    }
    private func checkLauncher(_ path: URL, expected: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            if errno == ENOENT { return }; throw DistributionError.unsafeFile
        }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
              (try? fm.destinationOfSymbolicLink(atPath: path.path)) == expected.path else {
            throw DistributionError.conflict
        }
    }
    private func installLauncher(_ path: URL, target: URL) throws {
        try checkLauncher(path, expected: target)
        var info = stat()
        if lstat(path.path, &info) == 0 { return }
        guard symlink(target.path, path.path) == 0 else { throw DistributionError.unavailable }
    }
    private func removeExactLauncher(_ path: URL, target: URL) throws {
        try checkLauncher(path, expected: target)
        var info = stat()
        if lstat(path.path, &info) == 0, unlink(path.path) != 0 { throw DistributionError.unavailable }
    }
    private func retainedDataPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              path != paths.root.path, !path.hasPrefix(paths.root.path + "/"),
              path != paths.machineState.path else { throw DistributionError.invalidPath }
        return path
    }
    private func fingerprint(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
