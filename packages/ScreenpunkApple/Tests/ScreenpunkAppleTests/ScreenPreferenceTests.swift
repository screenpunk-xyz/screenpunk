import XCTest
import WebKit
import ScreenpunkCore
@testable import ScreenpunkApple

final class ScreenPreferenceTests: XCTestCase {
    @MainActor
    func testRelaunchIsolationRemovalAndUnlinkInvalidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ScreenPreferenceStore(root: root)
        let lease = try first.generation()
        try first.set(dashboard: "calendar", key: "preferences.v1", value: ["timezone": "America/Detroit", "order": ["work", "home"]], generation: lease)
        let relaunched = ScreenPreferenceStore(root: root)
        let restored = try XCTUnwrap(try relaunched.get(dashboard: "calendar", key: "preferences.v1", generation: lease) as? [String: Any])
        XCTAssertEqual(restored["timezone"] as? String, "America/Detroit")
        XCTAssertTrue(try relaunched.get(dashboard: "different-screen", key: "preferences.v1", generation: lease) is NSNull)
        try relaunched.remove(dashboard: "calendar", key: "preferences.v1", generation: lease)
        XCTAssertTrue(try first.get(dashboard: "calendar", key: "preferences.v1", generation: lease) is NSNull)
        try first.set(dashboard: "calendar", key: "preferences.v1", value: "saved", generation: lease)
        try relaunched.erase()
        XCTAssertThrowsError(try first.set(dashboard: "calendar", key: "preferences.v1", value: "late write", generation: lease)) { XCTAssertEqual($0 as? ConnectionFailure, .permissionRequired) }
        let nextLease = try first.generation()
        XCTAssertNotEqual(lease, nextLease)
        XCTAssertTrue(try first.get(dashboard: "calendar", key: "preferences.v1", generation: nextLease) is NSNull)
    }

    @MainActor
    func testBoundedWritesAreAtomicAndCorruptionDoesNotOverwriteData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenPreferenceStore(root: root), lease = try store.generation()
        try store.set(dashboard: "screen", key: "settings", value: "original", generation: lease)
        XCTAssertThrowsError(try store.set(dashboard: "screen", key: "settings", value: String(repeating: "x", count: ScreenPreferenceStore.valueLimit), generation: lease))
        XCTAssertEqual(try store.get(dashboard: "screen", key: "settings", generation: lease) as? String, "original")
        XCTAssertThrowsError(try store.set(dashboard: "screen", key: "bad\nkey", value: true, generation: lease))
        XCTAssertThrowsError(try store.set(dashboard: "screen", key: "bad", value: Double.nan, generation: lease))
        for index in 0..<127 { try store.set(dashboard: "screen", key: "k\(index)", value: index, generation: lease) }
        XCTAssertThrowsError(try store.set(dashboard: "screen", key: "overflow", value: 1, generation: lease))
        XCTAssertTrue(try store.get(dashboard: "screen", key: "overflow", generation: lease) is NSNull)
        let file = root.appendingPathComponent("preferences-v1.json")
        let broken = Data("broken storage".utf8); try broken.write(to: file)
        XCTAssertThrowsError(try store.set(dashboard: "screen", key: "settings", value: "overwrite", generation: lease))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        try store.erase() // Explicit native reset can recover a corrupt archive.
        XCTAssertTrue(try store.get(dashboard: "screen", key: "settings", generation: store.generation()) is NSNull)
    }

    @MainActor
    func testAggregateLimitsAndScalarRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenPreferenceStore(root: root), lease = try store.generation()
        for (key, value) in [("bool", true as Any), ("number", 1.5 as Any), ("null", NSNull() as Any)] {
            try store.set(dashboard: "scalars", key: key, value: value, generation: lease)
        }
        XCTAssertEqual(try store.get(dashboard: "scalars", key: "bool", generation: lease) as? Bool, true)
        XCTAssertEqual(try store.get(dashboard: "scalars", key: "number", generation: lease) as? Double, 1.5)
        let large = String(repeating: "x", count: 16_000)
        for index in 0..<8 { try store.set(dashboard: "large", key: "k\(index)", value: large, generation: lease) }
        XCTAssertThrowsError(try store.set(dashboard: "large", key: "overflow", value: large, generation: lease))
        XCTAssertTrue(try store.get(dashboard: "large", key: "overflow", generation: lease) is NSNull)
    }

    #if os(macOS)
    @MainActor
    func testBundledSDKPersistsAcrossRevisionAndReadOnlyPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = ScreenPreferenceStore(root: root)
        func makeView(revision: String, readOnly: Bool, dashboard: String = "prefs-test") async throws -> (WKWebView, HomeAssistantPreviewBridge) {
            let manifest = DashboardManifest(schemaVersion: 1, dashboardId: dashboard, name: "Preference test", revision: revision, entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "test", width: 640, height: 360, scale: 1, orientation: "landscape"), connections: [], files: [])
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            let bridge = try HomeAssistantPreviewBridge(configuration: configuration, connections: .init(), revision: revision, manifest: manifest, preferenceStore: preferences, stateReadOnly: readOnly)
            let assets = PackageAssetStore(assets: ["index.html": .init(path: "index.html", data: Data("<!doctype html><title>Preference test</title>".utf8), mime: "text/html")])
            configuration.setURLSchemeHandler(PackageSchemeHandler(store: assets), forURLScheme: "screenpunk")
            let view = WKWebView(frame: .zero, configuration: configuration); bridge.attach(to: view)
            view.load(URLRequest(url: URL(string: "screenpunk://package/index.html")!))
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("typeof screenpunk !== 'undefined' && !!screenpunk.state")) as? Bool == true { return (view, bridge) }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw ConnectionFailure.timeout
        }
        let (one, bridgeOne) = try await makeView(revision: "1", readOnly: false)
        let written = try await one.callAsyncJavaScript("await screenpunk.state.set('calendar.preferences.v1', {schemaVersion:1,timezone:'America/Detroit',color:'#aabbcc'}); return (await screenpunk.state.get('calendar.preferences.v1')).timezone;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(written as? String, "America/Detroit")
        let (two, bridgeTwo) = try await makeView(revision: "2", readOnly: true)
        let restored = try await two.callAsyncJavaScript("return (await screenpunk.state.get('calendar.preferences.v1')).color;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(restored as? String, "#aabbcc")
        let denied = try await two.callAsyncJavaScript("try { await screenpunk.state.remove('calendar.preferences.v1'); return 'unexpected'; } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? String, "permission_required")
        let (other, bridgeOther) = try await makeView(revision: "1", readOnly: false, dashboard: "other-screen")
        let isolated = try await other.callAsyncJavaScript("return (await screenpunk.state.get('calendar.preferences.v1')) === null;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(isolated as? Bool, true)
        let removed = try await one.callAsyncJavaScript("await screenpunk.state.remove('calendar.preferences.v1'); return (await screenpunk.state.get('calendar.preferences.v1')) === null;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(removed as? Bool, true)
        withExtendedLifetime([bridgeOne, bridgeTwo, bridgeOther]) {}
    }
    #endif
}
