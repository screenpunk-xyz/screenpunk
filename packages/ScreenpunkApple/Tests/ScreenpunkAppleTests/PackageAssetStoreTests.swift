import XCTest
@testable import ScreenpunkApple
import ScreenpunkCore

final class PackageAssetStoreTests: XCTestCase {
    func testLoadsThroughTemporaryDirectoryAliasAndRejectsEscapingSymlink() throws {
        let root = URL(fileURLWithPath: "/tmp/sp-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<h1>screen</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        XCTAssertEqual(try PackageAssetStore.load(directory: root).assets["index.html"]?.data, Data("<h1>screen</h1>".utf8))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        // A symlink is either skipped as non-regular or rejected; it must never expose its target.
        if let loaded = try? PackageAssetStore.load(directory: root) { XCTAssertNil(loaded.assets["escape.txt"]) }
    }

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

    func testUnlinkClearsPackageAndReturnsUnpaired() throws {
        var session = try HostSession.offlineFixture()
        XCTAssertEqual(session.phase, .dashboard)
        XCTAssertNotNil(session.store)
        session.unlink()
        XCTAssertEqual(session.phase, .unpaired)
        XCTAssertNil(session.store)
        XCTAssertEqual(UnpairedHostCopy.headline, "Ready to pair")
        XCTAssertEqual(BrandIdentity.defaultLockup, "stacked")
    }
}
