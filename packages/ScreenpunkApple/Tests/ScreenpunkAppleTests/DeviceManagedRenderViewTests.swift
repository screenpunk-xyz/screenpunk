import XCTest
import Foundation
@_spi(ManagedRender) @testable import ScreenpunkCore
@testable import ScreenpunkApple
#if canImport(WebKit) && canImport(CryptoKit)
import WebKit
import CryptoKit

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
#endif
