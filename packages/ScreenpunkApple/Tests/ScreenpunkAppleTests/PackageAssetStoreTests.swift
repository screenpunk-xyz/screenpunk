import XCTest
@testable import ScreenpunkApple
import ScreenpunkCore

final class PackageAssetStoreTests: XCTestCase {
    func testBundledOfflineFixtureServesCustomScheme() throws {
        let store = try PackageAssetStore.bundledOfflineFixture()
        let html = try store.asset(forSchemeURL: "screenpunk://package/index.html")
        let body = String(data: html.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("SCREENPUNK_OFFLINE_EXAMPLE_V1"))
        XCTAssertEqual(html.mime, "text/html")
        XCTAssertNoThrow(try store.asset(forSchemeURL: "screenpunk://package/app.js"))
        XCTAssertNoThrow(try store.asset(forSchemeURL: "screenpunk://package/styles.css"))
        XCTAssertEqual(store.assets["manifest.json"]?.mime, "application/json")
    }

    func testDeniesTraversalAndRemoteURLs() throws {
        let store = try PackageAssetStore.bundledOfflineFixture()
        XCTAssertThrowsError(try store.asset(forSchemeURL: "https://evil.example/x"))
        XCTAssertThrowsError(try store.asset(forSchemeURL: "screenpunk://package/../Secrets"))
        XCTAssertThrowsError(try store.asset(forSchemeURL: "file:///etc/passwd"))
    }

    func testOfflineOverlayHiddenWithoutConnections() {
        XCTAssertFalse(NativeChromeHost.shouldShowOffline(requiredFailedOrStale: true, connectionCount: 0))
        XCTAssertTrue(NativeChromeHost.shouldShowOffline(requiredFailedOrStale: true, connectionCount: 1))
        XCTAssertEqual(NativeChromeHost.unlinkActionCount, 1)
        XCTAssertFalse(NativeChromeHost.ringUsesSystemRed)
        XCTAssertEqual(NativeChromeHost.lightDangerHex, "#A52C42")
        XCTAssertEqual(AppleHostPlaceholder.customScheme, "screenpunk")
    }
}
