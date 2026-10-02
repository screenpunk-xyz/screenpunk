import XCTest
import Foundation
@testable import ScreenpunkDistribution

private final class RecordingProcess: ArgumentProcessRunning {
    var result = BoundedProcessResult(exitStatus: 0, stdout: Data(), stderr: Data())
    var calls: [(String, [String], [String: String], TimeInterval, Int)] = []
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval, maximumOutputBytes: Int) throws -> BoundedProcessResult {
        calls.append((executable.path, arguments, environment, timeout, maximumOutputBytes))
        return result
    }
}
private struct StaticStatus: WorkbenchServiceStatusProbing {
    let value: ObservedWorkbenchService
    func status() throws -> ObservedWorkbenchService { value }
}
private struct StaticIdentity: InstalledServiceIdentityProbing {
    let matches: Bool
    func runningServiceMatches(version: String) throws -> Bool { matches }
}

final class VerifiedUserLifecycleSupportTests: XCTestCase {
    private func root() throws -> (URL, InstallationPaths) {
        let root = URL(fileURLWithPath: "/private/tmp/sp-launchd-support-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return (root, InstallationPaths(home: home))
    }

    func testBoundedLaunchctlUsesFixedArgumentsAndEnvironment() throws {
        let (root, paths) = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let process = RecordingProcess()
        process.result = .init(exitStatus: 0, stdout: Data("ready".utf8), stderr: Data())
        let launchctl = BoundedUserLaunchctl(runner: process, uid: 501, paths: paths)
        XCTAssertEqual(try launchctl.run(["bootstrap", "gui/501", paths.launchAgent.path]), "ready")
        XCTAssertEqual(process.calls.last?.0, "/bin/launchctl")
        XCTAssertEqual(process.calls.last?.2, ["HOME": paths.home.path, "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(process.calls.last?.3, 5)
        XCTAssertEqual(process.calls.last?.4, 65_536)
        XCTAssertThrowsError(try launchctl.run(["bootstrap", "system", paths.launchAgent.path]))
        XCTAssertThrowsError(try launchctl.run(["print", "gui/502/com.screenpunk.workbench"]))
        XCTAssertEqual(process.calls.count, 1)
    }

    func testCLIStatusUsesAbsoluteInstalledCommandAndClosedStatusEnvelope() throws {
        let (root, paths) = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let process = RecordingProcess()
        let controller = paths.home.appendingPathComponent("Library/Application Support/Screenpunk/controller")
        let runtime = paths.home.appendingPathComponent("Library/Application Support/Screenpunk/runtime")
        let probe = WorkbenchCLIStatusProbe(runner: process, paths: paths,
            controllerHome: controller, runtimeDirectory: runtime)
        process.result = .init(exitStatus: 0, stdout: try JSONSerialization.data(withJSONObject: [
            "apiVersion": "1.0", "ok": true,
            "result": ["apiVersion": "1.0", "status": "ready",
                       "controllerHomePath": controller.path]
        ]), stderr: Data())
        XCTAssertEqual(try probe.status(), .ready(apiVersion: "1.0", controllerHomePath: controller.path))
        XCTAssertEqual(process.calls.last?.0, paths.cli.path)
        XCTAssertEqual(process.calls.last?.1, ["--json", "--no-input", "--timeout", "2",
            "--home", controller.path, "--runtime-directory", runtime.path, "service", "status"])
        process.result = .init(exitStatus: 9, stdout: try JSONSerialization.data(withJSONObject: [
            "apiVersion": "1.0", "ok": false, "error": ["code": "unavailable"]
        ]), stderr: Data())
        XCTAssertEqual(try probe.status(), .unknown)
        process.result = .init(exitStatus: 9, stdout: try JSONSerialization.data(withJSONObject: [
            "apiVersion": "1.0", "ok": false, "error": ["code": "unauthorizedPeer"]
        ]), stderr: Data())
        XCTAssertThrowsError(try probe.status())
    }

    func testJobProbeRequiresLoadedPathProgramAndArguments() throws {
        let (root, paths) = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let process = RecordingProcess()
        let launchctl = BoundedUserLaunchctl(runner: process, uid: 501, paths: paths)
        let executable = paths.current.appendingPathComponent("libexec/screenpunk-service")
        let arguments = [executable.path, "--foreground"]
        func probe() throws -> OwnedLaunchdJobState {
            try launchctl.ownedJobState(expectedExecutable: executable, expectedPlist: paths.launchAgent,
                                       expectedArguments: arguments)
        }
        let prefix = "gui/501/com.screenpunk.workbench = {\n\tpath = \(paths.launchAgent.path)\n\tprogram = \(executable.path)\n"
        let content = prefix + "\targuments = {\n\t\t\(executable.path)\n\t\t--foreground\n\t}\n\tstate = not running\n}\n"
        process.result = .init(exitStatus: 0, stdout: Data(content.utf8), stderr: Data())
        XCTAssertEqual(try probe(), .registeredWithoutProcess)
        process.result = .init(exitStatus: 0, stdout: Data(content.replacingOccurrences(
            of: "program = \(executable.path)", with: "program = /other/service").utf8), stderr: Data())
        XCTAssertEqual(try probe(), .unknown)
        process.result = .init(exitStatus: 0, stdout: Data(content.replacingOccurrences(
            of: "--foreground", with: "--different").utf8), stderr: Data())
        XCTAssertEqual(try probe(), .unknown)
        process.result = .init(exitStatus: 113, stdout: Data(), stderr: Data(
            "Bad request.\nCould not find service \"com.screenpunk.workbench\" in domain for user gui: 501\n".utf8))
        XCTAssertEqual(try probe(), .absent)
        process.result = .init(exitStatus: 113, stdout: Data(), stderr: Data("Permission denied".utf8))
        XCTAssertEqual(try probe(), .unknown)
    }

    func testObservationDoesNotInventDrainOrConsumerEvidence() throws {
        let (root, paths) = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = paths.home.appendingPathComponent("controller")
        let absent = ConservativeWorkbenchObservation(statusProbe: StaticStatus(value: .absent),
            identityProbe: StaticIdentity(matches: false), controllerHome: controller)
        XCTAssertEqual(try absent.drainAndReportInterruptedJobs(), [])
        XCTAssertEqual(try absent.stopAndReportInterruptedJobs(), [])
        XCTAssertFalse(try absent.healthy(expectedVersion: "1.0.0"))
        XCTAssertThrowsError(try absent.compatibleGUIConsumers())
        let running = ConservativeWorkbenchObservation(statusProbe: StaticStatus(
            value: .ready(apiVersion: "1.0", controllerHomePath: controller.path)),
            identityProbe: StaticIdentity(matches: true), controllerHome: controller)
        XCTAssertTrue(try running.healthy(expectedVersion: "1.0.0"))
        XCTAssertThrowsError(try running.drainAndReportInterruptedJobs())
        XCTAssertThrowsError(try running.stopAndReportInterruptedJobs())
        let unreachable = ConservativeWorkbenchObservation(statusProbe: StaticStatus(value: .unknown),
            identityProbe: StaticIdentity(matches: true), controllerHome: controller)
        XCTAssertThrowsError(try unreachable.drainAndReportInterruptedJobs())
        XCTAssertThrowsError(try unreachable.stopAndReportInterruptedJobs())
    }
}
