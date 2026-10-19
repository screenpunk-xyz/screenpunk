import XCTest
import Darwin
@_spi(NativeInstallation) @testable import ScreenpunkApple

final class DeviceUnifiedRootAuthorityTests: XCTestCase {
    func testPinnedCommonRootRejectsDirectoryReplacementAndSymlink() throws {
        let anchorURL = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: anchorURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: anchorURL) }
        let root = anchorURL.appendingPathComponent("xyz.screenpunk.unified-inventory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let anchor = open(anchorURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(anchor, 0); XCTAssertGreaterThanOrEqual(descriptor, 0)
        var anchorStat = stat(), rootStat = stat()
        XCTAssertEqual(fstat(anchor, &anchorStat), 0); XCTAssertEqual(fstat(descriptor, &rootStat), 0)
        let reservation = DeviceManagementAuthority.UnifiedRootReservation(root: root, rootID: UUID(),
            anchor: anchor, descriptor: descriptor, anchorIdentity: anchorStat, identity: rootStat)
        try reservation.validate()
        let retained = anchorURL.appendingPathComponent("retained-original")
        try FileManager.default.moveItem(at: root, to: retained)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try reservation.validate())
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: retained)
        XCTAssertThrowsError(try reservation.validate())
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: retained, to: root)
        try reservation.validate()
    }
}
