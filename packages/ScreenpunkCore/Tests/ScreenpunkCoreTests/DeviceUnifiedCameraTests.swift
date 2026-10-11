import XCTest
@testable import ScreenpunkCore

final class DeviceUnifiedCameraTests: XCTestCase {
    func testCameraCapabilityCannotRetargetOriginOrPath() throws {
        XCTAssertEqual(try UnifiedCameraMediaURL.resolve(path: "/api/hls/approved_1/master_playlist.m3u8", origin: "https://home.example:8123").absoluteString,
            "https://home.example:8123/api/hls/approved_1/master_playlist.m3u8")
        for path in ["https://evil.example/api/hls/x/master_playlist.m3u8", "//evil.example/api/hls/x/master_playlist.m3u8", "/api/hls/../master_playlist.m3u8", "/api/hls/x/master_playlist.m3u8?token=other", "/api/hls/x/master_playlist.m3u8\n", "/api/states"] {
            XCTAssertThrowsError(try UnifiedCameraMediaURL.resolve(path: path, origin: "https://home.example"), path)
        }
    }
}
