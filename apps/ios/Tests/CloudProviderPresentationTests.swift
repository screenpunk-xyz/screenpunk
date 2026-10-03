import XCTest
import AuthenticationServices
import GoogleSignIn
import SwiftUI
import UIKit
@testable import Screenpunk

@MainActor
final class CloudProviderPresentationTests: XCTestCase {
    func testUnboundAndDetachedControllerCannotUseAnUnrelatedWindow() {
        let presentation = CloudProviderPresentation()
        XCTAssertThrowsError(try presentation.resolve())
        let detached = UIViewController(); detached.loadViewIfNeeded(); presentation.bind(detached)
        XCTAssertThrowsError(try presentation.resolve())
    }

    func testFakeResolverIsExplicitAndNotCalledByBinding() throws {
        var calls = 0
        let controller = UIViewController(), window = UIWindow()
        let presentation = CloudProviderPresentation(testResolve: { calls += 1; return .init(controller: controller, window: window) })
        presentation.bind(controller)
        XCTAssertEqual(calls, 0)
        let result = try presentation.resolve()
        XCTAssertEqual(calls, 1); XCTAssertTrue(result.controller === controller); XCTAssertTrue(result.window === window)
    }

    func testCurrentSceneWindowAndVisibleTopControllerResolveAndHiddenWindowBlocks() async throws {
        let scene = try activeScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController(), window = UIWindow(windowScene: scene)
        window.rootViewController = root; window.makeKeyAndVisible(); root.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let presentation = CloudProviderPresentation(); presentation.bind(root)
        let first = try presentation.resolve()
        XCTAssertTrue(first.controller === root); XCTAssertTrue(first.window === window)
        let top = UIViewController()
        await withCheckedContinuation { continuation in root.present(top, animated: false) { continuation.resume() } }
        let next = try presentation.resolve()
        XCTAssertTrue(next.controller === top); XCTAssertTrue(next.window === window)
        window.isHidden = true
        XCTAssertThrowsError(try presentation.resolve())
    }

    func testLostCapturedControllerCannotRebindThroughGlobalWindows() throws {
        let scene = try activeScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible(); root.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let presentation = CloudProviderPresentation(); presentation.bind(root)
        XCTAssertNoThrow(try presentation.resolve())
        window.rootViewController = UIViewController()
        XCTAssertNil(root.viewIfLoaded?.window)
        XCTAssertThrowsError(try presentation.resolve())
    }

    func testRepresentableCapturesItsContainingSceneWindow() async throws {
        let scene = try activeScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let presentation = CloudProviderPresentation()
        let hosting = UIHostingController(rootView: Text("Fixture").background(CloudPresentationAnchor(presentation: presentation).frame(width: 0, height: 0)))
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        hosting.view.layoutIfNeeded(); await Task.yield(); hosting.view.layoutIfNeeded()
        let result = try presentation.resolve()
        XCTAssertTrue(result.controller === hosting); XCTAssertTrue(result.window === window)
    }

    func testOfficialProviderControlsRenderDisabledWithoutAuthenticationAndHaveLabels() async throws {
        let scene = try activeScene(), previous = scene.windows.first(where: \.isKeyWindow)
        var apples = 0, googles = 0
        let hosting = UIHostingController(rootView: CloudNativeProviderButtons(enabled: false, apple: { apples += 1 }, google: { googles += 1 }))
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        hosting.view.layoutIfNeeded(); await Task.yield(); hosting.view.layoutIfNeeded()
        let controls = allSubviews(hosting.view).compactMap { $0 as? UIControl }
        let apple = try XCTUnwrap(controls.first(where: { $0.accessibilityIdentifier == "cloud.signIn.apple" }) as? ASAuthorizationAppleIDButton)
        let google = try XCTUnwrap(controls.first(where: { $0.accessibilityIdentifier == "cloud.signIn.google" }) as? GIDSignInButton)
        XCTAssertFalse(apple.isEnabled); XCTAssertFalse(google.isEnabled)
        XCTAssertEqual(apple.accessibilityLabel, "Sign in with Apple")
        XCTAssertFalse(google.accessibilityLabel?.isEmpty ?? true)
        XCTAssertEqual(google.accessibilityHint, "Google account sign-in")
        XCTAssertEqual(google.style, .standard)
        XCTAssertGreaterThanOrEqual(apple.bounds.height, 44); XCTAssertGreaterThanOrEqual(google.bounds.height, 44)
        apple.sendActions(for: .touchUpInside); google.sendActions(for: .touchUpInside)
        XCTAssertEqual(apples, 0); XCTAssertEqual(googles, 0)
        hosting.rootView = CloudNativeProviderButtons(enabled: true, apple: { apples += 1 }, google: { googles += 1 })
        hosting.view.layoutIfNeeded(); await Task.yield(); hosting.view.layoutIfNeeded()
        apple.sendActions(for: .touchUpInside); google.sendActions(for: .touchUpInside)
        XCTAssertEqual(apples, 1); XCTAssertEqual(googles, 1)
    }

    private func activeScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
    }
    private func allSubviews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allSubviews) }
}
