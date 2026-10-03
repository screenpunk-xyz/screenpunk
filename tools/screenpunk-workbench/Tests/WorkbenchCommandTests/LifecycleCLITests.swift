import XCTest
import Foundation
@testable import WorkbenchCommand
import ScreenpunkDistribution
import ScreenpunkController

private final class FixtureLifecycleService: InstallationServiceLifecycle {
    var interrupted = ["fixture-job-7"]
    var registeredVersions: [String] = []
    var stopped = false
    var healthyVersions: Set<String>? = nil
    var consumers: [String] = []
    func drain() throws -> [String] { interrupted }
    func register(serviceExecutable: URL, plist: URL) throws {
        let selector = serviceExecutable.deletingLastPathComponent().deletingLastPathComponent()
        registeredVersions.append(try FileManager.default.destinationOfSymbolicLink(atPath: selector.path))
    }
    func health(version: String) throws -> Bool { healthyVersions?.contains(version) ?? true }
    func stopAndUnregister(plist: URL) throws -> [String] { stopped = true; return interrupted }
    func compatibleGUIConsumers() throws -> [String] { consumers }
}
private final class FixtureInstalledIdentity: InstalledServiceIdentityProbing {
    var matches = true
    var versions: [String] = []
    func runningServiceMatches(version: String) throws -> Bool {
        versions.append(version); return matches
    }
}
private final class FixtureInstalledServiceToggle: WorkbenchInstalledServiceControl {
    var events: [String] = []
    var logPath: URL?
    func enable() throws { events.append("enable") }
    func disable() throws { events.append("disable") }
    func verifiedLogPath() throws -> URL {
        guard let logPath else { throw DistributionError.unavailable }
        events.append("logs")
        return logPath
    }
}

final class LifecycleCLITests: XCTestCase {
    private func root() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp/sp-lifecycle-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return value
    }
    private func archive(_ root: URL, version: String) throws -> URL {
        let payload = root.appendingPathComponent("payload-" + version)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let contents = [
            "bin/screenpunk": "#!/bin/sh\necho screenpunk-\(version)\n",
            "bin/screenpunk-mcp": "#!/bin/sh\necho mcp-\(version)\n",
            "libexec/screenpunk-service": "#!/bin/sh\necho service-\(version)\n",
            "Resources/AuthoringKit/LOCAL-TEST-ONLY.txt": "Synthetic fixture.\n",
            "Resources/help/README.txt": "help\n",
            "Resources/contracts/workspace.json": "{}\n",
            "LICENSES/NOTICE.txt": "fixture notice\n",
            "SBOM.json": "{\"testOnly\":true}\n"
        ]
        for (path, body) in contents {
            let file = payload.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(body.utf8).write(to: file)
            if path.hasPrefix("bin/") || path.hasPrefix("libexec/") {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
        }
        let result = root.appendingPathComponent("archive-" + version)
        _ = try DistributionArchive.assembleLocalTest(payload: payload, output: result,
            version: version)
        return result
    }
    private func fixture(_ root: URL, service: FixtureLifecycleService,
                         allowLocalTest: Bool = true) throws -> (InstallationPaths, ScreenpunkInstaller, WorkbenchLifecycleContext) {
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let paths = InstallationPaths(home: home)
        let installer = ScreenpunkInstaller(paths: paths, service: service, allowLocalTest: allowLocalTest)
        let workspace = root.appendingPathComponent("workspace")
        let external = root.appendingPathComponent("external-project")
        let context = WorkbenchLifecycleContext(installer: installer, inventory: {
            WorkbenchInstallationInventory(workspaceSchema: 1,
                workspaces: [workspace.path], externalProjects: [external.path])
        })
        return (paths, installer, context)
    }
    private func run(_ words: [String], _ context: WorkbenchLifecycleContext) -> Int32 {
        WorkbenchCommand.run(arguments: words, environment: [:], lifecycleContext: context)
    }

    func testInstallUpdateAndUninstallRoutesPreserveDataAndReportJobs() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FixtureLifecycleService()
        let (paths, installer, context) = try fixture(root, service: service)
        let first = try archive(root, version: "1.0.0")
        let firstToken = try installer.plan(archive: first, workspaceSchema: 1,
            protocolVersion: 1).confirmation
        XCTAssertEqual(run(["install", "plan", first.path, "--json"], context), 0)
        XCTAssertEqual(run(["install", "apply", first.path, "wrong"], context), 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
        XCTAssertEqual(run(["install", "apply", first.path, firstToken, "--json"], context), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path),
            "versions/1.0.0")
        let second = try archive(root, version: "1.1.0")
        let secondToken = try installer.plan(archive: second, workspaceSchema: 1,
            protocolVersion: 1).confirmation
        XCTAssertEqual(run(["update", "check", second.path, "--json"], context), 0)
        XCTAssertEqual(run(["update", "install", second.path, secondToken, "--json"], context), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path),
            "versions/1.1.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.versions.appendingPathComponent("1.0.0").path))
        XCTAssertEqual(service.registeredVersions, ["versions/1.0.0", "versions/1.1.0"])
        let uninstall = try installer.planUninstall(workspaces: [root.appendingPathComponent("workspace").path],
            externalProjects: [root.appendingPathComponent("external-project").path])
        XCTAssertEqual(run(["uninstall", "plan", "--json"], context), 0)
        XCTAssertEqual(run(["uninstall", "apply", uninstall.confirmation, "--json"], context), 0)
        XCTAssertTrue(service.stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertEqual(uninstall.purgeMachineState, false)
        XCTAssertEqual(service.interrupted, ["fixture-job-7"])
    }

    func testProductionTrustRejectsLocalTestArchiveBeforeAnyMutation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FixtureLifecycleService()
        let (paths, _, context) = try fixture(root, service: service, allowLocalTest: false)
        let artifact = try archive(root, version: "1.0.0")
        XCTAssertEqual(run(["install", "plan", artifact.path], context), 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertTrue(service.registeredVersions.isEmpty)
    }

    func testUpdateRollbackUsesRetainedVerifiedArchiveAndExactToken() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = FixtureLifecycleService()
        let (paths, installer, context) = try fixture(root, service: service)
        let first = try archive(root, version: "1.0.0")
        let second = try archive(root, version: "1.1.0")
        let firstToken = try installer.plan(archive: first, workspaceSchema: 1,
            protocolVersion: 1).confirmation
        XCTAssertEqual(run(["install", "apply", first.path, firstToken], context), 0)
        let secondToken = try installer.plan(archive: second, workspaceSchema: 1,
            protocolVersion: 1).confirmation
        XCTAssertEqual(run(["update", "install", second.path, secondToken], context), 0)
        let rollback = try installer.plan(archive: first, workspaceSchema: 1,
            protocolVersion: 1, rollback: true)
        XCTAssertEqual(run(["update", "rollback", "plan", first.path], context), 0)
        XCTAssertEqual(run(["update", "rollback", "apply", first.path, "wrong"], context), 8)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path),
            "versions/1.1.0")
        XCTAssertEqual(run(["update", "rollback", "apply", first.path,
            rollback.confirmation], context), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path),
            "versions/1.0.0")
        XCTAssertEqual(service.registeredVersions,
            ["versions/1.0.0", "versions/1.1.0", "versions/1.0.0"])
    }

    func testServiceEnableDisableRoutesOnlyThroughInstalledServiceControl() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, installer, original) = try fixture(root, service: FixtureLifecycleService())
        XCTAssertEqual(run(["service", "enable", "--json"], original), 8)
        let control = FixtureInstalledServiceToggle()
        let context = WorkbenchLifecycleContext(installer: installer,
            inventory: original.inventory, serviceControl: control)
        XCTAssertEqual(run(["service", "enable", "--json"], context), 0)
        XCTAssertEqual(run(["service", "disable", "--json"], context), 0)
        XCTAssertEqual(control.events, ["enable", "disable"])
    }

    func testServiceLogsRedactsUnknownContentAndRequiresInstalledControl() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, installer, original) = try fixture(root, service: FixtureLifecycleService())
        XCTAssertEqual(run(["service", "logs", "--json"], original), 8)
        let control = FixtureInstalledServiceToggle()
        let log = root.appendingPathComponent("service.log")
        control.logPath = log
        try Data("Screenpunk workbench broker ready; Ctrl-C stops this foreground service.\nsecret=do-not-print\nService stopped.\n".utf8).write(to: log)
        let context = WorkbenchLifecycleContext(installer: installer,
            inventory: original.inventory, serviceControl: control)
        let sanitized = try WorkbenchLifecycleCLI.sanitizedLog(at: log)
        XCTAssertEqual(sanitized.events, ["broker_ready", "service_stopped"])
        XCTAssertEqual(sanitized.redactedLineCount, 1)
        XCTAssertFalse(sanitized.events.joined().contains("do-not-print"))
        XCTAssertEqual(run(["service", "logs", "--json"], context), 0)
        XCTAssertEqual(control.events, ["logs"])
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL:
            root.appendingPathComponent("other.log"))
        XCTAssertThrowsError(try WorkbenchLifecycleCLI.sanitizedLog(at: log))
    }

    func testUpdateRejectsCleanInstallAndRelativeArchive() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (paths, _, context) = try fixture(root, service: FixtureLifecycleService())
        let artifact = try archive(root, version: "1.0.0")
        XCTAssertEqual(run(["update", "check", artifact.path], context), 8)
        XCTAssertEqual(run(["install", "plan", "relative/archive"], context), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
    }

    func testReviewTextEscapesControlsAndRefusesTruncation() throws {
        XCTAssertEqual(try WorkbenchLifecycleCLI.exactReviewText("/private/tmp/a\u{202E}b\n"),
            "/private/tmp/a\\u{202E}b\\u{000A}")
        XCTAssertThrowsError(try WorkbenchLifecycleCLI.exactReviewText(String(repeating: "a", count: 4097)))
    }

    func testLifecycleObservationBindsBrokerHomeAndInstalledIdentityBeforeDrainOrStop() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-lr-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let paths = InstallationPaths(home: home)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: paths.current.path,
            withDestinationPath: "versions/1.0.0")
        let runtime = try WorkbenchBrokerEnvironment(runtimeDirectory:
            paths.machineState.appendingPathComponent("Runtime"))
        let actualHome = paths.machineState.appendingPathComponent("Actual")
        let expectedHome = paths.machineState.appendingPathComponent("Expected")
        let host = try WorkbenchServiceHost(broker: runtime, home: actualHome,
            documents: CLIWorkspaceDocuments(environment: [:]),
            ownerCheck: {}, nativeFactory: { _ in nil })
        defer { host.stop() }
        let identity = FixtureInstalledIdentity()
        let mismatched = WorkbenchBrokerLifecycleObservation(paths: paths, broker: runtime,
            controllerHome: expectedHome, identity: identity)
        XCTAssertThrowsError(try mismatched.drainAndReportInterruptedJobs())
        XCTAssertThrowsError(try mismatched.stopAndReportInterruptedJobs())
        XCTAssertThrowsError(try mismatched.compatibleGUIConsumers())
        XCTAssertTrue(identity.versions.isEmpty, "mismatched broker home must fail before identity probe")
        let observer = WorkbenchBrokerClient(environment: runtime)
        try observer.connect(); defer { observer.close() }
        XCTAssertEqual(try observer.health().status, "ready", "foreign broker must remain running")
        let matching = WorkbenchBrokerLifecycleObservation(paths: paths, broker: runtime,
            controllerHome: actualHome, identity: identity)
        XCTAssertTrue(try matching.healthy(expectedVersion: "1.0.0"))
        XCTAssertEqual(identity.versions, ["1.0.0"])
        identity.matches = false
        XCTAssertFalse(try matching.healthy(expectedVersion: "1.0.0"))
        XCTAssertThrowsError(try matching.drainAndReportInterruptedJobs())
        XCTAssertThrowsError(try matching.stopAndReportInterruptedJobs())
        XCTAssertEqual(try observer.health().status, "ready")
    }
}
