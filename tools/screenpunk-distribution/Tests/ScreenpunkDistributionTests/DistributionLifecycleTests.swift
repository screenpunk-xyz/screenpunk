import XCTest
import Foundation
@testable import ScreenpunkDistribution

/// Emits launchctl's closed print grammar so lifecycle tests exercise the
/// production ownership parser without executing launchctl or a service.
private final class LegacyReplacementProcess: ArgumentProcessRunning {
    var state: OwnedLaunchdJobState = .absent
    var failBootout = false
    var retainJobAfterBootout = false
    var calls: [[String]] = []
    var plist = ""
    var serviceArguments: [String] = []
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval, maximumOutputBytes: Int) throws -> BoundedProcessResult {
        calls.append(arguments)
        switch arguments.first {
        case "bootstrap":
            plist = arguments[2]
            let value = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: plist)), options: [], format: nil) as! [String: Any]
            serviceArguments = value["ProgramArguments"] as! [String]
            state = .registeredWithoutProcess
        case "kickstart": state = .running
        case "bootout":
            if failBootout { return .init(exitStatus: 5, stdout: Data(), stderr: Data("failed".utf8)) }
            if !retainJobAfterBootout { state = .absent }
        case "print":
            if state == .absent {
                let uid = arguments[1].split(separator: "/")[1]
                return .init(exitStatus: 113, stdout: Data(), stderr: Data(
                    "Could not find service \"com.screenpunk.workbench\" in domain for user gui: \(uid)".utf8))
            }
            let stateLine = state == .running ? "state = running\n\tpid = 42" :
                (state == .registeredWithoutProcess ? "state = not running" : "state = unknown")
            let text = "\(arguments[1]) = {\n\tpath = \(plist)\n\tprogram = \(serviceArguments[0])\n\targuments = {\n" +
                serviceArguments.map { "\t\t" + $0 + "\n" }.joined() + "\t}\n\t\(stateLine)\n}\n"
            return .init(exitStatus: 0, stdout: Data(text.utf8), stderr: Data())
        default: XCTFail("Unexpected launchctl command")
        }
        return .init(exitStatus: 0, stdout: Data(), stderr: Data())
    }
}

private final class LegacyReplacementObservation: WorkbenchServiceObservation {
    var drains = 0
    var healthyVersions: Set<String> = ["1.0.0", "1.1.0"]
    func drainAndReportInterruptedJobs() throws -> [String] { drains += 1; return [] }
    func healthy(expectedVersion: String) throws -> Bool { healthyVersions.contains(expectedVersion) }
    func stopAndReportInterruptedJobs() throws -> [String] { [] }
    func compatibleGUIConsumers() throws -> [String] { [] }
}

private final class FakeService: InstallationServiceLifecycle {
    var healthy = true
    var healthyVersions: Set<String>? = nil
    var interrupted: [String] = []
    var consumers: [String] = []
    var registered: [String] = []
    var registeredVersions: [String] = []
    var stopped = false
    func drain() throws -> [String] { interrupted }
    func register(serviceExecutable: URL, plist: URL) throws {
        registered.append(serviceExecutable.path)
        let selector = serviceExecutable.deletingLastPathComponent().deletingLastPathComponent()
        registeredVersions.append((try? FileManager.default.destinationOfSymbolicLink(
            atPath: selector.path)) ?? "missing")
    }
    func health(version: String) throws -> Bool { healthyVersions?.contains(version) ?? healthy }
    func stopAndUnregister(plist: URL) throws -> [String] { stopped = true; return interrupted }
    func compatibleGUIConsumers() throws -> [String] { consumers }
}
private final class FakeLaunchctl: LaunchctlRunning {
    var calls: [[String]] = []
    func run(_ arguments: [String]) throws -> String { calls.append(arguments); return "fake status" }
}
private struct FakeObservation: WorkbenchServiceObservation {
    func drainAndReportInterruptedJobs() throws -> [String] { [] }
    func healthy(expectedVersion: String) throws -> Bool { true }
    func stopAndReportInterruptedJobs() throws -> [String] { [] }
    func compatibleGUIConsumers() throws -> [String] { [] }
}

private final class FailedActivationProcess: ArgumentProcessRunning {
    var state: OwnedLaunchdJobState = .absent
    var failBootstrap = false
    var retainUnknownState = false
    var calls: [[String]] = []
    var plistPath: String = ""
    var programArguments: [String] = []
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval, maximumOutputBytes: Int) throws -> BoundedProcessResult {
        calls.append(arguments)
        switch arguments.first {
        case "bootstrap":
            if failBootstrap { return .init(exitStatus: 5, stdout: Data(), stderr: Data("Bootstrap failed".utf8)) }
            plistPath = arguments[2]
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)),
                                                                   options: [], format: nil) as! [String: Any]
            programArguments = plist["ProgramArguments"] as! [String]
            state = retainUnknownState ? .unknown : .registeredWithoutProcess
        case "bootout": state = .absent
        case "print":
            let target = arguments[1]
            if state == .absent {
                let uid = target.split(separator: "/")[1]
                return .init(exitStatus: 113, stdout: Data(), stderr: Data(
                    "Bad request.\nCould not find service \"com.screenpunk.workbench\" in domain for user gui: \(uid)\n".utf8))
            }
            let stateText = state == .registeredWithoutProcess ? "not running" : "unknown"
            let loaded = "\(target) = {\n\tpath = \(plistPath)\n\tprogram = \(programArguments.first ?? "")\n\targuments = {\n" +
                programArguments.map { "\t\t" + $0 + "\n" }.joined() + "\t}\n\tstate = \(stateText)\n}\n"
            return .init(exitStatus: 0, stdout: Data(loaded.utf8), stderr: Data())
        default: break
        }
        return .init(exitStatus: 0, stdout: Data(), stderr: Data())
    }
}

private struct UnreachableFreshBroker: WorkbenchServiceObservation {
    func drainAndReportInterruptedJobs() throws -> [String] { [] }
    func healthy(expectedVersion: String) throws -> Bool { false }
    func stopAndReportInterruptedJobs() throws -> [String] { throw DistributionError.unavailable }
    func compatibleGUIConsumers() throws -> [String] { throw DistributionError.unavailable }
}

final class DistributionLifecycleTests: XCTestCase {
    func testLegacyRunningUpdateReplacesPositivelyOwnedJob() throws { try legacyReplacement(state: .running) }
    func testLegacyIdleUpdateReplacesPositivelyOwnedJob() throws { try legacyReplacement(state: .registeredWithoutProcess) }
    func testLegacyReinstallReplacesPositivelyOwnedJob() throws { try legacyReplacement(state: .running, reinstall: true) }
    func testLegacyIdleReinstallReplacesPositivelyOwnedJob() throws { try legacyReplacement(state: .registeredWithoutProcess, reinstall: true) }
    func testLegacyRollbackReplacesPositivelyOwnedJob() throws { try legacyReplacement(state: .running, rollback: true) }
    func testLegacyIdleRollbackReplacesPositivelyOwnedJob() throws { try legacyReplacement(state: .registeredWithoutProcess, rollback: true) }
    func testLegacyFailedHealthRestoresPreviousRunningVersion() throws { try legacyReplacement(state: .running, failHealth: true) }
    func testLegacyIdleFailedHealthRestoresPreviousRunningVersion() throws { try legacyReplacement(state: .registeredWithoutProcess, failHealth: true) }
    func testLegacyUnknownJobCannotBeReplaced() throws { try legacyReplacement(state: .unknown) }
    func testLegacyFailedBootoutCannotBootstrapReplacement() throws { try legacyReplacement(state: .running, failBootout: true) }
    func testLegacyRetainedJobCannotBootstrapReplacement() throws { try legacyReplacement(state: .registeredWithoutProcess, retainJob: true) }

    private func legacyReplacement(state: OwnedLaunchdJobState, reinstall: Bool = false,
                                   rollback: Bool = false, failHealth: Bool = false,
                                   failBootout: Bool = false, retainJob: Bool = false) throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let process = LegacyReplacementProcess(), observation = LegacyReplacementObservation()
        let adapter = LaunchdUserAdapter(observation: observation, paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("Controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("Runtime"), uid: 501,
            logDirectory: paths.machineState.appendingPathComponent("Logs"),
            launchctl: BoundedUserLaunchctl(runner: process, uid: 501, paths: paths))
        let installer = ScreenpunkInstaller(paths: paths, service: adapter, allowLocalTest: true)
        let first = try archive(base, version: "1.0.0"), second = try archive(base, version: "1.1.0")
        let initial = try installer.plan(archive: first, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(initial, confirming: initial.confirmation)
        if rollback {
            let forward = try installer.plan(archive: second, workspaceSchema: 1, protocolVersion: 1)
            _ = try installer.execute(forward, confirming: forward.confirmation)
        }
        let previous = rollback ? "1.1.0" : "1.0.0"
        let target = rollback || reinstall ? "1.0.0" : "1.1.0"
        process.state = state; process.failBootout = failBootout; process.retainJobAfterBootout = retainJob
        if failHealth { observation.healthyVersions = [previous] }
        let callsBefore = process.calls.count, drainsBefore = observation.drains
        let plistBefore = try Data(contentsOf: paths.launchAgent)
        let plan = try installer.plan(archive: target == "1.0.0" ? first : second,
            workspaceSchema: 1, protocolVersion: 1, rollback: rollback)
        let blocked = state == .unknown || failBootout || retainJob
        if blocked || failHealth {
            XCTAssertThrowsError(try installer.execute(plan, confirming: plan.confirmation)) {
                XCTAssertEqual($0 as? DistributionError, blocked ? .recoveryRequired : .unavailable)
            }
        } else {
            XCTAssertEqual(try installer.execute(plan, confirming: plan.confirmation).selectedVersion, target)
        }
        XCTAssertEqual(observation.drains, drainsBefore + 1)
        XCTAssertEqual(try current(paths), "versions/" + ((blocked || failHealth) ? previous : target))
        let actions = process.calls.dropFirst(callsBefore).filter { $0.first != "print" }.map { $0[0] }
        if state == .unknown {
            XCTAssertEqual(actions, [])
        } else if failBootout || retainJob {
            XCTAssertFalse(actions.contains("bootstrap"))
            XCTAssertFalse(actions.contains("kickstart"))
            XCTAssertEqual(try Data(contentsOf: paths.launchAgent), plistBefore)
        } else {
            XCTAssertEqual(actions, failHealth ? ["bootout", "bootstrap", "kickstart", "bootout", "bootstrap", "kickstart"] :
                ["bootout", "bootstrap", "kickstart"])
            XCTAssertEqual(process.state, .running)
        }
    }

    private func base() throws -> URL {
        let result = URL(fileURLWithPath: "/private/tmp/sp-distribution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return result
    }
    private func home(_ base: URL) throws -> InstallationPaths {
        let value = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return InstallationPaths(home: value)
    }
    private func archive(_ base: URL, version: String,
                         workspaceSchema: ClosedRange<Int> = 1...1) throws -> URL {
        let payload = base.appendingPathComponent("payload-" + version)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let contents: [String: String] = [
            "bin/screenpunk": "#!/bin/sh\necho screenpunk-\(version)\n",
            "bin/screenpunk-mcp": "#!/bin/sh\necho mcp-\(version)\n",
            "libexec/screenpunk-service": "#!/bin/sh\necho service-\(version)\n",
            "Resources/AuthoringKit/LOCAL-TEST-ONLY.txt": "Compiler and Node absent in this synthetic fixture.\n",
            "Resources/help/README.txt": "help\n", "Resources/contracts/workspace.json": "{}\n",
            "LICENSES/NOTICE.txt": "test notice\n", "SBOM.json": "{\"testOnly\":true}\n"
        ]
        for (path, text) in contents {
            let destination = payload.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: destination)
            if path.hasPrefix("bin/") || path.hasPrefix("libexec/") {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            }
        }
        let result = base.appendingPathComponent("archive-" + version)
        _ = try DistributionArchive.assembleLocalTest(payload: payload, output: result,
            version: version, workspaceSchema: workspaceSchema)
        return result
    }
    private func current(_ paths: InstallationPaths) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path)
    }

    func testCleanInstallReinstallUpdateAndHealthRollback() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService()
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let first = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: first, workspaceSchema: 1, protocolVersion: 1)
        XCTAssertEqual(plan.action, .install)
        XCTAssertThrowsError(try installer.execute(plan, confirming: "wrong"))
        let installed = try installer.execute(plan, confirming: plan.confirmation)
        XCTAssertEqual(installed.selectedVersion, "1.0.0")
        XCTAssertEqual(try current(paths), "versions/1.0.0")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.cli.path),
                       paths.current.appendingPathComponent("bin/screenpunk").path)
        let reinstall = try installer.plan(archive: first, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(reinstall, confirming: reinstall.confirmation)
        let second = try archive(base, version: "1.1.0")
        service.interrupted = ["job-7"]
        service.healthyVersions = ["1.0.0"]
        let update = try installer.plan(archive: second, workspaceSchema: 1, protocolVersion: 1)
        XCTAssertThrowsError(try installer.execute(update, confirming: update.confirmation))
        XCTAssertEqual(try current(paths), "versions/1.0.0")
        XCTAssertEqual(Array(service.registeredVersions.suffix(2)), ["versions/1.1.0", "versions/1.0.0"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.versions.appendingPathComponent("1.1.0").path))
        service.healthyVersions = ["1.0.0", "1.1.0"]
        let retry = try installer.plan(archive: second, workspaceSchema: 1, protocolVersion: 1)
        let result = try installer.execute(retry, confirming: retry.confirmation)
        XCTAssertEqual(result.interruptedJobs, ["job-7"])
        XCTAssertEqual(try current(paths), "versions/1.1.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.versions.appendingPathComponent("1.0.0").path))
    }

    func testFailedInitialHealthUnregistersAndRemovesLaunchers() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService(); service.healthy = false
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        XCTAssertThrowsError(try installer.execute(plan, confirming: plan.confirmation))
        XCTAssertTrue(service.stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cli.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.mcp.path))
    }

    func testFreshFailedBootstrapRecoversWithoutReachableBroker() throws {
        try exerciseFreshFailedActivation(failBootstrap: true)
    }

    func testFreshStartupExitRecoversWithoutReachableBroker() throws {
        try exerciseFreshFailedActivation(failBootstrap: false)
    }

    private func exerciseFreshFailedActivation(failBootstrap: Bool) throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let process = FailedActivationProcess(); process.failBootstrap = failBootstrap
        let launchctl = BoundedUserLaunchctl(runner: process, paths: paths)
        let adapter = LaunchdUserAdapter(observation: UnreachableFreshBroker(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("Controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("Runtime"),
            logDirectory: paths.machineState.appendingPathComponent("Logs"), launchctl: launchctl)
        let installer = ScreenpunkInstaller(paths: paths, service: adapter, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        XCTAssertThrowsError(try installer.execute(plan, confirming: plan.confirmation)) {
            XCTAssertEqual($0 as? DistributionError, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cli.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.mcp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.versions.appendingPathComponent("1.0.0").path))
        XCTAssertEqual(process.calls.contains { $0.first == "bootout" }, !failBootstrap)
    }

    func testFreshUnknownJobStatePreservesOwnedResourcesForRecovery() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let process = FailedActivationProcess(); process.retainUnknownState = true
        let adapter = LaunchdUserAdapter(observation: UnreachableFreshBroker(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("Controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("Runtime"),
            logDirectory: paths.machineState.appendingPathComponent("Logs"),
            launchctl: BoundedUserLaunchctl(runner: process, paths: paths))
        let installer = ScreenpunkInstaller(paths: paths, service: adapter, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        XCTAssertThrowsError(try installer.execute(plan, confirming: plan.confirmation)) {
            XCTAssertEqual($0 as? DistributionError, .recoveryRequired)
        }
        XCTAssertEqual(try current(paths), "versions/1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.launchAgent.path))
        XCTAssertFalse(process.calls.contains { $0.first == "bootout" })
    }

    func testFailedRollbackHealthReportsRecoveryRequired() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService()
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let first = try archive(base, version: "1.0.0")
        let install = try installer.plan(archive: first, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(install, confirming: install.confirmation)
        service.healthyVersions = []
        let second = try archive(base, version: "1.1.0")
        let update = try installer.plan(archive: second, workspaceSchema: 1, protocolVersion: 1)
        XCTAssertThrowsError(try installer.execute(update, confirming: update.confirmation)) { error in
            XCTAssertEqual(error as? DistributionError, .recoveryRequired)
        }
        XCTAssertEqual(try current(paths), "versions/1.0.0")
        XCTAssertEqual(Array(service.registeredVersions.suffix(2)), ["versions/1.1.0", "versions/1.0.0"])
    }

    func testRejectsIncompatibleSchemaAndUnrelatedLauncher() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService()
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let artifact = try archive(base, version: "2.0.0", workspaceSchema: 1...2)
        XCTAssertThrowsError(try installer.plan(archive: artifact, workspaceSchema: 3, protocolVersion: 1))
        try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("unrelated".utf8).write(to: paths.cli)
        XCTAssertThrowsError(try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1))
        XCTAssertEqual(try Data(contentsOf: paths.cli), Data("unrelated".utf8))
    }

    func testFullInventoryRejectsTamperingAndTestArtifactIsNotProductionTrusted() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let artifact = try archive(base, version: "1.0.0")
        XCTAssertEqual(try DistributionArchive.verify(root: artifact, allowLocalTest: true).files.count, 8)
        XCTAssertThrowsError(try DistributionArchive.verify(root: artifact, allowLocalTest: false))
        let changed = artifact.appendingPathComponent("Resources/help/README.txt")
        try Data("changed".utf8).write(to: changed)
        XCTAssertThrowsError(try DistributionArchive.verify(root: artifact, allowLocalTest: true))
    }

    func testUninstallPreservesWorkspacesExternalAndMachineState() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService()
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(plan, confirming: plan.confirmation)
        let workspace = base.appendingPathComponent("visible workspace")
        let external = base.appendingPathComponent("external project")
        let machine = paths.machineState
        for folder in [workspace, external, machine] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data("retain".utf8).write(to: folder.appendingPathComponent("marker"))
        }
        let removal = try installer.planUninstall(workspaces: [workspace.path], externalProjects: [external.path])
        XCTAssertThrowsError(try installer.executeUninstall(removal, confirming: "wrong"))
        let outcome = try installer.executeUninstall(removal, confirming: removal.confirmation)
        XCTAssertTrue(service.stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cli.path))
        XCTAssertEqual(outcome.preservedWorkspacePaths, [workspace.path])
        for folder in [workspace, external, machine] {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("marker")), Data("retain".utf8))
        }
    }

    func testSharedConsumerKeepsRuntimeButRemovesLaunchers() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService(); service.consumers = ["compatible-gui"]
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(plan, confirming: plan.confirmation)
        let removal = try installer.planUninstall(workspaces: [], externalProjects: [])
        let outcome = try installer.executeUninstall(removal, confirming: removal.confirmation)
        XCTAssertEqual(outcome.sharedGUIConsumers, ["compatible-gui"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cli.path))
        XCTAssertFalse(service.stopped)
    }

    func testUninstallRejectsUnknownInstallationRootFileBeforeStopping() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService()
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let plan = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(plan, confirming: plan.confirmation)
        let note = paths.root.appendingPathComponent("unrelated-note.txt")
        try Data("keep me".utf8).write(to: note)
        XCTAssertThrowsError(try installer.planUninstall(workspaces: [], externalProjects: []))
        XCTAssertFalse(service.stopped)
        XCTAssertEqual(try Data(contentsOf: note), Data("keep me".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.path))
    }

    func testUninstallRejectsUnexpectedEmptyVersionDirectoryBeforeStopping() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base); let service = FakeService()
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: true)
        let artifact = try archive(base, version: "1.0.0")
        let install = try installer.plan(archive: artifact, workspaceSchema: 1, protocolVersion: 1)
        _ = try installer.execute(install, confirming: install.confirmation)
        let extra = paths.versions.appendingPathComponent("1.0.0/unexpected-empty")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        XCTAssertThrowsError(try installer.planUninstall(workspaces: [], externalProjects: []))
        XCTAssertFalse(service.stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            paths.versions.appendingPathComponent("1.0.0/bin/screenpunk").path))
        XCTAssertEqual(try current(paths), "versions/1.0.0")
    }

    func testLaunchdAdapterUsesFixedPerUserCommandsAndExactPlist() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let runner = FakeLaunchctl()
        let controller = paths.machineState.appendingPathComponent("controller")
        let runtime = paths.machineState.appendingPathComponent("runtime")
        let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
            controllerHome: controller, runtimeDirectory: runtime, uid: 501,
            logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
            launchctl: runner)
        let service = paths.current.appendingPathComponent("libexec/screenpunk-service")
        try adapter.register(serviceExecutable: service, plist: paths.launchAgent)
        let data = try Data(contentsOf: paths.launchAgent)
        let value = try XCTUnwrap(PropertyListSerialization.propertyList(from: data,
            options: [], format: nil) as? [String: Any])
        XCTAssertEqual(value["ProgramArguments"] as? [String],
                       [service.path, "--foreground", "--home", controller.path,
                        "--runtime-directory", runtime.path])
        XCTAssertEqual(value["KeepAlive"] as? Bool, false)
        XCTAssertEqual(value["EnvironmentVariables"] as? [String: String],
                       ["HOME": paths.home.path, "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(runner.calls.first, ["bootstrap", "gui/501", paths.launchAgent.path])
        XCTAssertEqual(runner.calls[1], ["kickstart", "-k", "gui/501/com.screenpunk.workbench"])
        try adapter.register(serviceExecutable: service, plist: paths.launchAgent)
        XCTAssertEqual(Array(runner.calls.suffix(3)), [
            ["bootout", "gui/501", paths.launchAgent.path],
            ["bootstrap", "gui/501", paths.launchAgent.path],
            ["kickstart", "-k", "gui/501/com.screenpunk.workbench"]])
        try adapter.start(); try adapter.enable(); try adapter.disable()
        XCTAssertEqual(try adapter.status(), "fake status")
        XCTAssertEqual(runner.calls.last, ["print", "gui/501/com.screenpunk.workbench"])
        _ = try adapter.stopAndUnregister(plist: paths.launchAgent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgent.path))
    }

    func testLaunchdAdapterRejectsModifiedOwnedPlistBeforeUpdateOrStop() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let runner = FakeLaunchctl()
        let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("runtime"), uid: 501,
            logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
            launchctl: runner)
        let service = paths.current.appendingPathComponent("libexec/screenpunk-service")
        try adapter.register(serviceExecutable: service, plist: paths.launchAgent)
        var value = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: paths.launchAgent), options: [], format: nil) as? [String: Any])
        value["Unexpected"] = "foreign"
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: paths.launchAgent)
        let priorCalls = runner.calls.count
        XCTAssertThrowsError(try adapter.register(serviceExecutable: service, plist: paths.launchAgent))
        XCTAssertThrowsError(try adapter.enable())
        XCTAssertThrowsError(try adapter.disable())
        XCTAssertThrowsError(try adapter.stopAndUnregister(plist: paths.launchAgent))
        XCTAssertEqual(runner.calls.count, priorCalls)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.launchAgent.path))
    }

    func testLaunchdAdapterRejectsSymlinkedPlistBeforeUpdateOrStop() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let runner = FakeLaunchctl()
        let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("runtime"), uid: 501,
            logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
            launchctl: runner)
        let service = paths.current.appendingPathComponent("libexec/screenpunk-service")
        try adapter.register(serviceExecutable: service, plist: paths.launchAgent)
        let foreign = base.appendingPathComponent("foreign.plist")
        try FileManager.default.moveItem(at: paths.launchAgent, to: foreign)
        try FileManager.default.createSymbolicLink(at: paths.launchAgent, withDestinationURL: foreign)
        let priorCalls = runner.calls.count
        XCTAssertThrowsError(try adapter.register(serviceExecutable: service, plist: paths.launchAgent))
        XCTAssertThrowsError(try adapter.stopAndUnregister(plist: paths.launchAgent))
        XCTAssertEqual(runner.calls.count, priorCalls)
        XCTAssertEqual(try Data(contentsOf: foreign), try Data(contentsOf: paths.launchAgent))
    }

    func testLaunchdAdapterRejectsSymlinkedLaunchAgentsDirectory() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let library = paths.home.appendingPathComponent("Library")
        let alternate = paths.home.appendingPathComponent("alternate-agents")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("LaunchAgents"),
            withDestinationURL: alternate)
        let runner = FakeLaunchctl()
        let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("runtime"), uid: 501,
            logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
            launchctl: runner)
        let service = paths.current.appendingPathComponent("libexec/screenpunk-service")
        XCTAssertThrowsError(try adapter.register(serviceExecutable: service, plist: paths.launchAgent))
        XCTAssertThrowsError(try adapter.stopAndUnregister(plist: paths.launchAgent))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: alternate.path).isEmpty)
    }

    func testLaunchdAdapterAcceptsOwnedNonWritableSharedReadPermissions() throws {
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let library = paths.home.appendingPathComponent("Library")
        let agents = library.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for path in [paths.home, library, agents] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let runner = FakeLaunchctl()
        let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("runtime"), uid: 501,
            logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
            launchctl: runner)
        try adapter.register(serviceExecutable: paths.current.appendingPathComponent(
            "libexec/screenpunk-service"), plist: paths.launchAgent)
        XCTAssertEqual(runner.calls.map(\.first), ["bootstrap", "kickstart"])
        _ = try adapter.stopAndUnregister(plist: paths.launchAgent)
        XCTAssertEqual(runner.calls.last?.first, "bootout")
    }

    func testLaunchdAdapterRejectsWritableAgentAncestorsAndPlist() throws {
        for unsafePart in ["home", "Library", "LaunchAgents"] {
            let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
            let paths = try home(base)
            let library = paths.home.appendingPathComponent("Library")
            let agents = library.appendingPathComponent("LaunchAgents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let unsafe = unsafePart == "home" ? paths.home :
                unsafePart == "Library" ? library : agents
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
            let runner = FakeLaunchctl()
            let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
                controllerHome: paths.machineState.appendingPathComponent("controller"),
                runtimeDirectory: paths.machineState.appendingPathComponent("runtime"), uid: 501,
                logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
                launchctl: runner)
            let service = paths.current.appendingPathComponent("libexec/screenpunk-service")
            XCTAssertThrowsError(try adapter.register(serviceExecutable: service, plist: paths.launchAgent))
            XCTAssertThrowsError(try adapter.stopAndUnregister(plist: paths.launchAgent))
            XCTAssertTrue(runner.calls.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgent.path))
        }
        let base = try base(); defer { try? FileManager.default.removeItem(at: base) }
        let paths = try home(base)
        let runner = FakeLaunchctl()
        let adapter = LaunchdUserAdapter(observation: FakeObservation(), paths: paths,
            controllerHome: paths.machineState.appendingPathComponent("controller"),
            runtimeDirectory: paths.machineState.appendingPathComponent("runtime"), uid: 501,
            logDirectory: paths.home.appendingPathComponent("Library/Logs/Screenpunk"),
            launchctl: runner)
        let service = paths.current.appendingPathComponent("libexec/screenpunk-service")
        try adapter.register(serviceExecutable: service, plist: paths.launchAgent)
        try FileManager.default.setAttributes([.posixPermissions: 0o666],
            ofItemAtPath: paths.launchAgent.path)
        let priorCalls = runner.calls.count
        XCTAssertThrowsError(try adapter.register(serviceExecutable: service, plist: paths.launchAgent))
        XCTAssertThrowsError(try adapter.stopAndUnregister(plist: paths.launchAgent))
        XCTAssertEqual(runner.calls.count, priorCalls)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.launchAgent.path))
    }
}
