import XCTest
@testable import ScreenpunkApple
import ScreenpunkCore
import WebKit
import MapKit
#if os(macOS)
import AppKit
#endif

final class MapPreviewTests: XCTestCase {
    @MainActor
    func testDeclarationRequiresExplicitSupportedOperations() {
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: "maps-test", name: "Maps", revision: "1", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "test", width: 640, height: 360, scale: 1, orientation: "landscape"), connections: [], files: [])
        XCTAssertFalse(AppleMapPreview.isDeclared(in: manifest))
        manifest.connections = [.init(alias: "appleMaps", required: false)]
        XCTAssertFalse(AppleMapPreview.isDeclared(in: manifest))
        manifest.connections[0].operations = [.init(name: "snapshot", kind: "http")]
        XCTAssertTrue(AppleMapPreview.isDeclared(in: manifest))
        manifest.connections[0].operations?.append(.init(name: "search", kind: "http"))
        XCTAssertFalse(AppleMapPreview.isDeclared(in: manifest))
        manifest.connections[0].operations = ["present", "update", "close"].map { .init(name: $0, kind: "http") }
        XCTAssertTrue(AppleMapPreview.isDeclared(in: manifest, operation: "present"))
        XCTAssertFalse(AppleMapPreview.isDeclared(in: manifest, operation: "snapshot"))
    }

    @MainActor
    func testLiveAppleSnapshotWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SCREENPUNK_TEST_LIVE_MAPS"] == "1" else { throw XCTSkip("Opt-in Apple service smoke test") }
        let renderer = AppleMapPreview()
        let result = try await renderer.render(MapPreviewRequest(["address": "5 Avenue Anatole France, 75007 Paris, France"]))
        XCTAssertEqual(result.1, "ready")
        let data = try XCTUnwrap(result.0)
        let resources = PublicRasterResources()
        let url = try resources.put(.init(state: "fresh", body: data, mime: "image/png", status: 200))
        XCTAssertEqual(try resources.asset(url: url).data, data)
        resources.release(url: url)
        XCTAssertThrowsError(try resources.asset(url: url))
        try data.write(to: URL(fileURLWithPath: "/tmp/screenpunk-map-smoke.png"))
    }

    #if os(macOS)
    @MainActor
    func testHiddenBridgePreservesPermissionErrorThroughBundledSDK() async throws {
        let manifest = DashboardManifest(schemaVersion: 1, dashboardId: "map-approval-" + UUID().uuidString, name: "Map test", revision: "1", entrypoint: "index.html", sdkVersion: "1", target: .init(profileId: "test", width: 640, height: 360, scale: 1, orientation: "landscape"), connections: [.init(alias: "appleMaps", required: false, operations: [.init(name: "snapshot", kind: "http")])], files: [])
        let configuration = WKWebViewConfiguration()
        let bridge = try HomeAssistantPreviewBridge(configuration: configuration, connections: .init(), revision: "1", manifest: manifest)
        let store = PackageAssetStore(assets: ["index.html": .init(path: "index.html", data: Data("<!doctype html><title>Map test</title>".utf8), mime: "text/html")])
        configuration.setURLSchemeHandler(PackageSchemeHandler(store: store, rasterResources: bridge.rasterResources), forURLScheme: "screenpunk")
        let view = WKWebView(frame: .zero, configuration: configuration)
        bridge.attach(to: view)
        view.load(URLRequest(url: URL(string: "screenpunk://package/index.html")!))
        var loaded = false
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof screenpunk !== 'undefined' && !!screenpunk.connections")) as? Bool == true { loaded = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(loaded)
        let code = try await view.callAsyncJavaScript("try { await screenpunk.connections.read('appleMaps', 'snapshot', {address:'5 Avenue Anatole France, Paris, France'}); return 'unexpected'; } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(code as? String, "permission_required")
        let invalid = try await view.callAsyncJavaScript("try { await screenpunk.connections.read('appleMaps', 'snapshot', {address:'Paris', width:'999999'}); return 'unexpected'; } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(invalid as? String, "validation_failed")
    }
    #endif

    func testNativeBoundsRejectInvalidAndHideClippedSurfaces() throws {
        func rect(_ x: Int = 10, width: Int = 300, visible: Int = 1) -> String {
            "{\"x\":\(x),\"y\":20,\"width\":\(width),\"height\":200,\"viewportWidth\":800,\"radius\":16,\"visible\":\(visible)}"
        }
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(try NativeMapBounds(rect()).nativeFrame(in: bounds), CGRect(x: 5, y: 10, width: 150, height: 100))
        XCTAssertNil(try NativeMapBounds(rect(-1)).nativeFrame(in: bounds))
        XCTAssertNil(try NativeMapBounds(rect(700)).nativeFrame(in: bounds))
        XCTAssertNil(try NativeMapBounds(rect(visible: 0)).nativeFrame(in: bounds))
        XCTAssertThrowsError(try NativeMapBounds(rect(width: 2049)))
        XCTAssertThrowsError(try NativeMapBounds(rect(visible: 2)))
        XCTAssertThrowsError(try NativeMapBounds("{}"))
    }

    @MainActor
    func testInteractiveProtocolRejectsURLsCoordinatesAndUnknownFields() throws {
        let rect = "{\"x\":0,\"y\":0,\"width\":640,\"height\":360,\"viewportWidth\":800,\"radius\":16,\"visible\":1}"
        XCTAssertNoThrow(try InteractiveMapController.validate(operation: "present", parameters: ["id": "map-1", "address": "Paris", "rect": rect]))
        XCTAssertNoThrow(try InteractiveMapController.validate(operation: "close", parameters: ["id": "map-1"]))
        XCTAssertThrowsError(try InteractiveMapController.validate(operation: "present", parameters: ["id": "map-1", "address": "https://example.com", "rect": rect]))
        XCTAssertThrowsError(try InteractiveMapController.validate(operation: "update", parameters: ["id": "map-1", "rect": rect, "latitude": "0"]))
        XCTAssertNoThrow(try InteractiveMapController.validate(operation: "update", parameters: ["id": "map-1", "rect": rect, "mode": "fullscreen"]))
        XCTAssertThrowsError(try InteractiveMapController.validate(operation: "update", parameters: ["id": "map-1", "rect": rect, "mode": "tracking"]))
        XCTAssertThrowsError(try InteractiveMapController.validate(operation: "update", parameters: ["id": "map-1", "rect": rect, "location": "true"]))
        XCTAssertThrowsError(try InteractiveMapController.validate(operation: "close", parameters: ["id": "map-1", "mode": "fullscreen"]))
        XCTAssertThrowsError(try InteractiveMapController.validate(operation: "open", parameters: ["id": "map-1"]))
    }

    #if os(macOS)
    @MainActor
    func testLiveInteractiveSurfaceWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SCREENPUNK_TEST_LIVE_MAPS"] == "1" else { throw XCTSkip("Opt-in visible Apple map smoke test") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = webView; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let controller = InteractiveMapController(); controller.attach(webView)
        defer { controller.cancel(); window.close() }
        let rect = "{\"x\":40,\"y\":40,\"width\":640,\"height\":360,\"viewportWidth\":800,\"radius\":20,\"visible\":1}"
        let initial = try controller.request(operation: "present", parameters: ["id": "map-test", "address": "5 Avenue Anatole France, 75007 Paris, France", "rect": rect])
        XCTAssertEqual(initial["state"], "loading")
        var state = "loading"
        for _ in 0..<140 {
            try await Task.sleep(nanoseconds: 100_000_000)
            state = try controller.request(operation: "update", parameters: ["id": "map-test", "rect": rect])["state"] ?? ""
            if state != "loading" { break }
        }
        XCTAssertEqual(state, "ready")
        let surface = try XCTUnwrap(webView.subviews.first { $0.subviews.contains { $0 is MKMapView } })
        let map = try XCTUnwrap(surface.subviews.compactMap { $0 as? MKMapView }.first)
        XCTAssertTrue(map.isZoomEnabled && map.isScrollEnabled)
        XCTAssertFalse(map.showsUserLocation)
        var region = map.region; region.center.latitude += 0.001; region.span.latitudeDelta /= 2; region.span.longitudeDelta /= 2
        map.setRegion(region, animated: false)
        let changed = map.region
        _ = try controller.request(operation: "update", parameters: ["id": "map-test", "rect": rect])
        XCTAssertEqual(map.region.center.latitude, changed.center.latitude, accuracy: 0.00001)
        XCTAssertEqual(map.region.span.latitudeDelta, changed.span.latitudeDelta, accuracy: 0.00001)
        let locationButton = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Show my location" })
        XCTAssertTrue(locationButton.isHidden)
        let expanded = "{\"x\":0,\"y\":0,\"width\":800,\"height\":540,\"viewportWidth\":800,\"radius\":0,\"visible\":1}"
        _ = try controller.request(operation: "update", parameters: ["id": "map-test", "rect": expanded, "mode": "fullscreen"])
        XCTAssertFalse(locationButton.isHidden)
        XCTAssertFalse(map.showsUserLocation, "Fullscreen alone must not request or show location")
        XCTAssertTrue(surface.subviews.contains { $0 === map })
        XCTAssertEqual(map.region.center.latitude, changed.center.latitude, accuracy: 0.00001)
        _ = try controller.request(operation: "update", parameters: ["id": "map-test", "rect": rect, "mode": "embedded"])
        XCTAssertTrue(locationButton.isHidden)
        XCTAssertFalse(map.showsUserLocation)
        var taps: [String] = []
        controller.onTap = { taps.append($0) }
        let recognizer = try XCTUnwrap(map.gestureRecognizers.first { $0 is NSClickGestureRecognizer && $0.target === surface })
        let action = try XCTUnwrap(recognizer.action)
        _ = surface.perform(action)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(taps, ["map-test"])
        _ = surface.perform(action)
        _ = surface.perform(action)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(taps.count, 1, "Second tap must suppress the pending single tap")
        _ = surface.perform(action)
        _ = try controller.request(operation: "close", parameters: ["id": "map-test"])
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(taps.count, 1, "Closing must suppress a pending tap")
        XCTAssertNil(surface.superview)
    }
    #endif

    func testAddressAndDimensionsAreBoundedBeforeNetworkAccess() throws {
        let request = try MapPreviewRequest(["address": "  Eiffel Tower, Paris, France  "])
        XCTAssertEqual(request.address, "Eiffel Tower, Paris, France")
        XCTAssertEqual(request.width, 640)
        for parameters in [
            ["address": ""], ["address": "https://example.com"],
            ["address": String(repeating: "a", count: 513)],
            ["address": "Paris\nFrance"], ["address": "Paris", "url": "example.com"],
            ["address": "Paris", "width": "1025"], ["address": "Paris", "height": "119"],
            ["address": "Paris", "width": "NaN"], ["address": "Paris", "latitude": "48"]
        ] { XCTAssertThrowsError(try MapPreviewRequest(parameters)) }
        XCTAssertNoThrow(try MapPreviewRequest(["address": "Paris", "width": "1024", "height": "768"]))
    }
}
