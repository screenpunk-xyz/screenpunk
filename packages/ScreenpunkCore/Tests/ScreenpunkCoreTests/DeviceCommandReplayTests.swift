import XCTest
@testable import ScreenpunkCore
final class DeviceCommandReplayTests: XCTestCase {
    func testKnownReceiptLookupDoesNotAdvanceIntentFenceAndRejectsDifferentContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = DeviceCommandIntentCoordinator(root: root)
        let key = UUID().uuidString, digest = String(repeating: "a", count: 64)
        XCTAssertFalse(try owner.knownDeployment(key: key, digest: digest))
        try owner.acceptLocalDeployment(key: key, digest: digest)
        let checkpoint = try owner.checkpoint()
        let restored = DeviceCommandIntentCoordinator(root: root)
        XCTAssertTrue(try restored.knownDeployment(key: key, digest: digest))
        try restored.requireUnchanged(checkpoint)
        XCTAssertThrowsError(try restored.knownDeployment(key: key, digest: String(repeating: "b", count: 64)))
        try restored.requireUnchanged(checkpoint)
    }
}
