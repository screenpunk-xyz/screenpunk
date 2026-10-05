import XCTest
import Foundation
import Darwin
import ScreenpunkController
import ScreenpunkDistribution
@testable import WorkbenchCommand

private final class StatusFixtureBroker: WorkbenchStatusBrokerReading {
    var calls: [String] = []
    var offline = false
    var home = "/fixture/controller"
    var jobs = ["fixture-job"]
    func connect() throws { calls.append("connect"); if offline { throw WorkbenchIPCError(.unavailable) } }
    func close() { calls.append("close") }
    private func decode<T: Decodable>(_ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func health() throws -> WorkbenchBrokerSnapshot {
        calls.append("health")
        return try decode(["apiVersion": "1.0", "instanceId": "fixture-instance", "status": "ready",
            "supportedMethods": ["system.health", "workspace.status", "device.list"],
            "workspaceState": "selected", "build": "available", "devices": "read-only",
            "screenshots": "unavailable", "controllerHomePath": home])
    }
    func serviceLifecycle() throws -> WorkbenchServiceLifecycleResult {
        calls.append("lifecycle")
        return try decode(["schemaVersion": 1, "kind": "status", "state": jobs.isEmpty ? "healthy" : "busy",
            "activeJobIDs": jobs, "interruptedJobIDs": [], "authenticatedConnections": 1,
            "guiConsumersKnown": false, "guiConsumers": []])
    }
    func workspaceStatus() throws -> WorkbenchWorkspaceStatus {
        calls.append("workspace")
        return try decode(["state": "selected", "workspaceId": "fixture-workspace", "path": "/fixture/workspace",
            "generation": 6, "selectionGeneration": 1, "coverageComplete": true,
            "externalProjectCount": 0, "historyAuthority": "historical-only"])
    }
    func listDevices() throws -> [WorkbenchDeviceRead] {
        calls.append("devices")
        let value: WorkbenchDeviceRead = try decode(["deviceId": "fixture-device", "name": "iPhone\u{1b}[2J",
            "ownerMatchesCurrent": true, "reachability": "not-probed", "cachedReachability": "reachable",
            "lastSeenAt": "2026-10-05T12:00:00Z"])
        return [value]
    }
}

final class WorkbenchStatusCLITests: XCTestCase {
    private func context(_ broker: StatusFixtureBroker, installed: String = "1.0.7",
                         running: String = "1.0.7") -> WorkbenchStatusContext {
        .init(installedRelease: { .init(evidence: "verified", version: installed, packagePath: "/fixture/package") },
              process: { .init(evidence: "verified", state: "running", releaseVersion: running,
                               pid: 123, uid: UInt32(geteuid()), executablePath: "/fixture/service") },
              broker: { broker }, expectedHome: "/fixture/controller", toolCatalogCount: { 72 },
              uptime: { 100 }, timeout: 3)
    }
    private func captured(_ body: () -> Int32) throws -> (Int32, String) {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw WorkbenchIPCError(.unavailable) }
        XCTAssertEqual(dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO), STDOUT_FILENO)
        let result = body()
        XCTAssertEqual(dup2(saved, STDOUT_FILENO), STDOUT_FILENO)
        close(saved)
        try pipe.fileHandleForWriting.close()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        return (result, String(decoding: bytes, as: UTF8.self))
    }

    func testHealthySummaryUsesReleaseEvidenceJobsAndCachedDevicesWithoutMutations() throws {
        let broker = StatusFixtureBroker()
        let report = context(broker).collect()
        XCTAssertEqual(report.installedRelease.version, "1.0.7")
        XCTAssertEqual(report.service.versionComparison, "match")
        XCTAssertEqual(report.service.activeJobCount, 1)
        XCTAssertEqual(report.workspace.path, "/fixture/workspace")
        XCTAssertEqual(report.devices.pairedCount, 1)
        XCTAssertEqual(report.devices.items.first?.cachedReachability, "reachable")
        XCTAssertEqual(report.devices.items.first?.connectionEvidence, "not_assessed")
        XCTAssertEqual(report.mcp.state, "broker_ready")
        XCTAssertEqual(report.mcp.clientRegistration, "not_assessed")
        XCTAssertEqual(broker.calls, ["connect", "health", "lifecycle", "workspace", "devices", "close"])
        XCTAssertTrue(report.human.contains("Installed release: 1.0.7 (verified)"))
        XCTAssertTrue(report.human.contains("last observed reachable (cached)"))
        XCTAssertFalse(report.human.contains("\u{1b}"))
        XCTAssertTrue(report.human.contains("Client registration not assessed"))
    }

    func testOfflineBrokerRetainsInstalledAndOwnedProcessFactsWithoutInventingEmptyJobsDevices() {
        let broker = StatusFixtureBroker(); broker.offline = true
        let report = context(broker).collect()
        XCTAssertEqual(report.installedRelease.version, "1.0.7")
        XCTAssertEqual(report.service.process.releaseVersion, "1.0.7")
        XCTAssertEqual(report.service.health, "unavailable")
        XCTAssertNil(report.service.activeJobCount)
        XCTAssertNil(report.devices.pairedCount)
        XCTAssertEqual(report.workspace.evidence, "unavailable")
        XCTAssertEqual(report.mcp.state, "broker_unavailable")
        XCTAssertEqual(broker.calls, ["connect", "close"])
    }

    func testVersionMismatchIsExplicitInHumanAndStructuredOutput() throws {
        let broker = StatusFixtureBroker()
        let report = context(broker, installed: "1.0.7", running: "1.0.5").collect()
        XCTAssertEqual(report.service.versionComparison, "mismatch")
        XCTAssertEqual(report.mcp.state, "service_version_mismatch")
        XCTAssertTrue(report.human.contains("VERSION MISMATCH"))
        let (exit, output) = try captured {
            WorkbenchCommand.run(arguments: ["status", "--json"], environment: [:],
                statusContext: context(broker, installed: "1.0.7", running: "1.0.5"))
        }
        XCTAssertEqual(exit, 0)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let service = try XCTUnwrap(result["service"] as? [String: Any])
        XCTAssertEqual(service["versionComparison"] as? String, "mismatch")
        XCTAssertFalse(output.contains("0.2.0-m1"))
    }

    func testWrongControllerHomeDoesNotReadWorkspaceDevicesOrClaimMCPReadiness() {
        let broker = StatusFixtureBroker(); broker.home = "/different/controller"
        let report = context(broker).collect()
        XCTAssertEqual(report.service.health, "controller_home_mismatch")
        XCTAssertEqual(report.mcp.state, "broker_unavailable")
        XCTAssertEqual(broker.calls, ["connect", "health", "close"])
    }

    func testOlderBrokerDeviceFieldsDecodeWithoutInventingCurrentConnection() throws {
        let data = Data(#"{"deviceId":"old-phone","name":"iPhone","ownerMatchesCurrent":true,"reachability":"not-probed"}"#.utf8)
        let device = try JSONDecoder().decode(WorkbenchDeviceRead.self, from: data)
        XCTAssertNil(device.cachedReachability)
        XCTAssertNil(device.lastSeenAt)
        XCTAssertEqual(device.reachability, "not-probed")
    }

    func testExpiredBudgetDoesNotConnectOrReadMoreEvidence() {
        var now: TimeInterval = 100
        let broker = StatusFixtureBroker()
        let value = WorkbenchStatusContext(installedRelease: {
            now = 104; return .init(evidence: "verified", version: "1.0.7", packagePath: "/fixture/package")
        }, process: { XCTFail("Expired budget"); throw WorkbenchIPCError(.unavailable) },
           broker: { XCTFail("Expired budget"); return broker }, expectedHome: "/fixture/controller",
           toolCatalogCount: { 72 }, uptime: { now }, timeout: 3)
        let report = value.collect()
        XCTAssertEqual(report.service.process.state, "timeout")
        XCTAssertTrue(broker.calls.isEmpty)
    }

    func testRealStatusDispatchDoesNotCreateAbsentRuntimeWorkspaceOrStartService() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-status-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("controller")
        let runtime = root.appendingPathComponent("runtime")
        let (exit, output) = try captured {
            WorkbenchCommand.run(arguments: ["--json", "--no-input", "--timeout", "1",
                "--home", home.path, "--runtime-directory", runtime.path, "status"], environment: [:])
        }
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(output.contains("broker_unavailable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func launchd(_ program: String, paths: InstallationPaths) -> String {
        """
        gui/\(geteuid())/com.screenpunk.workbench = {
            path = \(paths.launchAgent.path)
            program = \(program)
            arguments = {
                \(program)
                --foreground
                --home
                \(paths.machineState.appendingPathComponent("Controller").path)
                --runtime-directory
                \(paths.machineState.appendingPathComponent("Runtime").path)
            }
            pid = 123
        }
        """
    }
    func testOwnedProcessVersionRequiresExactLaunchdArgumentsUIDAndStableNativeImage() throws {
        let paths = InstallationPaths(home: URL(fileURLWithPath: "/fixture/home"))
        let program = "/opt/homebrew/Caskroom/screenpunk-cli/1.0.5/Screenpunk CLI 1.0.5/libexec/screenpunk-service"
        let initial = WorkbenchStatusNativeProcess.Identity(pid: 123, uid: UInt32(geteuid()), path: program,
                                                          started: 10, image: Data(repeating: 1, count: 16))
        var reads = 0
        let parsed = try WorkbenchStatusNativeProcess.parse(text: launchd(program, paths: paths), paths: paths,
            readProcess: { _ in reads += 1; return initial }, authenticate: { _ in "1.0.5" })
        XCTAssertEqual(parsed.releaseVersion, "1.0.5")
        XCTAssertEqual(parsed.evidence, "verified")
        XCTAssertEqual(reads, 2)
        var replacement = initial; replacement.started = 11
        reads = 0
        XCTAssertThrowsError(try WorkbenchStatusNativeProcess.parse(text: launchd(program, paths: paths), paths: paths,
            readProcess: { _ in reads += 1; return reads == 1 ? initial : replacement }, authenticate: { _ in "1.0.5" }))
        var foreign = initial; foreign.uid += 1
        XCTAssertThrowsError(try WorkbenchStatusNativeProcess.parse(text: launchd(program, paths: paths), paths: paths,
            readProcess: { _ in foreign }, authenticate: { _ in XCTFail("Foreign process"); return "1.0.5" }))
        XCTAssertThrowsError(try WorkbenchStatusNativeProcess.parse(text: launchd(program, paths: paths)
            .replacingOccurrences(of: "--foreground", with: "--other"), paths: paths,
            readProcess: { _ in XCTFail("Wrong arguments"); return initial }, authenticate: { _ in "1.0.5" }))
    }
}
