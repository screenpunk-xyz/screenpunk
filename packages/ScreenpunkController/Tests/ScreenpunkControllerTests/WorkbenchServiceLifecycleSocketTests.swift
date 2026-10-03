#if os(macOS)
import XCTest
@testable import ScreenpunkController

final class WorkbenchServiceLifecycleSocketTests: XCTestCase {
    func testRemovalSocketRejectsActiveJobWithoutCancellationAndDisconnectReleasesReservation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = WorkbenchServiceLifecycle()
        let token = try lifecycle.beginJob(id: "active-build", cancel: { XCTFail("Removal must not cancel") })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment, lifecycleCoordinator: lifecycle)
        try server.start(); defer { server.stop() }
        let busy = WorkbenchBrokerClient(environment: environment)
        try busy.connect(); defer { busy.close() }
        XCTAssertThrowsError(try busy.prepareServiceRemoval()) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .serviceBusy)
        }
        XCTAssertEqual(lifecycle.snapshot().state, .busy)
        XCTAssertEqual(lifecycle.snapshot().activeJobIDs, ["active-build"])
        lifecycle.finishJob(id: "active-build", token: token)
        let owner = WorkbenchBrokerClient(environment: environment)
        try owner.connect()
        let prepared = try owner.prepareServiceRemoval()
        XCTAssertEqual(prepared.state, "drained")
        XCTAssertTrue(prepared.interruptedJobIDs.isEmpty)
        XCTAssertFalse(prepared.guiConsumersKnown)
        XCTAssertEqual(lifecycle.snapshot().state, .draining)
        let other = WorkbenchBrokerClient(environment: environment)
        try other.connect(); defer { other.close() }
        XCTAssertThrowsError(try other.drainService())
        owner.close()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, lifecycle.snapshot().state == .draining {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(lifecycle.snapshot().state, .healthy)
    }

    func testDrainReportsOnlyRegisteredInterruptedJobs() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = WorkbenchServiceLifecycle()
        var token: UUID?
        token = try lifecycle.beginJob(id: "build-17", cancel: {
            lifecycle.finishJob(id: "build-17", token: token!, completion: .interrupted)
        })
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment, lifecycleCoordinator: lifecycle)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect(); defer { client.close() }
        XCTAssertEqual(try client.serviceLifecycle().state, "busy")
        XCTAssertEqual(try client.serviceLifecycle().activeJobIDs, ["build-17"])
        let result = try client.drainService()
        XCTAssertEqual(result.interruptedJobIDs, ["build-17"])
        XCTAssertEqual(result.activeJobIDs, [])
    }

    func testAuthenticatedLifecycleDrainClosesWorkButRetainsHealth() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        let server = WorkbenchBrokerServer(environment: environment)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment)
        try client.connect()
        XCTAssertEqual(try client.serviceLifecycle().state, "healthy")
        XCTAssertFalse(try client.serviceLifecycle().guiConsumersKnown)
        let drained = try client.drainService()
        XCTAssertEqual(drained.state, "drained")
        XCTAssertEqual(drained.interruptedJobIDs, [])
        XCTAssertEqual(try client.serviceLifecycle().state, "draining")
        XCTAssertThrowsError(try client.listDevices()) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .serviceBusy)
        }
        client.close()
        let health = WorkbenchBrokerClient(environment: environment)
        try health.connect(); defer { health.close() }
        XCTAssertEqual(try health.health().status, "ready")
    }
}
#endif
