import XCTest
@testable import ScreenpunkApple
final class AuthoringAssetsTests: XCTestCase {
    func testBundledFontAndImageMIMEs() {
        XCTAssertEqual(PackageAssetStore.mime(for: "assets/type.woff2"), "font/woff2")
        XCTAssertEqual(PackageAssetStore.mime(for: "assets/type.woff"), "font/woff")
        XCTAssertEqual(PackageAssetStore.mime(for: "assets/photo.jpg"), "image/jpeg")
        XCTAssertEqual(PackageAssetStore.mime(for: "assets/chunk.js"), "text/javascript")
    }
}
