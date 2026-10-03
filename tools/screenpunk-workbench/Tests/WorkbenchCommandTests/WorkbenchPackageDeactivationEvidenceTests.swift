import XCTest
import Foundation
import Darwin
import ScreenpunkController
@testable import ScreenpunkDistribution
@testable import WorkbenchCommand

private final class DeactivationIdentity: InstalledServiceIdentityProbing {
    var matches = true
    var versions: [String] = []
    func runningServiceMatches(version: String) throws -> Bool {
        versions.append(version); return matches
    }
}
private struct DeactivationCommit: PackageCommitChecking {
    func prepareInstall(stateDirectory: Int32) throws {}
    func assertReady(stateDirectory: Int32) throws {}
}
private struct DeactivationGUIVerifier: WorkbenchGUIConsumerVerifier {
    func verifyConnectedPeer(socket: Int32) -> Bool { true }
}
private final class DeactivationLaunchctl: ArgumentProcessRunning {
    let paths: InstallationPaths
    let executable: URL
    var state: OwnedLaunchdJobState = .absent
    var mutations: [[String]] = []
    var onBootout: () -> Void = {}
    init(paths: InstallationPaths, executable: URL) {
        self.paths = paths; self.executable = executable
    }
    func run(executable command: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval, maximumOutputBytes: Int) throws -> BoundedProcessResult {
        XCTAssertEqual(command.path, "/bin/launchctl")
        XCTAssertEqual(environment["HOME"], paths.home.path)
        XCTAssertEqual(timeout, 5)
        let target = "gui/\(geteuid())/com.screenpunk.workbench"
        if arguments.first == "print" {
            if state == .absent {
                return .init(exitStatus: 113, stdout: Data(),
                    stderr: Data("Could not find service \"com.screenpunk.workbench\" in domain for user gui: \(geteuid())".utf8))
            }
            let process = state == .running ? "pid = 12345" : "state = not running"
            let output = """
            \(target) = {
                path = \(paths.launchAgent.path)
                program = \(executable.path)
                arguments = {
                    \(executable.path)
                    --foreground
                    --home
                    \(paths.machineState.appendingPathComponent("Controller").path)
                    --runtime-directory
                    \(paths.machineState.appendingPathComponent("Runtime").path)
                }
                \(process)
            }
            """
            return .init(exitStatus: 0, stdout: Data(output.utf8), stderr: Data())
        }
        mutations.append(arguments)
        switch arguments.first {
        case "bootstrap": state = .registeredWithoutProcess
        case "kickstart": state = .running
        case "bootout": onBootout(); state = .absent
        default: XCTFail("Unexpected launchctl mutation")
        }
        return .init(exitStatus: 0, stdout: Data(), stderr: Data())
    }
}

final class WorkbenchPackageDeactivationEvidenceTests: XCTestCase {
    private final class Fixture {
        let base: URL
        let root: URL
        let paths: InstallationPaths
        let broker: WorkbenchBrokerEnvironment
        let host: WorkbenchServiceHost
        let runner: DeactivationLaunchctl
        let launchctl: BoundedUserLaunchctl
        let identity = DeactivationIdentity()
        let catalog: URL
        let packageBytes: Data
        let shutdown = DispatchSemaphore(value: 0)

        init(guiVerifier: WorkbenchGUIConsumerVerifier? = nil) throws {
            // Keep the real fixed per-user suffix inside the Unix socket limit.
            base = URL(fileURLWithPath: "/private/tmp/gd-" + UUID().uuidString.prefix(12))
            let home = base.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            paths = InstallationPaths(home: home)
            let payload = base.appendingPathComponent("payload")
            for member in ["bin/screenpunk", "bin/screenpunk-mcp", "libexec/screenpunk-service",
                           "SBOM.json", "Resources/AuthoringKit/test.txt", "Resources/help/help.txt",
                           "Resources/contracts/test.json", "LICENSES/test.txt"] {
                let file = payload.appendingPathComponent(member)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data("fixture".utf8).write(to: file)
                if member.hasPrefix("bin/") || member.hasPrefix("libexec/") {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                }
            }
            root = base.appendingPathComponent("package")
            _ = try DistributionArchive.assembleLocalTest(payload: payload, output: root, version: "1.0.2")
            packageBytes = try Data(contentsOf: root.appendingPathComponent(DistributionArchive.manifestFile))
            broker = try WorkbenchBrokerEnvironment(runtimeDirectory: paths.machineState.appendingPathComponent("Runtime"))
            let signal = shutdown
            host = try WorkbenchServiceHost(broker: broker,
                home: paths.machineState.appendingPathComponent("Controller"),
                documents: CLIWorkspaceDocuments(environment: [
                    "SCREENPUNK_DOCUMENTS_DIRECTORY": base.appendingPathComponent("Documents").path]),
                ownerCheck: {}, nativeFactory: { _ in nil }, guiVerifier: guiVerifier,
                onShutdown: { signal.signal() })
            runner = DeactivationLaunchctl(paths: paths,
                executable: root.appendingPathComponent("libexec/screenpunk-service"))
            launchctl = BoundedUserLaunchctl(runner: runner, paths: paths)
            let heldHost = host
            runner.onBootout = { heldHost.stop() }
            catalog = paths.machineState.appendingPathComponent("Toolchains/Catalog/retained-fixture.json")
            try FileManager.default.createDirectory(at: catalog.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("retained-catalog".utf8).write(to: catalog)
            let initial = adapter(assertGUIAbsent: {})
            try initial.register(serviceExecutable: root.appendingPathComponent("libexec/screenpunk-service"),
                                 plist: paths.launchAgent)
            runner.mutations.removeAll()
        }
        deinit { host.stop(); try? FileManager.default.removeItem(at: base) }
        func client() throws -> WorkbenchBrokerClient {
            let client = WorkbenchBrokerClient(environment: broker); try client.connect(); return client
        }
        func adapter(assertGUIAbsent: @escaping () throws -> Void) -> LaunchdUserAdapter {
            let observation = WorkbenchBrokerLifecycleObservation(paths: paths, broker: broker,
                controllerHome: paths.machineState.appendingPathComponent("Controller"),
                identity: identity, packageVersion: "1.0.2", assertGUIAbsent: assertGUIAbsent)
            return LaunchdUserAdapter(observation: observation, paths: paths,
                controllerHome: paths.machineState.appendingPathComponent("Controller"),
                runtimeDirectory: broker.runtimeDirectory,
                logDirectory: paths.machineState.appendingPathComponent("Logs"),
                launchctl: launchctl, serviceExecutable: root.appendingPathComponent("libexec/screenpunk-service"))
        }
        func installation(assertGUIAbsent: @escaping () throws -> Void) -> PackageManagedInstallation {
            PackageManagedInstallation(root: root, paths: paths, service: adapter(assertGUIAbsent: assertGUIAbsent),
                releaseTrust: RejectUnconfiguredReleaseTrust(), allowLocalTest: true,
                prepare: { _, _ in XCTFail("Deactivation must not prepare/import any kit") },
                assertUnmanagedServiceAbsent: { XCTFail("Running service must use verified shutdown"); return nil },
                assertStoppedRemovalSafe: { XCTFail("Running service must use its reservation and native evidence") },
                commit: DeactivationCommit())
        }
        func assertRetained(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: catalog), Data("retained-catalog".utf8), file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(DistributionArchive.manifestFile)),
                packageBytes, file: file, line: line)
        }
    }

    func testCLIOnlyUnknownWireEvidenceDeactivatesOnlyWithTwoFreshNativeAbsenceChecks() throws {
        let f = try Fixture()
        let client = try f.client(); defer { client.close() }
        let status = try client.serviceLifecycle()
        XCTAssertFalse(status.guiConsumersKnown)
        XCTAssertTrue(status.guiConsumers.isEmpty)
        var absenceChecks = 0
        let probe = WorkbenchGUIAbsenceProbe(uid: 503, snapshot: {
            [.init(pid: 20, uid: 503, path: "/fixture/cli", started: 100, image: Data(repeating: 1, count: 16))]
        }, codeIdentity: { _ in .other }, applicationPresent: { false })
        XCTAssertEqual(try f.installation(assertGUIAbsent: {
            absenceChecks += 1; try probe.assertAbsent()
        }).deactivate(), [])
        XCTAssertEqual(absenceChecks, 2, "Fresh evidence is required before and after idle reservation")
        XCTAssertEqual(f.shutdown.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(f.runner.mutations.map(\.first), ["bootout"])
        XCTAssertEqual(f.runner.state, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
        XCTAssertEqual(f.identity.versions, ["1.0.2"])
        try f.assertRetained()
    }

    func testUnknownOrPresentNativeGUIEvidenceRetainsRunningBrokerAndPlist() throws {
        for verdict in [WorkbenchGUIAbsenceProbe.CodeIdentity.unknown, .approvedGUI] {
            let f = try Fixture()
            let probe = WorkbenchGUIAbsenceProbe(uid: 503, snapshot: {
                [.init(pid: 20, uid: 503, path: "/fixture/process", started: 100, image: Data(repeating: 1, count: 16))]
            }, codeIdentity: { _ in verdict }, applicationPresent: { false })
            XCTAssertThrowsError(try f.installation(assertGUIAbsent: { try probe.assertAbsent() }).deactivate())
            XCTAssertTrue(f.runner.mutations.isEmpty)
            XCTAssertEqual(f.runner.state, .running)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
            let client = try f.client(); defer { client.close() }
            XCTAssertEqual(try client.serviceLifecycle().state, "healthy")
            XCTAssertFalse(try client.serviceLifecycle().guiConsumersKnown)
            XCTAssertEqual(f.shutdown.wait(timeout: .now()), .timedOut)
            try f.assertRetained()
        }
    }

    func testAbsenceLostAfterReservationBlocksStopAndReopensAdmission() throws {
        let f = try Fixture()
        var checks = 0
        XCTAssertThrowsError(try f.installation(assertGUIAbsent: {
            checks += 1
            if checks == 2 { throw DistributionError.unavailable }
        }).deactivate())
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(f.runner.mutations.isEmpty)
        XCTAssertEqual(f.runner.state, .running)
        let client = try f.client(); defer { client.close() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, try client.serviceLifecycle().state == "draining" {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(try client.serviceLifecycle().state, "healthy")
        XCTAssertNoThrow(try client.listDevices(), "Rejected removal must reopen ordinary job admission")
        XCTAssertEqual(try client.health().status, "ready")
        XCTAssertEqual(f.shutdown.wait(timeout: .now()), .timedOut)
        try f.assertRetained()
        // A retry uses a new connection and may remove the same retained package.
        XCTAssertEqual(try f.installation(assertGUIAbsent: {}).deactivate(), [])
        XCTAssertEqual(f.runner.state, .absent)
    }

    func testWrongProcessIdentityFailsBeforeNativeAbsenceAndNeverStops() throws {
        let f = try Fixture()
        f.identity.matches = false
        XCTAssertThrowsError(try f.installation(assertGUIAbsent: {
            XCTFail("Identity must be checked before native GUI evidence")
        }).deactivate())
        XCTAssertTrue(f.runner.mutations.isEmpty)
        XCTAssertEqual(f.runner.state, .running)
        XCTAssertEqual(f.shutdown.wait(timeout: .now()), .timedOut)
        try f.assertRetained()
    }

    func testRegisteredGUIBlocksEvenIfInjectedNativeInventoryClaimsEmpty() throws {
        let f = try Fixture(guiVerifier: DeactivationGUIVerifier())
        let gui = try f.client(); defer { gui.close() }
        _ = try gui.registerGUIConsumer()
        XCTAssertFalse(try gui.serviceLifecycle().guiConsumers.isEmpty)
        XCTAssertThrowsError(try f.installation(assertGUIAbsent: {
            XCTFail("Known registered consumer cannot be overridden by another proof")
        }).deactivate())
        XCTAssertTrue(f.runner.mutations.isEmpty)
        XCTAssertEqual(f.runner.state, .running)
        XCTAssertEqual(f.shutdown.wait(timeout: .now()), .timedOut)
        try f.assertRetained()
    }
}
