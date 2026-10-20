import XCTest
import Foundation
@_spi(ManagedRender) @testable import ScreenpunkCore
@testable import ScreenpunkApple
#if canImport(WebKit) && canImport(CryptoKit)
import WebKit
import CryptoKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Isolated renderer tests only. This internal qualified-byte projection seam is NOT a production
/// admission factory. Genuine four-store checkpoint issuance is tested in Core transport tests.
@MainActor final class DeviceManagedRenderViewTests:XCTestCase {
    private enum Changed:Error {case stale}
    private func content(_ text:String="Isolated static fixture",validate:@escaping ()throws->Void = {})throws->DeviceManagedStaticContent {
        func hash(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
        let html=Data("<html><body>\(text)</body></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:"00000000-0000-4000-8000-000000000001",name:"Static",revision:"00000000-0000-4000-8000-000000000002",entrypoint:"screen.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[],files:[.init(path:"screen.html",bytes:html.count,sha256:hash(html))])
        manifest.digest=hash(try GrantPreparationCodec.encode(manifest))
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        let package=try DevicePackageQualifier.qualify(.init(manifest:GrantPreparationCodec.encode(manifest),files:[.init(path:"screen.html",bytes:html)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
        return try DeviceManagedRenderProjection.make(package:package,operationID:UUID(),generationID:UUID(),entryID:UUID(),displayName:"Static fixture",validate:validate)
    }
    private func show(_ web: WKWebView) throws -> () -> Void {
        #if os(macOS)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x:0,y:0,width:390,height:844), styleMask:.borderless, backing:.buffered, defer:false)
        window.contentView = web; window.orderBack(nil)
        return { window.orderOut(nil) }
        #elseif os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene), controller = UIViewController()
        controller.view = web; window.rootViewController = controller; window.isHidden = false
        return { window.isHidden = true }
        #else
        return {}
        #endif
    }
    func testIdenticalViewUpdatesAndRetainedPauseKeepDocumentWithoutGraphIO() async throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let gate = RendererPresentationTestGate(); var checks = 0
        let content = try content(validate:{ checks += 1 }), lifetime = DeviceRuntimeLifetime()
        let mounted = expectation(description:"actual package navigation mounted"); var didMount = false
        let coordinator = DashboardWebCoordinator(managedStatic:content,lifetime:lifetime,presentationAllowed:{gate.allows()},serviceMounted:{ didMount = true; mounted.fulfill() })
        let web = coordinator.makeWebView(), close = try show(web)
        defer { coordinator.retireForReset(); close() }
        await fulfillment(of:[mounted],timeout:10)
        guard didMount else { return }
        XCTAssertTrue(coordinator.hasMountedPresentation)
        _ = try await rendererJavaScript(web,"globalThis.retainedFixture='same-document';return true",arguments:[:])
        let before = checks
        for _ in 0..<5 { coordinator.updateManagedStatic(content:content,lifetime:lifetime) }
        XCTAssertEqual(checks,before)
        gate.set(false); coordinator.updateManagedStatic(content:content,lifetime:lifetime)
        coordinator.webView(web,didFinish:nil) // Late callback must deny before resource validation.
        XCTAssertEqual(checks,before); XCTAssertTrue(coordinator.isPresentationSuspended)
        XCTAssertFalse(coordinator.isRetired); XCTAssertFalse(lifetime.isRetired)
        XCTAssertEqual(coordinator.handler.store.assets["screen.html"]?.data,content.assets.first(where:{$0.path == "screen.html"})?.bytes)
        gate.set(true); coordinator.updateManagedStatic(content:content,lifetime:lifetime)
        XCTAssertEqual(checks,before); XCTAssertFalse(coordinator.isPresentationSuspended)
        XCTAssertTrue(coordinator.hasMountedPresentation); XCTAssertTrue(web.navigationDelegate === coordinator)
        let marker = try await rendererJavaScript(web,"return globalThis.retainedFixture",arguments:[:]) as? String
        XCTAssertEqual(marker,"same-document")
    }
    func testPauseCancelsInitialMountEpochWithoutFailureOrLateReactivation() async throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let gate = RendererPresentationTestGate(); var failures = 0, mounts = 0, checks = 0
        var didHold = false, didMountNew = false
        let started = expectation(description:"initial real navigation reached mount callback"), mountedNew = expectation(description:"new real navigation mounted")
        let held = RendererHeldOperation(onHeld:{didHold = true; started.fulfill()})
        defer { held.release(); XCTAssertFalse(held.escaped) }
        let content = try content(validate:{checks += 1}), lifetime = DeviceRuntimeLifetime()
        let coordinator = DashboardWebCoordinator(managedStatic:content,lifetime:lifetime,presentationAllowed:{gate.allows()},serviceMounted:{
            mounts += 1
            if mounts == 1 { try await held.hold() }
            else { didMountNew = true; mountedNew.fulfill() }
        },serviceMountFailed:{ _ in failures += 1 })
        let web = coordinator.makeWebView(), close = try show(web)
        defer { coordinator.retireForReset(); close() }
        let oldNavigation = try XCTUnwrap(coordinator.currentNavigation)
        await fulfillment(of:[started],timeout:10)
        guard didHold else { return }
        XCTAssertNotNil(web.url); XCTAssertFalse(coordinator.hasMountedPresentation)
        gate.set(false); coordinator.updateManagedStatic(content:content,lifetime:lifetime)
        gate.set(true); coordinator.updateManagedStatic(content:content,lifetime:lifetime)
        held.release()
        let newNavigation = try XCTUnwrap(web.load(URLRequest(url:URL(string:"screenpunk://package/screen.html")!)))
        XCTAssertFalse(newNavigation === oldNavigation)
        coordinator.webView(web,didStartProvisionalNavigation:newNavigation)
        XCTAssertTrue(coordinator.currentNavigation === newNavigation)
        let beforeOldCallbacks = checks
        coordinator.webView(web,didFinish:oldNavigation)
        coordinator.webView(web,didFail:oldNavigation,withError:NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut))
        XCTAssertEqual(checks,beforeOldCallbacks,"old token must deny before resource validation even after a new load")
        await fulfillment(of:[mountedNew],timeout:10)
        guard didMountNew else { return }
        XCTAssertTrue(coordinator.hasMountedPresentation); XCTAssertEqual(mounts,2); XCTAssertEqual(failures,0)
        XCTAssertFalse(coordinator.isRetired); XCTAssertFalse(lifetime.isRetired)
    }
    func testSameContentUpdateCannotReplaceInitializerGateBinding() throws {
        let original = RendererPresentationTestGate(), offered = RendererPresentationTestGate()
        let content = try content(), lifetime = DeviceRuntimeLifetime()
        let coordinator = DashboardWebCoordinator(managedStatic:content,lifetime:lifetime,presentationAllowed:{original.allows()})
        defer { coordinator.retireForReset() }
        offered.set(false)
        coordinator.updateManagedStatic(content:content,lifetime:lifetime,presentationAllowed:{offered.allows()})
        XCTAssertFalse(coordinator.isPresentationSuspended)
        original.set(false); offered.set(true)
        coordinator.updateManagedStatic(content:content,lifetime:lifetime,presentationAllowed:{offered.allows()})
        XCTAssertTrue(coordinator.isPresentationSuspended,"all children stay bound to the original host gate")
    }
    func testRetainedSDKPromiseSettlesOnPauseBeforeProviderAndFreshRequestWorks() async throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let started = expectation(description:"original request entered transport"), loaded = expectation(description:"SDK document loaded")
        var didHold = false, didLoad = false
        let held = RendererHeldOperation(onHeld:{didHold = true; started.fulfill()})
        defer { held.release(); XCTAssertFalse(held.escaped) }
        let prefsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-prefs-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:prefsRoot) }
        let http = RetainedRendererHTTP(held:held), authorizations = RendererAuthorizationCounter()
        let connection = ConnectionRuntime(dashboardId:"fixture",store:MemoryCredentialStore(),http:http,webSocket:RetainedRendererNoSocket(),resolver:FixedResolver(["93.184.216.34"]),authorizeScope:{authorizations.record()})
        let grant = ConnectionGrant(schemaVersion:1,id:UUID(),alias:"probe",origin:"https://example.com",transport:.http,authRef:"probe",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:.http,method:.GET,path:"/state",idempotent:true,write:false)])
        try await connection.install(grant:grant,binding:.init(authRef:"probe",placement:.none))
        let gate = RendererPresentationTestGate(), lifetime = DeviceRuntimeLifetime()
        let coordinator = DashboardWebCoordinator(store:try .bundledOfflineFixture(),lifetime:lifetime,preferenceStore:ScreenPreferenceStore(root:prefsRoot),connections:connection,presentationAllowed:{gate.allows()},onReady:{didLoad = true; loaded.fulfill()}) {}
        let web = coordinator.makeWebView(), close = try show(web)
        defer { coordinator.retireForReset(); close() }
        await fulfillment(of:[loaded],timeout:10)
        guard didLoad else { return }
        let settled = expectation(description:"SDK promise settled before transport release")
        var oldReply:String?, oldCompleted = false
        let oldRequest = Task {
            defer { oldCompleted = true; settled.fulfill() }
            do { oldReply = try await rendererJavaScript(web,"try{return (await screenpunk.connections.request('probe','read',{})).value.value}catch(e){return e.code}") as? String }
            catch { XCTFail("bounded SDK request failed: \(error)") }
        }
        defer { oldRequest.cancel() }
        await fulfillment(of:[started],timeout:3)
        guard didHold else { return }
        let beforePause = authorizations.count()
        _ = try await rendererJavaScript(web,"window.retainedMarker = 'same-document'")
        gate.set(false); lifetime.suspendPresentation(); gate.set(true)
        // No redraw or callback observes the closed boolean. The exact lifetime
        // notification must invalidate and settle the already pending request.
        XCTAssertTrue(coordinator.isPresentationSuspended)
        await fulfillment(of:[settled],timeout:3)
        guard oldCompleted else { return }
        let pausedCalls = await http.calls(); XCTAssertEqual(pausedCalls,1)
        XCTAssertEqual(authorizations.count(),beforePause,"closed gate must not enter Core authorization")
        coordinator.update(settings:.init(),active:true,onSettingsApplied:{_ in})
        held.release()
        XCTAssertEqual(oldReply,"device_offline")
        let fresh = try await rendererJavaScript(web,"return (await screenpunk.connections.request('probe','read',{})).value.value") as? String
        XCTAssertEqual(fresh,"resumed")
        let marker = try await rendererJavaScript(web,"return window.retainedMarker") as? String
        XCTAssertEqual(marker,"same-document")
        XCTAssertFalse(coordinator.isRetired); XCTAssertTrue(web.navigationDelegate === coordinator)
    }
    func testStaticCoordinatorHasNoBridgeEventsRasterOrInjectedSDK()throws {
        let content=try content(),lifetime=DeviceRuntimeLifetime(),coordinator=DashboardWebCoordinator(managedStatic:content,lifetime:lifetime)
        XCTAssertFalse(coordinator.hasCapabilityBridge);XCTAssertFalse(coordinator.hasEventRuntime)
        XCTAssertNil(coordinator.handler.rasterResources);XCTAssertFalse(coordinator.isRetired)
        XCTAssertEqual(coordinator.handler.store.assets["screen.html"]?.data,content.assets.first(where:{$0.path == "screen.html"})?.bytes)
        let webView=coordinator.makeWebView();defer{coordinator.retireForReset()}
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(webView.configuration.userContentController.userScripts.contains{$0.source.contains("connections.request") || $0.source.contains("screenpunk.preference")})
    }
    func testStaleBeforeConstructionCreatesOnlyEmptyRetiredRenderer()throws {
        let content=try content(validate:{throw Changed.stale}),coordinator=DashboardWebCoordinator(managedStatic:content,lifetime:DeviceRuntimeLifetime())
        XCTAssertTrue(coordinator.isRetired);XCTAssertTrue(coordinator.handler.store.assets.isEmpty)
        XCTAssertNil(coordinator.handler.rasterResources);XCTAssertFalse(coordinator.hasCapabilityBridge);XCTAssertFalse(coordinator.hasEventRuntime)
        let view=coordinator.makeWebView();XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }
    func testUpdateRechecksOriginalResourcesAndRetiresOnFailure()throws {
        var valid=true,checks=0
        let content=try content(validate:{checks += 1;guard valid else{throw Changed.stale}})
        let coordinator=DashboardWebCoordinator(managedStatic:content,lifetime:DeviceRuntimeLifetime())
        XCTAssertFalse(coordinator.isRetired);valid=false
        coordinator.update(settings:.init(),active:true,onSettingsApplied:{_ in XCTFail("stale renderer must not publish settings")})
        XCTAssertTrue(coordinator.isRetired);XCTAssertGreaterThanOrEqual(checks,2)
        XCTAssertFalse(coordinator.hasCapabilityBridge);XCTAssertNil(coordinator.handler.rasterResources)
    }
    func testResourceChangeAfterCoordinatorConstructionBlocksInitialNavigation() throws {
        var valid = true, checks = 0, mounts = 0, failures = 0
        let content = try content(validate: { checks += 1; guard valid else { throw Changed.stale } })
        let coordinator = DashboardWebCoordinator(managedStatic: content, lifetime: DeviceRuntimeLifetime(),
            serviceMounted: { mounts += 1 }, serviceMountFailed: { _ in failures += 1 })
        defer { coordinator.retireForReset() }
        XCTAssertFalse(coordinator.isRetired)
        XCTAssertFalse(coordinator.handler.store.assets.isEmpty)
        let before = checks
        valid = false
        let view = coordinator.makeWebView()
        XCTAssertGreaterThan(checks, before, "Initial construction must freshly reject resources changed after coordinator admission")
        XCTAssertTrue(coordinator.isRetired)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertNil(view.configuration.urlSchemeHandler(forURLScheme: IsolationPolicy.customScheme))
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        XCTAssertNil(view.url); XCTAssertFalse(view.isLoading)
        XCTAssertNil(view.navigationDelegate); XCTAssertNil(view.uiDelegate)
        XCTAssertFalse(coordinator.hasCapabilityBridge); XCTAssertFalse(coordinator.hasEventRuntime)
        XCTAssertFalse(coordinator.hasMountedPresentation)
        XCTAssertEqual(mounts, 0); XCTAssertEqual(failures, 0)
    }
    func testReusedCoordinatorRejectsDifferentGenuineContentAndLifetime()throws {
        let first=try content("First"),second=try content("Second")
        XCTAssertNotEqual(first.assets.first(where:{$0.path == "screen.html"})?.bytes,second.assets.first(where:{$0.path == "screen.html"})?.bytes)
        let originalLifetime=DeviceRuntimeLifetime()
        let replacedContent=DashboardWebCoordinator(managedStatic:first,lifetime:originalLifetime)
        let originalAssets=replacedContent.handler.store.assets
        replacedContent.updateManagedStatic(content:second,lifetime:originalLifetime)
        XCTAssertTrue(replacedContent.isRetired);XCTAssertEqual(replacedContent.handler.store.assets,originalAssets)
        let replacedLifetime=DashboardWebCoordinator(managedStatic:first,lifetime:originalLifetime)
        replacedLifetime.updateManagedStatic(content:first,lifetime:DeviceRuntimeLifetime())
        XCTAssertTrue(replacedLifetime.isRetired);XCTAssertEqual(replacedLifetime.handler.store.assets,originalAssets)
        let unchanged=DashboardWebCoordinator(managedStatic:first,lifetime:originalLifetime)
        unchanged.updateManagedStatic(content:first,lifetime:originalLifetime)
        XCTAssertFalse(unchanged.isRetired);unchanged.retireForReset()
    }
    func testRetiredLifetimeCannotCreateActiveViewAndDismantleIsTerminal()throws {
        let content=try content(),retired=DeviceRuntimeLifetime();retired.retire()
        let blocked=DashboardWebCoordinator(managedStatic:content,lifetime:retired)
        XCTAssertTrue(blocked.isRetired);XCTAssertTrue(blocked.handler.store.assets.isEmpty)
        let lifetime=DeviceRuntimeLifetime(),active=DashboardWebCoordinator(managedStatic:content,lifetime:lifetime)
        active.retireForReset();active.update(settings:.init(),active:true,onSettingsApplied:{_ in})
        XCTAssertTrue(active.isRetired);XCTAssertFalse(active.hasCapabilityBridge)
    }
}
private final class RendererAuthorizationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
private struct RetainedRendererNoSocket: WebSocketTransport {
    func connect(_ request: AuthorizedWebSocketRequest) async throws -> any WebSocketSession { throw ConnectionFailure.permissionRequired }
}
private actor RetainedRendererHTTP: HTTPTransport {
    private var count = 0
    private let held:RendererHeldOperation
    init(held:RendererHeldOperation) { self.held = held }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        count += 1
        if count == 1 { try await held.hold(); return .init(status:200,body:Data("{\"value\":\"obsolete-success\"}".utf8)) }
        return .init(status:200,body:Data("{\"value\":\"resumed\"}".utf8))
    }
    func calls() -> Int { count }
}
#endif
