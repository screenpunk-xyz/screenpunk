import Foundation
import Darwin
import ScreenpunkController
import ScreenpunkDistribution

public struct WorkbenchInstallationInventory {
    public let workspaceSchema: Int
    public let workspaces: [String]
    public let externalProjects: [String]
    public init(workspaceSchema: Int, workspaces: [String], externalProjects: [String]) {
        self.workspaceSchema = workspaceSchema
        self.workspaces = workspaces
        self.externalProjects = externalProjects
    }
}

public protocol WorkbenchInstalledServiceControl {
    func enable() throws
    func disable() throws
    func verifiedLogPath() throws -> URL
}
extension LaunchdUserAdapter: WorkbenchInstalledServiceControl {}

/// Injection is used by private-root tests. Executable entrypoints construct
/// the production context with rejecting release trust and fixed user paths.
public struct WorkbenchLifecycleContext {
    public let installer: ScreenpunkInstaller
    public let inventory: () throws -> WorkbenchInstallationInventory
    public let serviceControl: (any WorkbenchInstalledServiceControl)?
    public init(installer: ScreenpunkInstaller,
                inventory: @escaping () throws -> WorkbenchInstallationInventory,
                serviceControl: (any WorkbenchInstalledServiceControl)? = nil) {
        self.installer = installer; self.inventory = inventory
        self.serviceControl = serviceControl
    }

    static func production(options: Options, environment: [String: String]) throws -> Self {
        guard options.home == nil, options.runtime == nil, options.workspace == nil else {
            throw Options.usage("Installation lifecycle uses fixed per-user paths; omit --home, --runtime-directory, and --workspace.")
        }
        let paths = InstallationPaths(home: FileManager.default.homeDirectoryForCurrentUser)
        let packageRoot = WorkbenchProductionTrust.homebrewRoot()
        let packageVersion = try packageRoot.map { try WorkbenchProductionTrust.verifyPackage($0).version }
        let controllerHome = paths.machineState.appendingPathComponent("Controller")
        let runtime = try WorkbenchBrokerEnvironment(runtimeDirectory:
            paths.machineState.appendingPathComponent("Runtime"))
        let launchctl = BoundedUserLaunchctl(paths: paths)
        let observation = WorkbenchBrokerLifecycleObservation(paths: paths,
            broker: runtime, controllerHome: controllerHome,
            identity: LaunchdProcessIdentityProbe(launchctl: launchctl, paths: paths, packageRoot: packageRoot),
            packageVersion: packageVersion)
        let adapter = LaunchdUserAdapter(observation: observation, paths: paths,
            controllerHome: controllerHome, runtimeDirectory: runtime.runtimeDirectory,
            logDirectory: paths.machineState.appendingPathComponent("Logs"),
            launchctl: launchctl, serviceExecutable: packageRoot?.appendingPathComponent("libexec/screenpunk-service"))
        let installer = ScreenpunkInstaller(paths: paths, service: adapter,
            releaseTrust: ScreenpunkProductionReleaseTrust(),
            prepareVerifiedPayload: { root, manifest in
                try WorkbenchProductionTrust.prepareVerifiedPayload(root: root,
                    manifest: manifest, paths: paths)
            })
        return .init(installer: installer, inventory: {
            let workspace = try WorkspaceStore(documents: CLIWorkspaceDocuments(environment: environment),
                machineRootPath: runtime.runtimeDirectory.appendingPathComponent("machine").path)
            let current = try workspace.current()
            let bindings = try workspace.selection.current()?.externalBindings.values.map(\.path) ?? []
            return .init(workspaceSchema: current?.descriptor.schemaVersion ?? 1,
                workspaces: current.map { [$0.path] } ?? [],
                externalProjects: Array(Set(bindings)).sorted())
        }, serviceControl: adapter)
    }
}

/// Actual broker lifecycle reporting. No process, GUI consumer or interrupted
/// job is inferred from a missing socket. A clean install may report absence
/// only when the selector, owned launch agent and broker locator are all absent.
final class WorkbenchBrokerLifecycleObservation: WorkbenchServiceObservation {
    private let paths: InstallationPaths
    private let broker: WorkbenchBrokerEnvironment
    private let controllerHome: URL
    private let identity: InstalledServiceIdentityProbing
    private let packageVersion: String?
    private let assertGUIAbsent: () throws -> Void
    init(paths: InstallationPaths, broker: WorkbenchBrokerEnvironment, controllerHome: URL,
         identity: InstalledServiceIdentityProbing, packageVersion: String? = nil,
         assertGUIAbsent: @escaping () throws -> Void = {
             try WorkbenchGUIAbsenceProbe.production().assertAbsent()
         }) {
        self.paths = paths; self.broker = broker
        self.controllerHome = controllerHome; self.identity = identity; self.packageVersion = packageVersion
        self.assertGUIAbsent = assertGUIAbsent
    }
    private func absent(_ path: String) throws -> Bool {
        var metadata = stat()
        if lstat(path, &metadata) == 0 { return false }
        guard errno == ENOENT else { throw DistributionError.unavailable }
        return true
    }
    private func cleanAbsence() throws -> Bool {
        try absent(paths.current.path) && absent(paths.launchAgent.path) &&
            absent(broker.runtimeDirectory.appendingPathComponent("broker.locator.json").path)
    }
    private func client() throws -> WorkbenchBrokerClient {
        let client = WorkbenchBrokerClient(environment: broker)
        try client.connect()
        return client
    }
    private func emptyVerifiedGUI(_ value: WorkbenchServiceLifecycleResult) throws {
        guard value.guiConsumers.isEmpty else {
            throw DistributionError.unavailable
        }
        // Registered-consumer data cannot establish absence of an unregistered
        // GUI. Always obtain fresh host-owned evidence, including for CLI-only
        // brokers whose wire evidence deliberately remains unknown.
        try assertGUIAbsent()
    }
    private func selectedVersion() throws -> String {
        if let packageVersion { return packageVersion }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path)
        guard target.hasPrefix("versions/"),
              DistributionArchive.validVersion(String(target.dropFirst("versions/".count))) else {
            throw DistributionError.conflict
        }
        return String(target.dropFirst("versions/".count))
    }
    private func verifyInstalledBroker(_ connection: WorkbenchBrokerClient,
                                       version: String) throws {
        let health = try connection.health()
        guard health.apiVersion == "1.0", health.status == "ready",
              health.controllerHomePath == controllerHome.resolvingSymlinksInPath().path,
              try identity.runningServiceMatches(version: version) else {
            throw DistributionError.unavailable
        }
    }
    func drainAndReportInterruptedJobs() throws -> [String] {
        if try cleanAbsence() { return [] }
        let connection = try client(); defer { connection.close() }
        try verifyInstalledBroker(connection, version: selectedVersion())
        try emptyVerifiedGUI(connection.serviceLifecycle())
        let drained = try connection.drainService()
        try emptyVerifiedGUI(drained)
        return drained.interruptedJobIDs
    }
    func healthy(expectedVersion: String) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        repeat {
            if let connection = try? client() {
                defer { connection.close() }
                do { try verifyInstalledBroker(connection, version: expectedVersion); return true }
                catch { return false }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    func stopAndReportInterruptedJobs() throws -> [String] {
        if try cleanAbsence() { return [] }
        let connection = try client(); defer { connection.close() }
        try verifyInstalledBroker(connection, version: selectedVersion())
        // The separately confirmed legacy installer retains its explicit
        // drain semantics. Homebrew removal always has a verified package version.
        if packageVersion == nil {
            try emptyVerifiedGUI(connection.serviceLifecycle())
            let drained = try connection.drainService()
            try emptyVerifiedGUI(drained)
            _ = try connection.stopService()
            return drained.interruptedJobIDs
        }
        let status = try connection.serviceLifecycle()
        guard status.guiConsumers.isEmpty else { throw WorkbenchPackageRemovalRefusal.guiActive }
        guard status.activeJobIDs.isEmpty, status.state == "healthy" else {
            throw WorkbenchPackageRemovalRefusal.busy
        }
        try removalGUIAbsent(status)
        let prepared: WorkbenchServiceLifecycleResult
        do { prepared = try connection.prepareServiceRemoval() }
        catch let error as WorkbenchIPCError where error.code == .serviceBusy {
            throw WorkbenchPackageRemovalRefusal.busy
        }
        try removalGUIAbsent(prepared)
        do { _ = try connection.stopService() }
        catch let error as WorkbenchIPCError where error.code == .serviceBusy {
            throw WorkbenchPackageRemovalRefusal.busy
        }
        return []
    }
    private func removalGUIAbsent(_ value: WorkbenchServiceLifecycleResult) throws {
        guard value.guiConsumers.isEmpty else { throw WorkbenchPackageRemovalRefusal.guiActive }
        do { try assertGUIAbsent() }
        catch { throw WorkbenchPackageRemovalRefusal.guiEvidenceUnavailable }
    }
    func compatibleGUIConsumers() throws -> [String] {
        if try cleanAbsence() { return [] }
        let connection = try client(); defer { connection.close() }
        try verifyInstalledBroker(connection, version: selectedVersion())
        let status = try connection.serviceLifecycle()
        if status.guiConsumers.isEmpty { try assertGUIAbsent() }
        return status.guiConsumers
    }
}

enum WorkbenchPackageRemovalRefusal: Error {
    case busy, guiActive, guiEvidenceUnavailable
}

enum WorkbenchLifecycleCLI {
    static func serviceToggle(_ verb: String, context: WorkbenchLifecycleContext,
                              presentation: Presentation) throws {
        guard let control = context.serviceControl else { throw DistributionError.unavailable }
        switch verb {
        case "enable": try control.enable()
        case "disable": try control.disable()
        default: throw Options.usage("Use service enable or service disable.")
        }
        presentation.success(["state": verb == "enable" ? "enabled" : "disabled",
            "startPolicy": verb == "enable" ? "registered_on_demand" : "automatic_start_disabled"],
            human: verb == "enable"
                ? "Enabled the verified installed user service. It starts on demand."
                : "Disabled automatic start of the verified installed user service; an already running process is unchanged.")
    }

    static func serviceLogs(context: WorkbenchLifecycleContext,
                            presentation: Presentation) throws {
        guard let control = context.serviceControl else { throw DistributionError.unavailable }
        let log = try sanitizedLog(at: control.verifiedLogPath())
        presentation.success(["state": log.state, "events": log.events,
            "redactedLineCount": log.redactedLineCount,
            "truncated": log.truncated],
            human: log.events.isEmpty
                ? "No recognized service events. Redacted lines: \(log.redactedLineCount)."
                : log.events.joined(separator: "\n") + "\nRedacted lines: \(log.redactedLineCount).")
    }

    struct SanitizedLog {
        let state: String
        let events: [String]
        let redactedLineCount: Int
        let truncated: Bool
    }

    static func sanitizedLog(at url: URL) throws -> SanitizedLog {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT {
            return .init(state: "empty", events: [], redactedLineCount: 0, truncated: false)
        }
        guard fd >= 0 else { throw DistributionError.unavailable }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o022) == 0,
              metadata.st_size >= 0 else { throw DistributionError.conflict }
        let maximum = 64 * 1024
        let truncated = metadata.st_size > maximum
        let start = max(off_t(0), metadata.st_size - off_t(maximum))
        guard lseek(fd, start, SEEK_SET) == start else { throw DistributionError.unavailable }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while bytes.count < maximum {
            let count = Darwin.read(fd, &chunk, min(chunk.count, maximum - bytes.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DistributionError.unavailable }
            if count == 0 { break }
            bytes.append(contentsOf: chunk.prefix(count))
        }
        var lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if truncated && !lines.isEmpty { lines.removeFirst() }
        let recent = Array(lines.suffix(200))
        var events: [String] = []
        var redacted = 0
        for line in recent {
            let value = String(line)
            if value.contains("Screenpunk workbench broker ready") {
                events.append("broker_ready")
            } else if value == "Service stopped." {
                events.append("service_stopped")
            } else if value.hasPrefix("release_untrusted:") {
                events.append("release_untrusted")
            } else if value.hasPrefix("runtime_unavailable:") {
                events.append("runtime_unavailable")
            } else if value.hasPrefix("insecureRuntime:") || value.hasPrefix("insecure_runtime:") {
                events.append("insecure_runtime")
            } else if value.hasPrefix("mcp_error") {
                events.append("mcp_error")
            } else if !value.isEmpty {
                redacted += 1
            }
        }
        return .init(state: "available", events: events,
            redactedLineCount: redacted, truncated: truncated || lines.count > 200)
    }

    static func run(words: [String], context: WorkbenchLifecycleContext,
                    presentation: Presentation) throws {
        let inventory = try context.inventory()
        let installer = context.installer
        switch (words.first, words.dropFirst().first, words.count) {
        case ("install", "plan", 3), ("update", "check", 3), ("update", "plan", 3):
            let archive = try archiveURL(words[2])
            let plan = try installer.plan(archive: archive,
                workspaceSchema: inventory.workspaceSchema, protocolVersion: 1)
            guard words[0] != "update" || plan.action == .update else {
                throw DistributionError.incompatible
            }
            try present(plan, presentation: presentation)
        case ("install", "apply", 4), ("update", "install", 4):
            let archive = try archiveURL(words[2]); let token = words[3]
            let plan = try installer.plan(archive: archive,
                workspaceSchema: inventory.workspaceSchema, protocolVersion: 1)
            guard words[0] != "update" || plan.action == .update else {
                throw DistributionError.incompatible
            }
            let outcome = try installer.execute(plan, confirming: token)
            presentation.success(["selectedVersion": outcome.selectedVersion,
                "interruptedJobIDs": outcome.interruptedJobs,
                "retainedPreviousVersion": outcome.retainedPreviousVersion.map { $0 as Any } ?? NSNull(),
                "pathGuidance": outcome.pathGuidance],
                human: "Selected Screenpunk \(outcome.selectedVersion). Interrupted jobs: \(outcome.interruptedJobs.count). \(TerminalPresentation.safe(outcome.pathGuidance))")
        case ("update", "rollback", 4) where words[2] == "plan":
            let archive = try archiveURL(words[3])
            let plan = try installer.plan(archive: archive,
                workspaceSchema: inventory.workspaceSchema, protocolVersion: 1,
                rollback: true)
            try present(plan, presentation: presentation)
        case ("update", "rollback", 5) where words[2] == "apply":
            let archive = try archiveURL(words[3])
            let plan = try installer.plan(archive: archive,
                workspaceSchema: inventory.workspaceSchema, protocolVersion: 1,
                rollback: true)
            let outcome = try installer.execute(plan, confirming: words[4])
            presentation.success(["selectedVersion": outcome.selectedVersion,
                "interruptedJobIDs": outcome.interruptedJobs,
                "retainedPreviousVersion": outcome.retainedPreviousVersion.map { $0 as Any } ?? NSNull(),
                "pathGuidance": outcome.pathGuidance],
                human: "Rolled back to Screenpunk \(outcome.selectedVersion). Interrupted jobs: \(outcome.interruptedJobs.count). \(TerminalPresentation.safe(outcome.pathGuidance))")
        case ("uninstall", "plan", 2):
            let plan = try installer.planUninstall(workspaces: inventory.workspaces,
                externalProjects: inventory.externalProjects)
            try present(plan, presentation: presentation)
        case ("uninstall", "apply", 3):
            let token = words[2]
            let plan = try installer.planUninstall(workspaces: inventory.workspaces,
                externalProjects: inventory.externalProjects)
            let outcome = try installer.executeUninstall(plan, confirming: token)
            presentation.success(["interruptedJobIDs": outcome.interruptedJobs,
                "preservedWorkspacePaths": outcome.preservedWorkspacePaths,
                "preservedExternalPaths": outcome.preservedExternalPaths,
                "preservedMachineState": outcome.preservedMachineState,
                "sharedGUIConsumers": outcome.sharedGUIConsumers,
                "agentConfigurationNotice": outcome.agentConfigurationNotice],
                human: "Uninstalled owned launchers. Workspaces and external projects remain at their listed paths. \(TerminalPresentation.safe(outcome.agentConfigurationNotice))")
        default:
            throw Options.usage("Use install plan|apply ARCHIVE [TOKEN], update check|plan ARCHIVE, update install ARCHIVE TOKEN, update rollback plan ARCHIVE or apply ARCHIVE TOKEN, or uninstall plan|apply [TOKEN].")
        }
    }

    private static func archiveURL(_ path: String) throws -> URL {
        guard WorkspacePath.isAbsolute(path) else {
            throw Options.usage("The release archive must have an absolute path without dot traversal.")
        }
        return URL(fileURLWithPath: WorkspacePath.canonical(path), isDirectory: true)
    }

    private static func present(_ plan: InstallationPlan, presentation: Presentation) throws {
        let details: [String: Any] = ["action": plan.action.rawValue, "version": plan.version,
            "previousVersion": plan.previousVersion.map { $0 as Any } ?? NSNull(), "archive": plan.archive.path,
            "manifestHash": plan.manifestHash, "workspaceSchema": plan.workspaceSchema,
            "protocolVersion": plan.protocolVersion, "requiredBytes": plan.requiredBytes,
            "confirmation": plan.confirmation, "effects": plan.effects]
        let effects = try plan.effects.map(exactReviewText)
        presentation.success(details, human: "\(plan.action.rawValue.capitalized) \(plan.version)\nArchive: \(try exactReviewText(plan.archive.path))\nManifest: \(plan.manifestHash)\nConfirmation: \(plan.confirmation)\n\(effects.joined(separator: "\n"))")
    }
    private static func present(_ plan: UninstallPlan, presentation: Presentation) throws {
        let details: [String: Any] = ["versionNames": plan.versionNames,
            "preservedWorkspacePaths": plan.preservedWorkspacePaths,
            "preservedExternalPaths": plan.preservedExternalPaths,
            "purgeMachineState": plan.purgeMachineState,
            "sharedGUIConsumers": plan.sharedGUIConsumers,
            "confirmation": plan.confirmation, "effects": plan.effects]
        let workspacePaths = try plan.preservedWorkspacePaths.map(exactReviewText)
        let externalPaths = try plan.preservedExternalPaths.map(exactReviewText)
        let effects = try plan.effects.map(exactReviewText)
        presentation.success(details, human: "Remove installation versions: \(plan.versionNames.joined(separator: ", "))\nRetain workspaces: \(workspacePaths.joined(separator: ", "))\nRetain external projects: \(externalPaths.joined(separator: ", "))\nConfirmation: \(plan.confirmation)\n\(effects.joined(separator: "\n"))")
    }

    static func exactReviewText(_ value: String) throws -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let unsafe = code < 0x20 || (0x7f...0x9f).contains(code)
                || (0x202a...0x202e).contains(code) || (0x2066...0x2069).contains(code)
                || code == 0x061c || code == 0x200e || code == 0x200f
                || code == 0x2028 || code == 0x2029
            escaped += unsafe ? String(format: "\\u{%04X}", code) : String(scalar)
            guard escaped.utf8.count <= 4096 else {
                throw CommandFailure("review_text_too_long",
                    "The installation review contains a path too long to display exactly.", 8)
            }
        }
        return escaped
    }
    static func failure(_ error: DistributionError) -> CommandFailure {
        let code: String
        switch error {
        case .untrustedRelease: code = "release_untrusted"
        case .invalidManifest, .integrity, .incompletePayload: code = "release_invalid"
        case .incompatible: code = "release_incompatible"
        case .conflict, .alreadyExists: code = "installation_conflict"
        case .invalidPath, .unsafeFile: code = "installation_unsafe_path"
        case .insufficientSpace: code = "insufficient_space"
        case .recoveryRequired: code = "installation_recovery_required"
        case .unavailable: code = "installation_unavailable"
        }
        return CommandFailure(code,
            "The Screenpunk installation operation could not complete (\(error)).", 8)
    }
}
