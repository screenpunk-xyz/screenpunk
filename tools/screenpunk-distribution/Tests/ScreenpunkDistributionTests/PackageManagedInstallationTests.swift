import XCTest
import Foundation
@testable import ScreenpunkDistribution

private final class PackageLaunchctl: LaunchctlRunning, OwnedLaunchdJobProbing {
    var state: OwnedLaunchdJobState = .absent
    var calls: [[String]] = []
    var failBootstrap = false
    var failBootout = false
    var failKickstart = false
    func run(_ arguments: [String]) throws -> String {
        calls.append(arguments)
        switch arguments.first {
        case "bootstrap":
            if failBootstrap { throw DistributionError.unavailable }
            state = .registeredWithoutProcess
        case "kickstart":
            if failKickstart { throw DistributionError.unavailable }
            state = .running
        case "bootout":
            if failBootout { throw DistributionError.unavailable }
            guard state != .absent else { throw DistributionError.unavailable }
            state = .absent
        default: break
        }
        return ""
    }
    func ownedJobState(expectedExecutable: URL, expectedPlist: URL,
                       expectedArguments: [String]) throws -> OwnedLaunchdJobState { state }
}
private final class PackageObservation: WorkbenchServiceObservation {
    var healthy = true
    var failStop = false
    var stops = 0
    func drainAndReportInterruptedJobs() throws -> [String] { [] }
    func healthy(expectedVersion: String) throws -> Bool { healthy }
    func stopAndReportInterruptedJobs() throws -> [String] {
        if failStop { throw DistributionError.unavailable }
        stops += 1; return ["fixture-job"]
    }
    func compatibleGUIConsumers() throws -> [String] { [] }
}
private struct FixtureCommit: PackageCommitChecking {
    func prepareInstall(stateDirectory: Int32) throws {}
    func assertReady(stateDirectory: Int32) throws {}
}

final class PackageManagedInstallationTests: XCTestCase {
    private final class Fixture {
        let base: URL
        let root: URL
        let paths: InstallationPaths
        let launchctl = PackageLaunchctl()
        let observation = PackageObservation()
        var preparations = 0
        var preparationError: (any Error)?
        var unmanaged = false
        let adapter: LaunchdUserAdapter
        init() throws {
            base = URL(fileURLWithPath: "/private/tmp/sp-package-" + UUID().uuidString)
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
            _ = try DistributionArchive.assembleLocalTest(payload: payload, output: root, version: "1.0.1")
            adapter = LaunchdUserAdapter(observation: observation, paths: paths,
                controllerHome: paths.machineState.appendingPathComponent("Controller"),
                runtimeDirectory: paths.machineState.appendingPathComponent("Runtime"),
                logDirectory: paths.machineState.appendingPathComponent("Logs"),
                launchctl: launchctl, serviceExecutable: root.appendingPathComponent("libexec/screenpunk-service"))
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func installation() -> PackageManagedInstallation {
            PackageManagedInstallation(root: root, paths: paths, service: adapter,
                releaseTrust: RejectUnconfiguredReleaseTrust(), allowLocalTest: true,
                prepare: { [unowned self] _, _ in
                    self.preparations += 1
                    if let error = self.preparationError { throw error }
                },
                assertUnmanagedServiceAbsent: { [unowned self] in
                    if self.unmanaged { throw DistributionError.conflict }; return nil
                }, commit: FixtureCommit())
        }
    }

    func testFirstUseDirectlyRegistersPackageWithoutSoftwareCopyOrLaunchers() throws {
        let f = try Fixture()
        try f.installation().start()
        XCTAssertEqual(f.launchctl.calls.map(\.first), ["bootstrap", "kickstart"])
        XCTAssertEqual(f.preparations, 1)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: f.paths.launchAgent),
            options: [], format: nil) as? [String: Any])
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.first,
            f.root.appendingPathComponent("libexec/screenpunk-service").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.cli.path))
        try f.installation().start()
        XCTAssertEqual(f.preparations, 1)
        XCTAssertEqual(f.launchctl.calls.count, 2)
    }

    func testPreparationFailureKeepsCauseAndDoesNotActivateOrUnregisterService() throws {
        let f = try Fixture()
        let cause = NSError(domain: "test.offline-preparation", code: 42)
        f.preparationError = cause
        XCTAssertThrowsError(try f.installation().start()) { error in
            let failure = error as? PackagePreparationFailure
            XCTAssertEqual(failure?.underlying as? NSError, cause)
        }
        XCTAssertTrue(f.launchctl.calls.isEmpty)
        XCTAssertEqual(f.observation.stops, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.path))
        f.preparationError = nil
        try f.installation().start()
        XCTAssertEqual(f.launchctl.calls.map(\.first), ["bootstrap", "kickstart"])
    }

    func testIdleExitReconnectKickstartsOwnedJobThenRemovalStopsIt() throws {
        let f = try Fixture(); let installation = f.installation()
        try installation.start()
        f.launchctl.state = .registeredWithoutProcess
        try installation.start()
        XCTAssertEqual(f.launchctl.calls.map(\.first), ["bootstrap", "kickstart", "kickstart"])
        XCTAssertEqual(try installation.deactivate(), ["fixture-job"])
        XCTAssertEqual(f.observation.stops, 1)
        XCTAssertEqual(f.launchctl.state, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.machineState.path))
    }

    func testAbsentJobWithOwnedPlistCanResumeWithoutDuplicateBootout() throws {
        let f = try Fixture(); try f.installation().start()
        f.launchctl.state = .absent
        try f.installation().start()
        XCTAssertEqual(f.launchctl.calls.map(\.first), ["bootstrap", "kickstart", "bootstrap", "kickstart"])
    }

    func testNeverActivatedUninstallIsIdempotentAndPreservesState() throws {
        let f = try Fixture()
        XCTAssertEqual(try f.installation().deactivate(), [])
        XCTAssertEqual(try f.installation().deactivate(), [])
        XCTAssertTrue(f.launchctl.calls.isEmpty)
        XCTAssertEqual(f.preparations, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.path))
    }

    func testDeactivatedRootCannotRestartBetweenHookReturnAndBrewPurge() throws {
        let f = try Fixture(); let installation = f.installation()
        try installation.start()
        _ = try installation.deactivate()
        let calls = f.launchctl.calls.count
        XCTAssertThrowsError(try installation.start())
        XCTAssertEqual(f.launchctl.calls.count, calls)
        try installation.rearm()
        XCTAssertEqual(f.launchctl.calls.count, calls) // install hook starts no process
        try installation.start()
        XCTAssertEqual(f.launchctl.state, .running)
    }

    func testRearmFailsBeforeClearingFenceWhenJobStateIsUnknown() throws {
        let f = try Fixture(); _ = try f.installation().deactivate()
        f.launchctl.state = .unknown
        XCTAssertThrowsError(try f.installation().rearm())
        f.launchctl.state = .absent
        XCTAssertThrowsError(try f.installation().start())
    }

    func testFailedFencePublicationLeavesNoPartialMarkerAndCanRetry() throws {
        let f = try Fixture(); let installation = f.installation()
        try installation.start()
        installation.beforeFencePublication = { throw DistributionError.insufficientSpace }
        XCTAssertThrowsError(try installation.deactivate())
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.paths.machineState.path)
            .contains { $0.hasPrefix(".package-removal-") || $0.hasPrefix(".package-fence-") })
        installation.beforeFencePublication = {}
        XCTAssertEqual(try installation.deactivate(), [])
        XCTAssertThrowsError(try installation.start())
        try installation.rearm()
        try installation.start()
    }

    func testFailedBootstrapRecoversAndRetainsOriginalCause() throws {
        let f = try Fixture(); f.launchctl.failBootstrap = true
        XCTAssertThrowsError(try f.installation().start()) { error in
            let failure = error as? PackageActivationFailure
            XCTAssertEqual(failure?.activation as? DistributionError, .unavailable)
            XCTAssertNil(failure?.cleanup)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
        f.launchctl.failBootstrap = false
        try f.installation().start()
    }

    func testFailedKickstartAndFailedCleanupKeepResourcesAndBothCauses() throws {
        let f = try Fixture(); f.launchctl.failKickstart = true; f.launchctl.failBootout = true
        XCTAssertThrowsError(try f.installation().start()) { error in
            let failure = error as? PackageActivationFailure
            XCTAssertEqual(failure?.activation as? DistributionError, .unavailable)
            XCTAssertEqual(failure?.cleanup as? DistributionError, .unavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.path))
        f.launchctl.failKickstart = false; f.launchctl.failBootout = false
        try f.installation().start()
    }

    func testUnreachableLiveBrokerAndUnknownJobFailClosed() throws {
        let f = try Fixture(); try f.installation().start()
        f.observation.failStop = true
        XCTAssertThrowsError(try f.installation().deactivate())
        XCTAssertEqual(f.launchctl.state, .running)
        f.launchctl.state = .unknown
        XCTAssertThrowsError(try f.installation().deactivate())
        XCTAssertThrowsError(try f.installation().start())
        XCTAssertFalse(f.launchctl.calls.contains { $0.first == "bootout" })
    }

    func testDetachedBrokerBlocksStoppedJobRemovalAndStartup() throws {
        let f = try Fixture(); try f.installation().start()
        f.launchctl.state = .registeredWithoutProcess; f.unmanaged = true
        XCTAssertThrowsError(try f.installation().deactivate())
        XCTAssertThrowsError(try f.installation().start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.launchAgent.path))
        XCTAssertFalse(f.launchctl.calls.contains { $0.first == "bootout" })
    }

    func testLoadedJobWithMissingDiskPlistBlocksSoftwareRemoval() throws {
        let f = try Fixture(); try f.installation().start()
        try FileManager.default.removeItem(at: f.paths.launchAgent)
        XCTAssertThrowsError(try f.installation().deactivate())
        XCTAssertThrowsError(try f.installation().start())
        XCTAssertEqual(f.launchctl.state, .running)
        XCTAssertEqual(f.observation.stops, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.path))
    }

    func testPackageServiceEnableDisableVerifyCaskrootPlist() throws {
        let f = try Fixture(); try f.installation().start()
        try f.adapter.disable(); try f.adapter.enable()
        XCTAssertEqual(f.launchctl.calls.suffix(2).map(\.first), ["disable", "enable"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.current.path))
    }

    func testLegacySoftwareAndTamperedPackageRejectBeforeServiceMutation() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.paths.root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try f.installation().start())
        XCTAssertThrowsError(try f.installation().deactivate())
        try FileManager.default.removeItem(at: f.paths.root)
        try Data("tampered".utf8).write(to: f.root.appendingPathComponent("bin/screenpunk"))
        XCTAssertThrowsError(try f.installation().start())
        XCTAssertTrue(f.launchctl.calls.isEmpty)
    }

    func testSymlinkedStateParentRejectsBeforeServiceMutation() throws {
        let f = try Fixture()
        let other = f.base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.paths.home.appendingPathComponent("Library"), withDestinationURL: other)
        XCTAssertThrowsError(try f.installation().start())
        XCTAssertTrue(f.launchctl.calls.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }
}
