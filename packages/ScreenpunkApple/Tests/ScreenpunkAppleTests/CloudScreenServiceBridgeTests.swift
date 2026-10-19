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
        let gate = RendererPresentationTestGate()
        var didHold = false
        let heldStarted = expectation(description:"in-flight service invocation")
        let held = RendererHeldOperation(onHeld:{didHold = true; heldStarted.fulfill()})
        defer { held.release(); XCTAssertFalse(held.escaped) }
        let bridge = CloudScreenServiceBridge(lifetime: lifetime, declaredOperations: ["weather.read", "ai.generate"], presentationAllowed:{gate.allows()}) { id, _, operation, input in
            calls.append((id, operation))
            if input == "held" { try await held.hold() }
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
        defer { bridge.retire(); web.stopLoading() }
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
        guard waiter.succeeded else { return }
        let binding = UUID().uuidString.lowercased(), invocation = UUID().uuidString.lowercased()
        let premature = try await rendererJavaScript(web,"try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}",arguments:["binding": binding]) as? String
        XCTAssertTrue(premature?.contains("service_request_denied") == true)
        XCTAssertTrue(calls.isEmpty)
        bridge.setMounted()
        let response = try await rendererJavaScript(web,"""
            const options={bindingId:binding,invocationId:invocation};
            const weather=await screenpunkServices.invoke('weather.read',{location:'Boston'},options);
            const aiOptions={bindingId:binding,invocationId:aiInvocation};
            const pending=await screenpunkServices.invoke('ai.generate',{prompt:'Title'},aiOptions);
            const settled=await screenpunkServices.invoke('ai.generate',{prompt:'Title'},aiOptions);
            return [weather.status,pending.status,settled.status];
            """,arguments:["binding": binding, "invocation": invocation, "aiInvocation": UUID().uuidString.lowercased()]) as? [String]
        XCTAssertEqual(response, ["succeeded", "pending", "succeeded"])
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(calls[1].0, calls[2].0)
        let suspended = expectation(description:"retained document pending promise settled before provider completes")
        var lateReply:String?, oldCompleted = false
        let oldRequest = Task {
            defer { oldCompleted = true; suspended.fulfill() }
            do { lateReply = try await rendererJavaScript(web,"try{await screenpunkServices.invoke('weather.read',{location:'held'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}",arguments:["binding":binding]) as? String }
            catch { XCTFail("bounded service request failed: \(error)") }
        }
        defer { oldRequest.cancel() }
        await fulfillment(of:[heldStarted],timeout:5)
        guard didHold else { return }
        gate.set(false) // Host gate closes before any coordinator/SwiftUI update.
        let earlyDenied = try await rendererJavaScript(web,"try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}",arguments:["binding":binding]) as? String
        XCTAssertTrue(earlyDenied?.contains("service_request_denied") == true); XCTAssertEqual(calls.count,4)
        await fulfillment(of:[suspended],timeout:3) // Provider is deliberately still waiting.
        guard oldCompleted else { return }
        gate.set(true); bridge.setActive(true)
        held.release()
        XCTAssertTrue(lateReply?.contains("service_disconnected") == true)
        let resumed = try await rendererJavaScript(web,"return (await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding})).status",arguments:["binding":binding]) as? String
        XCTAssertEqual(resumed,"succeeded"); XCTAssertEqual(calls.count,5)
        bridge.setActive(false)
        let denied = try await rendererJavaScript(web,"try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}",arguments:["binding": binding]) as? String
        XCTAssertTrue(denied?.contains("service_request_denied") == true)
        XCTAssertEqual(calls.count, 5)
        // Promotion retires the old frame's lifetime even if its declarations
        // match the new screen and a late foreground callback tries to resume it.
        lifetime.retire(); bridge.setActive(true)
        let retired = try await rendererJavaScript(web,"try{await screenpunkServices.invoke('weather.read',{location:'Boston'},{bindingId:binding});return 'accepted'}catch(e){return String(e)}",arguments:["binding": binding]) as? String
        XCTAssertTrue(retired?.contains("service_request_denied") == true)
        XCTAssertEqual(calls.count, 5)
        bridge.retire(); web.stopLoading()
    }

}
#endif

#if canImport(WebKit)
@MainActor private final class ServiceNavigationWaiter: NSObject, WKNavigationDelegate {
    let loaded = XCTestExpectation(description: "service package loaded")
    private(set) var succeeded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { succeeded = true; loaded.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { XCTFail("Service package navigation failed: \(error)"); loaded.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { XCTFail("Service package provisional navigation failed: \(error)"); loaded.fulfill() }
}
#endif
