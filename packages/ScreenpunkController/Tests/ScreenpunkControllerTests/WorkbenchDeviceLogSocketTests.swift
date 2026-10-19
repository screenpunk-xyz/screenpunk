#if os(macOS)
import XCTest
import Foundation
@testable import ScreenpunkController

final class WorkbenchDeviceLogSocketTests: XCTestCase {
    func testPrivateBrokerObservedLogIsBoundedRedactedAndPersistsAcrossOwnerRestart() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-device-log-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = root.appendingPathComponent("machine")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let journalPath = machine.appendingPathComponent("device-events.sqlite").path
        let journal = try WorkbenchDeviceEventJournal(path: journalPath)
        for _ in 0..<130 {
            try journal.append(deviceId: "device-a", kind: "screenSetObserved", outcome: "observed")
        }
        try journal.append(deviceId: "device-b", kind: "settingsUpdated", outcome: "acknowledged")
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let controller = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: machine.appendingPathComponent("devices.json"), rendererFactory: { nil })
        let domain = WorkbenchBrokerDomain(controller: controller,
            machineAuthorityPath: machine.appendingPathComponent("authority.json").path,
            mutationGate: {})
        func readOnce() throws -> WorkbenchDeviceLogRead {
            let server = WorkbenchBrokerServer(environment: environment, domain: domain)
            try server.start(); defer { server.stop() }
            let client = WorkbenchBrokerClient(environment: environment)
            try client.connect(); defer { client.close() }
            let value = try client.deviceLogs(deviceId: "device-a")
            XCTAssertEqual(try client.deviceLogs(deviceId: "device-b").events.count, 1)
            return value
        }
        let first = try readOnce()
        XCTAssertEqual(first.events.count, 128)
        XCTAssertTrue(first.truncated)
        XCTAssertFalse(first.complete)
        XCTAssertEqual(first.scope, "broker-observed-device-events")
        XCTAssertTrue(first.events.allSatisfy { $0.deviceId == "device-a" &&
            $0.kind == "screenSetObserved" && $0.outcome == "observed" })
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any]
        XCTAssertEqual(Set(encoded?.keys.map { $0 } ?? []), ["schemaVersion", "deviceId", "scope",
            "complete", "truncated", "events"])
        XCTAssertEqual(try readOnce(), first)
    }
}
#endif
