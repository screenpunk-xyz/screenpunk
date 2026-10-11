#if canImport(WebKit)
import XCTest
import WebKit
import ScreenpunkCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
@testable import ScreenpunkApple

@MainActor final class CloudScreenServiceBridgeTests: XCTestCase {
    func testDeclarationsDoNotExpandOperations() {
        let valid = Data(#"{"schemaVersion":1,"requirements":[{"service":"fixture.v1","operation":"weather.read"},{"service":"fixture.v1","operation":"ai.generate"}]}"#.utf8)
        XCTAssertEqual(CloudScreenServiceBridge.declaredOperations(valid), Set(["weather.read", "ai.generate"]))
        XCTAssertTrue(CloudScreenServiceBridge.declaredOperations(nil).isEmpty)
        let invalidVersion = Data(#"{"schemaVersion":true,"requirements":[{"service":"fixture.v1","operation":"weather.read"}]}"#.utf8)
        XCTAssertTrue(CloudScreenServiceBridge.declaredOperations(invalidVersion).isEmpty)
        let unsupported = Data(#"{"schemaVersion":1,"requirements":[{"service":"private-provider","operation":"weather.read"}]}"#.utf8)
        XCTAssertTrue(CloudScreenServiceBridge.declaredOperations(unsupported).isEmpty)
        let override = Data(#"{"schemaVersion":1,"requirements":[{"service":"fixture.v1","operation":"weather.read","providerKey":"secret"}]}"#.utf8)
        XCTAssertTrue(CloudScreenServiceBridge.declaredOperations(override).isEmpty)
        XCTAssertTrue(CloudScreenServiceBridge.declaredOperations(Data(repeating: 32, count: 8193)).isEmpty)
    }
    func testWebKitWeatherAsyncAndInactiveBridge() async throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let lifetime = DeviceRuntimeLifetime()
        var calls: [(UUID, String)] = []
        let bridge = CloudScreenServiceBridge(lifetime: lifetime, declaredOperations: ["weather.read", "ai.generate"]) { id, _, operation, _ in
            calls.append((id, operation))
            let count = calls.filter { $0.0 == id }.count
            return Data((operation == "ai.generate" && count == 1 ? "{\"status\":\"pending\"}" : "{\"status\":\"succeeded\"}").utf8)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "screenpunkServices")
        configuration.userContentController.addUserScript(WKUserScript(source: CloudScreenServiceBridge.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let store = PackageAssetStore(assets: ["index.html": PackageAsset(path: "index.html", data: Data("<html><body>Service fixture</body></html>".utf8), mime: "text/html")])
        configuration.setURLSchemeHandler(PackageSchemeHandler(store: store), forURLScheme: "screenpunk")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        #if os(macOS)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web; window.orderBack(nil)
        defer { window.orderOut(nil) }
        #elseif os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        controller.view = web; window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true }
        #endif
        let waiter = ServiceNavigationWaiter()
        web.navigationDelegate = waiter
        web.load(URLRequest(url: URL(string: "screenpunk://package/index.html")!))
        await fulfillment(of: [waiter.loaded], timeout: 10)
        let binding = UUID().uuidString.lowercased(), invocation = UUID().uuidString.lowercased()
        let premature = try await web.callAsyncJavaScript("try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}", arguments: ["binding": binding], in: nil, contentWorld: .page) as? String
        XCTAssertTrue(premature?.contains("service_request_denied") == true)
        XCTAssertTrue(calls.isEmpty)
        bridge.setMounted()
        let response = try await web.callAsyncJavaScript("""
            const options={bindingId:binding,invocationId:invocation};
            const weather=await screenpunkServices.invoke('weather.read',{location:'Boston'},options);
            const aiOptions={bindingId:binding,invocationId:aiInvocation};
            const pending=await screenpunkServices.invoke('ai.generate',{prompt:'Title'},aiOptions);
            const settled=await screenpunkServices.invoke('ai.generate',{prompt:'Title'},aiOptions);
            return [weather.status,pending.status,settled.status];
            """, arguments: ["binding": binding, "invocation": invocation, "aiInvocation": UUID().uuidString.lowercased()], in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(response, ["succeeded", "pending", "succeeded"])
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(calls[1].0, calls[2].0)
        bridge.setActive(false)
        let denied = try await web.callAsyncJavaScript("try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}", arguments: ["binding": binding], in: nil, contentWorld: .page) as? String
        XCTAssertTrue(denied?.contains("service_request_denied") == true)
        XCTAssertEqual(calls.count, 3)
        // Promotion retires the old frame's lifetime even if its declarations
        // match the new screen and a late foreground callback tries to resume it.
        lifetime.retire(); bridge.setActive(true)
        let retired = try await web.callAsyncJavaScript("try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}", arguments: ["binding": binding], in: nil, contentWorld: .page) as? String
        XCTAssertTrue(retired?.contains("service_request_denied") == true)
        XCTAssertEqual(calls.count, 3)
        bridge.retire(); web.stopLoading()
    }

}
#endif

#if canImport(WebKit)
@MainActor private final class ServiceNavigationWaiter: NSObject, WKNavigationDelegate {
    let loaded = XCTestExpectation(description: "service package loaded")
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { XCTFail("Service package navigation failed: \(error)"); loaded.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { XCTFail("Service package provisional navigation failed: \(error)"); loaded.fulfill() }
}
#endif
