import XCTest
import Foundation
@testable import ScreenpunkController
#if os(macOS)
final class MacBrokerRecoveryTests: XCTestCase {
    func testMigrationResponseBoundsAreRestrictedToInventoryPaths() throws {
        func data(_ key: String, _ count: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["result": ["migrationPlan": [key: Array(repeating: "revision", count: count)]]])
        }
        XCTAssertThrowsError(try WorkbenchWireJSON.object(data("packageRevisions", 129)))
        XCTAssertNoThrow(try WorkbenchWireJSON.object(data("packageRevisions", 129), allowMigrationPlan: true))
        XCTAssertThrowsError(try WorkbenchWireJSON.object(data("excludedClasses", 129), allowMigrationPlan: true))
        XCTAssertThrowsError(try WorkbenchWireJSON.object(data("packageRevisions", 10_001), allowMigrationPlan: true))
    }
    func testPreviewChunksKeepLargeStringsScopedAndBounded() throws {
        func frame(_ bytes: Int, key: String = "chunk") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["result": [key: ["bytes": Data(repeating: 255, count: bytes).base64EncodedString()]]])
        }
        XCTAssertThrowsError(try WorkbenchWireJSON.object(frame(64 * 1024)))
        XCTAssertNoThrow(try WorkbenchWireJSON.object(frame(64 * 1024), allowWorkspacePackageChunk: true))
        XCTAssertThrowsError(try WorkbenchWireJSON.object(frame(64 * 1024 + 1), allowWorkspacePackageChunk: true))
        XCTAssertThrowsError(try WorkbenchWireJSON.object(frame(64 * 1024, key: "unrelated"), allowWorkspacePackageChunk: true))
    }
    func testReconnectAfterClosedConnectionAllowsNextRead() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-mac-reconnect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"), limits: .init(timeout: 0.3))
        let server = WorkbenchBrokerServer(environment: environment)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: environment, reconnectClosedConnections: true)
        try client.connect(); defer { client.close() }
        XCTAssertFalse(try client.reconnectIfPeerClosed())
        // The broker expires the idle socket; the next UI action must open a
        // fresh authenticated connection before it sends its request.
        Thread.sleep(forTimeInterval: 0.6)
        // The read itself reconnects under its request lock, without a separate preflight.
        XCTAssertEqual(try client.health().status, "ready")
        XCTAssertFalse(try client.reconnectIfPeerClosed())
        client.close()
        XCTAssertThrowsError(try client.health(), "An explicit close must not reopen the session")
        let review = WorkbenchBrokerClient(environment: environment, credentialScope: .localReview,
                                           reconnectClosedConnections: true)
        try review.connect(); defer { review.close() }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertThrowsError(try review.health(), "Consent-bound review sessions must not reconnect automatically")
    }
}
#endif
