import XCTest
import SwiftUI
import UIKit
import Combine
@_spi(NativeInstallation) @testable import ScreenpunkCore
@_spi(ManagedRender) @_spi(NativeInstallation) import ScreenpunkApple
@testable import Screenpunk

@MainActor
final class CloudSceneRootTests: XCTestCase {
    func testPreparedNativeConnectClosesOriginalRootSheetBeforeActualEmptyMount() async throws {
        let native = try await NativePreparedConnectionFixture.make()
        defer { native.close() }
        let human = RouteJourneyFixture(accountID: native.accountID)
        await human.transport.setAccounts(true)
        await (try human.actions.signIn(.google))?.value
        await human.actions.chooseAccount(native.accountID)?.value
        XCTAssertEqual(human.coordinator.selectedAccountID, native.accountID)
        XCTAssertFalse(native.controller.hasRecordedCloudInstallation)
        XCTAssertNil(try native.unified.mountedAssociation())
        var mountedAtConnectionReady: Bool?, runtimeReceiptAtConnectionReady: Bool?
        let readiness = native.controller.$completedExplicitConnectionOperationID.sink { operation in
            guard operation != nil else { return }
            mountedAtConnectionReady = (try? native.unified.mountedAssociation()) != nil
            runtimeReceiptAtConnectionReady = native.http.deliveryPaths.contains { $0.hasSuffix("/services/runtime-observations") }
        }
        defer { readiness.cancel() }
        var connectionTask: Task<Void, Error>?, callbackError: Error?, connectCalls = 0
        var reportedEmptyGeneration: UUID?
        let root = CloudSceneRoot(cloud: human.lifecycle, bootstrap: native.bootstrap, enrollment: native.controller,
            accountSheet: .init(availability: .qualified), connectDevice: { account, location, name in
                connectCalls += 1
                XCTAssertEqual(account, native.accountID); XCTAssertNil(location); XCTAssertEqual(name, native.name)
                do { connectionTask = try native.connect() } catch { callbackError = error }
            }, emptyMountReported: { reportedEmptyGeneration = $0 })
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), hosting = UIHostingController(rootView: root)
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let originalSheet = try await presentedSettings(hosting, phase: "prepared native original Connect sheet")
        let connect = try await routeButton("Connect device", in: originalSheet.view)
        assertVisible(connect, in: window)
        let cancellations = human.cancellations
        XCTAssertTrue(connect.accessibilityActivate())
        XCTAssertEqual(connectCalls, 1); XCTAssertNil(callbackError)
        try await XCTUnwrap(connectionTask).value
        let operation = try XCTUnwrap(native.controller.completedExplicitConnectionOperationID)
        XCTAssertNoThrow(try native.controller.requireExplicitConnectionCompletion(operationID: operation))
        XCTAssertEqual(mountedAtConnectionReady, false, "Connection readiness cannot manufacture a mounted display")
        XCTAssertEqual(runtimeReceiptAtConnectionReady, false)
        try await waitFor("original Connect sheet automatically closes") {
            hosting.presentedViewController !== originalSheet && originalSheet.view.window == nil
        }
        try await waitFor("actual Root empty view produces mounted proof and runtime HTTP", timeout: 10) {
            guard let mounted = try? native.unified.mountedAssociation() else { return false }
            return mounted.currentlyConfigured && mounted.entryID == nil && mounted.generationID == native.controller.emptyDisplayGeneration &&
                reportedEmptyGeneration == mounted.generationID && native.http.deliveryPaths.contains { $0.hasSuffix("/services/runtime-observations") }
        }
        XCTAssertNoThrow(try native.controller.requireExplicitConnectionCompletion(operationID: operation))
        XCTAssertEqual(human.cancellations, cancellations, "Verified connection completion preserves the native foreground authority")
        XCTAssertNotNil(human.coordinator.humanIdentity)
        XCTAssertFalse(nativeElements(hosting.view).contains { $0.accessibilityLabel == "Check for screens" })
        capture(window, name: "Prepared-Native-Root-Auto-Completion-And-Actual-Empty-Mount")
    }

    func testOnlyAutomaticEmptyWelcomeClosesWhenAssignedContentArrives() async throws {
        let state = NativeMenuFixtureState()
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), hosting = UIHostingController(rootView: NativeMenuDisplayFixture(state: state))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let automaticWelcome = try await presentedSettings(hosting, phase: "first empty automatic Welcome")
        _ = try await routeButton("Settings", in: automaticWelcome.view)
        state.rendered = true
        try await waitFor("assigned content closes only automatic Welcome") {
            hosting.presentedViewController == nil && automaticWelcome.view.window == nil
        }
        try await waitFor("assigned display appears") {
            self.nativeElements(hosting.view).contains { $0.accessibilityLabel == "Rendered Cloud screen" }
        }
        state.rendered = false; state.emptyGeneration = UUID(); state.installationID = UUID()
        let manual = try await presentedSettings(hosting, phase: "new installation automatic Welcome")
        try await activateButton("Settings", in: manual.view)
        _ = try await routeButton("Screenpunk Cloud", in: manual.view)
        // Entering Settings is an explicit choice even when its Welcome menu
        // was initially automatic. It must survive the next prepared display.
        state.rendered = true
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        repeat {
            XCTAssertTrue(hosting.presentedViewController === manual, "Assigned content must preserve explicitly opened Settings")
            try await Task.sleep(nanoseconds: 10_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        assertVisible(try await routeButton("Close", in: manual.view), in: window)
        capture(window, name: "Native-Assigned-Content-Preserves-User-Settings")
        try await activateButton("Close", in: manual.view)
        try await waitFor("manual Settings dismissal") { hosting.presentedViewController == nil && manual.view.window == nil }
    }

    func testNativeEmptyMenuOpensOnceAndRenderedDisplayRetainsStandardMenuEntry() async throws {
        let state = NativeMenuFixtureState()
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: NativeMenuDisplayFixture(state: state))
        window.frame = CGRect(x: 0, y: 0, width: 768, height: 1024)
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitFor("empty display standard menu") { hosting.presentedViewController?.transitionCoordinator == nil && hosting.presentedViewController != nil }
        let menu = try XCTUnwrap(hosting.presentedViewController)
        let settings = try await routeButton("Settings", in: menu.view)
        let close = try await routeButton("Close", in: menu.view)
        assertVisible(settings, in: window); assertVisible(close, in: window)
        capture(window, name: "Native-Empty-Standard-Welcome-768x1024")
        XCTAssertTrue(close.accessibilityActivate())
        try await waitFor("menu closes completely") {
            hosting.presentedViewController == nil && menu.view.window == nil && menu.transitionCoordinator == nil
        }
        state.emptyGeneration = UUID() // A status refresh can issue a new association while still empty.
        state.connection = .needsAttention
        try await assertRemainsDismissed(hosting)
        let controls = nativeElements(hosting.view)
        XCTAssertFalse(controls.contains { $0.accessibilityLabel == "Cloud account" || $0.accessibilityLabel == "Reset this device" })
        XCTAssertTrue(controls.contains { $0.accessibilityLabel == "Assign your first screen in Screenpunk Cloud." })
        XCTAssertFalse(controls.contains { $0.accessibilityLabel?.contains("Check for screens") == true })
        let action = try XCTUnwrap(controls.flatMap { $0.accessibilityCustomActions ?? [] }.first { $0.name == "Open Screenpunk menu" })
        XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action), "The supported accessibility entry reopens the same standard menu")
        let reopened = try await presentedSettings(hosting, phase: "manual accessibility menu reopen")
        try await activateButton("Close", in: reopened.view)
        try await waitFor("second close completely") {
            hosting.presentedViewController == nil && reopened.view.window == nil && reopened.transitionCoordinator == nil
        }
        state.rendered = true
        try await waitFor("actual rendered surface replaces empty display") {
            self.nativeElements(hosting.view).contains { $0.accessibilityLabel == "Rendered Cloud screen" }
        }
        try await assertRemainsDismissed(hosting)
        func gestures(_ view: UIView) -> [UILongPressGestureRecognizer] {
            (view.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer } ?? []) + view.subviews.flatMap(gestures)
        }
        XCTAssertTrue(gestures(hosting.view).contains { $0.numberOfTouchesRequired == 2 && $0.minimumPressDuration == 5 && $0.view?.window === window }, "The actual rendered surface retains the standard two-finger five-second recognizer")
        state.rendered = false; state.emptyGeneration = UUID()
        try await waitFor("empty display returns after rendered content") {
            self.nativeElements(hosting.view).contains { $0.accessibilityLabel == "Your screens" }
        }
        try await assertRemainsDismissed(hosting)
        capture(window, name: "Native-Later-Empty-Stays-Quiet")
        let returnedAction = try XCTUnwrap(nativeElements(hosting.view).flatMap { $0.accessibilityCustomActions ?? [] }.first { $0.name == "Open Screenpunk menu" })
        XCTAssertTrue(try XCTUnwrap(returnedAction.actionHandler)(returnedAction))
        let returnedMenu = try await presentedSettings(hosting, phase: "manual menu entry from later empty display")
        XCTAssertEqual(state.retryCalls, 0); XCTAssertEqual(state.logoutCalls, 0)
        try await activateButton("Close", in: returnedMenu.view)
        try await waitFor("final menu teardown") {
            hosting.presentedViewController == nil && returnedMenu.view.window == nil && returnedMenu.transitionCoordinator == nil
        }
    }

    func testExistingInstallationSettingsOpensWithoutHumanSessionOrEnrollment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-native-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try recordedController(directory: directory)
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let state = NativeMenuFixtureState()
        var factories = 0, enrollments = 0
        let journey = CloudEnrollmentAccountJourneyView(lifecycle: lifecycle, presentation: CloudProviderPresentation(),
            availability: .qualified, controller: controller, connect: { _, _, _ in enrollments += 1 },
            makeSession: { _ in factories += 1; throw CloudNativeIdentityError.notConfigured },
            connectedSettings: { AnyView(DeviceCloudMenuView(host: nil, cloud: state.content, page: .cloud, availableSize: CGSize(width: 768, height: 1024))) })
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), hosting = UIHostingController(rootView: NativeSettingsSheetFixture(content: journey))
        window.frame = CGRect(x: 0, y: 0, width: 768, height: 1024)
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let settings = try await presentedSettings(hosting)
        for title in ["Log out", "Reset this device", "Close"] { assertVisible(try await routeButton(title, in: settings.view), in: window) }
        XCTAssertTrue(nativeElements(settings.view).allSatisfy { !["Continue with Google", "Continue with Apple", "Connect device"].contains($0.accessibilityLabel ?? "") })
        XCTAssertFalse(nativeElements(settings.view).contains { $0.accessibilityLabel == "Check for screens" || $0.accessibilityLabel == "Retry connection" })
        XCTAssertEqual(factories, 0); XCTAssertEqual(enrollments, 0); XCTAssertNil(lifecycle.coordinator)
        XCTAssertTrue(controller.hasRecordedCloudInstallation)
        capture(window, name: "Native-Cloud-Settings-No-Human-Session-768x1024")
    }

    func testNativeSettingsRetryAndLogoutFailureKeepCurrentDeviceControls() async throws {
        let state = NativeMenuFixtureState(); state.connection = .needsAttention
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: NativeSettingsSheetFixture(content: NativeSettingsLiveFixture(state: state)))
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var settings = try await presentedSettings(hosting)
        let retry = try await routeButton("Retry connection", in: settings.view)
        XCTAssertTrue(visibleEnabledButtons(in: settings.view, window: window).contains { $0.accessibilityLabel == "Retry connection" }, "Positive control: the exposed enabled Retry exists before connecting")
        XCTAssertTrue(retry.accessibilityActivate())
        try await waitFor("native retry loading has no visible enabled retry action") {
            self.nativeElements(settings.view).contains { $0.accessibilityLabel == "Connecting to Cloud" } &&
                !self.visibleEnabledButtons(in: settings.view, window: window).contains { $0.accessibilityLabel == "Retry connection" || $0.accessibilityLabel == "Check for screens" }
        }
        XCTAssertEqual(state.retryCalls, 1)
        XCTAssertFalse(visibleEnabledButtons(in: settings.view, window: window).contains { $0.accessibilityLabel == "Retry connection" || $0.accessibilityLabel == "Check for screens" })
        capture(window, name: "Native-Cloud-Settings-Device-Only-Connecting-Landscape")
        state.connection = .connected
        try await activateButton("Log out", in: settings.view)
        try await waitFor("logout confirmation completely attached") {
            guard let confirmation = settings.presentedViewController else { return false }
            return !confirmation.isBeingPresented && confirmation.transitionCoordinator == nil && confirmation.view.window === window
        }
        let confirmation = try XCTUnwrap(settings.presentedViewController)
        let confirmedLogout = try await routeButton("Log out", in: confirmation.view)
        assertVisible(confirmedLogout, in: window)
        XCTAssertFalse(confirmedLogout.accessibilityTraits.contains(.notEnabled))
        capture(window, name: "Native-Cloud-Actual-Logout-Confirmation")
        var cancelled = false
        confirmation.dismiss(animated: false) { cancelled = true }
        try await waitFor("confirmation public cancellation") {
            cancelled && settings.presentedViewController == nil && confirmation.view.window == nil
        }
        XCTAssertEqual(state.logoutCalls, 0, "Presenting or cancelling confirmation must not disconnect")
        // Published failure rendering is ordinary in-process coverage. A separate
        // explicitly driven Simulator test below verifies the actual confirmation tap.
        state.logoutMessage = "The device could not log out. Try again."
        settings = try XCTUnwrap(hosting.presentedViewController)
        XCTAssertTrue(nativeElements(settings.view).contains { $0.accessibilityLabel == "Connected to Screenpunk Cloud" })
        XCTAssertFalse(nativeElements(settings.view).contains { $0.accessibilityLabel == "Check for screens" })
        try await waitFor("published logout failure reaches Settings accessibility") {
            self.nativeElements(settings.view).contains { $0.accessibilityLabel == state.logoutMessage }
        }
        XCTAssertTrue(nativeElements(settings.view).contains { $0.accessibilityLabel == state.logoutMessage })
        XCTAssertFalse(nativeElements(settings.view).contains { $0.accessibilityLabel?.hasPrefix("Continue with") == true })
        XCTAssertEqual(state.resetCalls, 0)
        capture(window, name: "Native-Cloud-Logout-Failure-Retryable-Settings")
    }

    /// Opt-in interactive qualification: the supported Simulator driver taps the
    /// actual native confirmation. Ordinary CI never waits for external input.
    func testExternalNativeLogoutConfirmationDispatchesActualEvent() async throws {
        guard ProcessInfo.processInfo.environment["SCREENPUNK_EXTERNAL_UI_CONFIRMATION"] == "1" else {
            throw XCTSkip("Requires the explicit external Simulator tap qualification driver")
        }
        let state = NativeMenuFixtureState()
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: NativeSettingsSheetFixture(content: NativeSettingsLiveFixture(state: state)))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let settings = try await presentedSettings(hosting)
        try await activateButton("Log out", in: settings.view)
        try await waitFor("external native confirmation attached") {
            guard let confirmation = settings.presentedViewController else { return false }
            return !confirmation.isBeingPresented && confirmation.transitionCoordinator == nil && confirmation.view.window === window
        }
        let confirmation = try XCTUnwrap(settings.presentedViewController)
        assertVisible(try await routeButton("Log out", in: confirmation.view), in: window)
        XCTAssertEqual(state.logoutCalls, 0)
        capture(window, name: "External-Native-Logout-Ready-For-Actual-Tap")
        print("SCREENPUNK_EXTERNAL_LOGOUT_CONFIRMATION_READY")
        try await waitFor("actual Simulator confirmation event callback", timeout: 30) { state.logoutCalls == 1 }
        try await waitFor("native confirmation dismisses after actual event") {
            settings.presentedViewController == nil && confirmation.view.window == nil
        }
        XCTAssertEqual(state.logoutCalls, 1)
        XCTAssertEqual(state.retryCalls, 0); XCTAssertEqual(state.resetCalls, 0)
        XCTAssertTrue(nativeElements(settings.view).contains { $0.accessibilityLabel == "Connected to Screenpunk Cloud" })
        XCTAssertFalse(nativeElements(settings.view).contains { $0.accessibilityLabel == "Check for screens" })
        XCTAssertTrue(nativeElements(settings.view).contains { $0.accessibilityLabel == state.logoutMessage })
        capture(window, name: "External-Native-Logout-Actual-Tap-Delivered")
    }

    func testNativeSettingsPendingLogoutOffersOnlyExistingCleanupRetry() async throws {
        let state = NativeMenuFixtureState()
        state.connection = .needsAttention; state.cloudLogoutCleanupPending = true
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: NativeSettingsSheetFixture(content: NativeSettingsLiveFixture(state: state)))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let settings = try await presentedSettings(hosting)
        let reconnect = try await routeButton("Retry connection", in: settings.view)
        XCTAssertTrue(reconnect.accessibilityTraits.contains(.notEnabled), "A revoked device must not retry using the retired Cloud credential")
        let retryLogout = try await routeButton("Retry log out", in: settings.view)
        XCTAssertFalse(retryLogout.accessibilityTraits.contains(.notEnabled))
        assertVisible(retryLogout, in: window)
        XCTAssertTrue(retryLogout.accessibilityActivate())
        try await waitFor("same logout cleanup callback") { state.logoutCalls == 1 }
        XCTAssertEqual(state.retryCalls, 0); XCTAssertEqual(state.resetCalls, 0)
        XCTAssertTrue(state.cloudLogoutCleanupPending, "A failed cleanup remains actionable in the same Settings")
        XCTAssertNotNil(hosting.presentedViewController)
        _ = try await routeButton("Retry log out", in: settings.view)
        XCTAssertFalse(nativeElements(settings.view).contains { $0.accessibilityLabel?.hasPrefix("Continue with") == true })
        capture(window, name: "Native-Cloud-Settings-Pending-Logout-Cleanup")
    }

    func testFreshJourneyDoesNotSwitchToSettingsWhenInstallationBecomesRecorded() async throws {
        let fixture = RouteJourneyFixture(realPresentation: true)
        await fixture.transport.setAccounts(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-fresh-presentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = NativeJourneyModeFixtureState(controller: NativeEnrollmentSceneController(testIntentJournal: NativeEnrollmentIntentJournal(directory: directory)))
        let scene = try foregroundScene(), previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), hosting = UIHostingController(rootView: NativeSettingsSheetFixture(content: NativeJourneyModeFixture(state: route, fixture: fixture)))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); fixture.actions.cancel(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let panel = try await presentedSettings(hosting)
        try await activateButton("Continue with Google", in: panel.view)
        _ = try await routeButton("Connect device", in: panel.view)
        let session = fixture.lifecycle.coordinator, cancellations = fixture.cancellations
        route.controller = try recordedController(directory: directory)
        // Replace the observed value at the activation boundary without changing the
        // mounted presentation identity. This isolates the presentation lifetime;
        // controller/HTTP/mount completion is qualified by its real authority tests.
        _ = try await routeButton("Connect device", in: panel.view)
        XCTAssertFalse(nativeElements(panel.view).contains { $0.accessibilityLabel == "Existing installation Settings" })
        XCTAssertEqual(fixture.cancellations, cancellations)
        XCTAssertTrue(fixture.lifecycle.coordinator === session)
        XCTAssertNotNil(fixture.coordinator.humanIdentity)
        try await activateButton("Close", in: panel.view)
        try await waitFor("explicit close still dismisses and revokes") { hosting.presentedViewController == nil && fixture.cancellations == cancellations + 1 }
    }
    private func activateButton(_ label: String, in view: UIView) async throws {
        let button = try await routeButton(label, in: view)
        let activated = button.accessibilityActivate()
        if !activated {
            let details = XCTAttachment(string: "type=\(type(of: button)) label=\(button.accessibilityLabel ?? "nil") traits=\(button.accessibilityTraits.rawValue) frame=\(button.accessibilityFrame) window=\(view.window != nil)")
            details.name = "Unactivated-" + label; details.lifetime = .keepAlways; add(details)
            if let window = view.window { capture(window, name: "Unactivated-" + label) }
        }
        XCTAssertTrue(activated, "Actual mounted button: " + label)
    }
    private func visibleEnabledButtons(in view: UIView, window: UIWindow) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        func exposed(_ object: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(object)).inserted, !object.accessibilityElementsHidden else { return [] }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0.01 || view.window == nil { return [] }
            // Read the exposed accessibility container rather than all retained
            // UIKit subviews. Form can keep obsolete row views after deletion.
            var children = object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
            if #available(iOS 17, *) { children += object.automationElements?.compactMap { $0 as? NSObject } ?? [] }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1_000 { children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject } }
            return [object] + children.flatMap(exposed)
        }
        return exposed(view).filter { element in
            let rect = window.convert(element.accessibilityFrame, from: nil)
            return element.accessibilityTraits.contains(.button) && !element.accessibilityTraits.contains(.notEnabled) &&
                !rect.isEmpty && window.bounds.insetBy(dx: -1, dy: -1).contains(rect)
        }
    }
    private func foregroundScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
    }
    private func nativeElements(_ view: UIView) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []; return routeAccessibilityElements(view, visited: &visited)
    }
    private func presentedSettings<Content: View>(_ hosting: UIHostingController<Content>, phase: String = "presented standard menu") async throws -> UIViewController {
        do {
            try await waitFor(phase + " settled") {
                guard let presented = hosting.presentedViewController else { return false }
                return !presented.isBeingPresented && presented.transitionCoordinator == nil && presented.view.window != nil
            }
        } catch {
            let presented = hosting.presentedViewController
            let details = "phase=\(phase) presented=\(presented.map { String(describing: type(of: $0)) } ?? "nil") presenting=\(presented?.isBeingPresented ?? false) dismissing=\(presented?.isBeingDismissed ?? false) transition=\(presented?.transitionCoordinator != nil) window=\(presented?.viewIfLoaded?.window != nil)"
            let attachment = XCTAttachment(string: details); attachment.name = "Menu-Presentation-State"; attachment.lifetime = .keepAlways; add(attachment)
            if let window = hosting.view.window { capture(window, name: "Menu-Presentation-Timeout-" + phase) }
            throw error
        }
        return try XCTUnwrap(hosting.presentedViewController)
    }
    private func assertRemainsDismissed<Content: View>(_ hosting: UIHostingController<Content>) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 0.25
        repeat { await Task.yield(); XCTAssertNil(hosting.presentedViewController); try await Task.sleep(nanoseconds: 10_000_000) } while ProcessInfo.processInfo.systemUptime < until
    }
    private func recordedController(directory: URL) throws -> NativeEnrollmentSceneController {
        let journal = NativeEnrollmentIntentJournal(directory: directory)
        let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Office display", profile: "iPad", origin: URL(string: "https://fixture.invalid")!, viewport: CGSize(width: 768, height: 1024))
        try journal.saveOriginal(intent); try journal.markRecordedInstallation(intent)
        return NativeEnrollmentSceneController(testIntentJournal: journal)
    }
    func testSavedEnrollmentUsesWelcomeProviderHandoffAndPreservesOriginalOnClose() async throws {
        try await assertWelcomeProviderHandoff(savedIntent: true)
    }
    func testFreshWelcomeOAuthAndConnectDispatchesControllerBeforePrivateEffects() async throws {
        try await assertWelcomeProviderHandoff(savedIntent: false)
    }
    private func assertWelcomeProviderHandoff(savedIntent: Bool) async throws {
        let fixture = RouteJourneyFixture(realPresentation: true)
        fixture.holdAuthentication = true
        await fixture.transport.setAccounts(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-recovery-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NativeEnrollmentIntentJournal(directory: directory)
        let intent = try NativeEnrollmentIntentRecord(accountID: RouteJourneyTransport.accountID, locationID: nil,
            name: "Original recovery device", profile: "iPad", origin: URL(string: "https://fixture.invalid")!,
            viewport: CGSize(width: 768, height: 1024))
        if savedIntent { try journal.saveOriginal(intent) }
        let originalURL = directory.appendingPathComponent("original.json")
        let originalBytes = savedIntent ? try Data(contentsOf: originalURL) : nil
        let controller = NativeEnrollmentSceneController(testIntentJournal: journal)
        XCTAssertEqual(controller.hasUnfinishedCloudEnrollment, savedIntent)
        let route = WelcomeRootPresentationState()
        let bootstrap = DeviceManagementBootstrap() // Inert: no owner, startup, credentials, or transports.
        var dispatched: [(UUID, UUID?, String)] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let hosting = UIHostingController(rootView: WelcomeRootPresentationFixture(route: route, fixture: fixture, controller: controller,
            connect: { account, location, name in
                guard !savedIntent else { return XCTFail("Provider handoff must not enroll implicitly") }
                dispatched.append((account, location, name))
                controller.enroll(lifecycle: fixture.lifecycle, bootstrap: bootstrap, accountID: account,
                    locationID: location, name: name, viewport: CGSize(width: 768, height: 1024))
            }))
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let cleanup: () async throws -> Void = {
            fixture.holdAuthentication = false
            fixture.actions.cancel()
            let continuation = fixture.authenticationContinuation; fixture.authenticationContinuation = nil
            continuation?.resume()
            try await self.waitFor("recovery authentication drain") { !fixture.coordinator.isWorking }
        }
        do {
            let cloud = try await routeButton("Screenpunk Cloud", in: hosting.view)
            var initialVisited: Set<ObjectIdentifier> = []
            let initialButtons = routeAccessibilityElements(hosting.view, visited: &initialVisited).filter { $0.accessibilityTraits.contains(.button) }
            XCTAssertEqual(initialButtons.count, 2, "Fresh and saved setup use the established Cloud and Local Welcome choices")
            _ = try await routeButton("Local Screenpunk", in: hosting.view)
            capture(window, name: savedIntent ? "Saved-Welcome" : "Fresh-Welcome")
            assertVisible(cloud, in: window)
            XCTAssertTrue(cloud.accessibilityActivate())
            try await waitFor("actual recovery presentation") {
                guard let presented = hosting.presentedViewController else { return false }
                return !presented.isBeingPresented && presented.transitionCoordinator == nil
            }
            let journey = try XCTUnwrap(hosting.presentedViewController)
            let google = try await routeButton("Continue with Google", in: journey.view)
            capture(window, name: savedIntent ? "Saved-Cloud-Providers" : "Fresh-Cloud-Providers")
            assertVisible(google, in: window)
            XCTAssertTrue(google.accessibilityActivate())
            try await waitFor("held provider authentication") { fixture.authenticationContinuation != nil }
            XCTAssertEqual(fixture.lifecycle.accountEntryState, .ownedHere)
            let session = fixture.lifecycle.coordinator
            let presenter = try fixture.presentation.resolve().controller
            XCTAssertTrue(presenter === journey, "Use the actual attached journey's presentation anchor")
            let provider = UIViewController(); provider.modalPresentationStyle = .fullScreen
            var covered = false; presenter.present(provider, animated: false) { covered = true }
            try await waitFor("provider handoff") { covered }
            let cancellations = fixture.cancellations
            route.branch = .checking
            await Task.yield()
            route.branch = .runtime
            await Task.yield()
            var uncovered = false; provider.dismiss(animated: false) { uncovered = true }
            try await waitFor("provider return") { uncovered }
            XCTAssertTrue(hosting.presentedViewController === journey, "Recovery journey must retain its modal owner across root replacement")
            XCTAssertNotNil(route.sheet)
            XCTAssertEqual(fixture.cancellations, cancellations)
            XCTAssertTrue(fixture.lifecycle.coordinator === session)
            fixture.holdAuthentication = false
            let continuation = fixture.authenticationContinuation; fixture.authenticationContinuation = nil
            continuation?.resume()
            try await waitFor("workspace and Unassigned discovery after handoff") {
                fixture.coordinator.humanIdentity != nil && fixture.coordinator.selectedAccountID == intent.accountID && !fixture.coordinator.isWorking
            }
            let connect = try await routeButton("Connect device", in: journey.view)
            XCTAssertFalse(connect.accessibilityTraits.contains(.notEnabled))
            assertVisible(connect, in: window)
            XCTAssertEqual(try journal.load(), savedIntent ? intent : nil)
            XCTAssertEqual(try? Data(contentsOf: originalURL), originalBytes)
            capture(window, name: savedIntent ? "Saved-Cloud-Confirmation" : "Fresh-Cloud-Confirmation")
            XCTAssertTrue(dispatched.isEmpty, "Neither Welcome nor provider return may connect implicitly")
            if !savedIntent {
                XCTAssertTrue(connect.accessibilityActivate(), "Dispatch the actual mounted Connect button")
                try await waitFor("real controller admission boundary") { controller.state == .needsAttention }
                XCTAssertEqual(dispatched.count, 1)
                XCTAssertEqual(dispatched.first?.0, intent.accountID)
                XCTAssertNil(dispatched.first?.1, "Fresh location remains Unassigned")
                XCTAssertEqual(dispatched.first?.2, controller.suggestedDeviceName)
                XCTAssertFalse(try XCTUnwrap(dispatched.first?.2).isEmpty)
                XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .authority)
                XCTAssertEqual(controller.enrollmentDiagnostic?.category, .localState)
                XCTAssertNil(bootstrap.currentAuthority)
                XCTAssertEqual(bootstrap.startupAttempt, 0)
                XCTAssertNil(try journal.load(), "This UI dispatch fixture stops before any private effects or saved original")
                var visibleError: NSObject?
                try await waitFor("mounted real controller error") {
                    var visited: Set<ObjectIdentifier> = []
                    visibleError = self.routeAccessibilityElements(journey.view, visited: &visited).first {
                        $0.accessibilityLabel == controller.deliveryMessage
                    }
                    return visibleError != nil
                }
                assertVisible(try XCTUnwrap(visibleError), in: window)
                capture(window, name: "Fresh-Cloud-Connect-Dispatch-BeforePrivateEffects")
            }
            let close = try await routeButton("Close", in: journey.view)
            assertVisible(close, in: window)
            XCTAssertTrue(close.accessibilityActivate())
            try await waitFor("real Close dismissal") { hosting.presentedViewController == nil && route.sheet == nil }
            XCTAssertEqual(fixture.cancellations, cancellations + 1)
            XCTAssertNil(fixture.coordinator.humanIdentity)
            XCTAssertEqual(try? Data(contentsOf: originalURL), originalBytes)
        } catch {
            try await cleanup(); throw error
        }
    }
    private func assertVisible(_ element: NSObject, in window: UIWindow, file: StaticString = #filePath, line: UInt = #line) {
        let rect = window.convert(element.accessibilityFrame, from: nil)
        XCTAssertFalse(rect.isEmpty, file: file, line: line)
        XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Required control must be fully visible: \(element.accessibilityLabel ?? "")", file: file, line: line)
    }
    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func routeButton(_ label: String, in view: UIView) async throws -> NSObject {
        var found: NSObject?
        try await waitFor("actual button: " + label) {
            var visited: Set<ObjectIdentifier> = []
            found = self.routeAccessibilityElements(view, visited: &visited).first {
                $0.accessibilityLabel?.hasPrefix(label) == true && $0.accessibilityTraits.contains(.button)
            }
            return found != nil
        }
        return try XCTUnwrap(found)
    }
    private func routeAccessibilityElements(_ object: NSObject, visited: inout Set<ObjectIdentifier>) -> [NSObject] {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
        var children = (object as? UIView)?.subviews.map { $0 as NSObject } ?? []
        if #available(iOS 17, *) { children += object.automationElements?.compactMap { $0 as? NSObject } ?? [] }
        children += object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
        let count = object.accessibilityElementCount()
        if count > 0 && count < 1_000 { children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject } }
        return [object] + children.flatMap { routeAccessibilityElements($0, visited: &visited) }
    }
    func testPhoneOnboardingOrientationLeasesOverlapAndRestoreOnlyTheirWindow() throws {
        let policy = ScreenpunkOnboardingOrientationPolicy()
        let phoneWindow = UIWindow(), otherWindow = UIWindow()
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .phone), .allButUpsideDown)
        let welcome = try XCTUnwrap(policy.acquire(window: phoneWindow, idiom: .phone, requestRotation: false))
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .phone), .portrait)
        XCTAssertEqual(policy.supportedOrientations(window: otherWindow, idiom: .phone), .allButUpsideDown)
        let cloud = try XCTUnwrap(policy.acquire(window: phoneWindow, idiom: .phone, requestRotation: false))
        policy.release(welcome, notify: false)
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .phone), .portrait)
        policy.release(cloud, notify: false)
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .phone), .allButUpsideDown)
        let reopenedWelcome = try XCTUnwrap(policy.acquire(window: phoneWindow, idiom: .phone, requestRotation: false))
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .phone), .portrait)
        policy.release(reopenedWelcome, notify: false)
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .phone), .allButUpsideDown)
        XCTAssertNil(policy.acquire(window: phoneWindow, idiom: .pad, requestRotation: false))
        XCTAssertEqual(policy.supportedOrientations(window: phoneWindow, idiom: .pad), .all)
    }
    func testSceneEnrollmentPresentationIncludesDetectedMetadataWithoutCreatingSession() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-scene-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = NativeEnrollmentSceneController(intentJournal: NativeEnrollmentIntentJournal(directory: parent))
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let actions = CloudAccountJourneyActions.enrollment(lifecycle: lifecycle, presentation: CloudProviderPresentation(),
            availability: .qualified, controller: controller, connect: { _, _, _ in XCTFail("Rendering must not connect") })
        XCTAssertEqual(actions.suggestedDeviceName, controller.suggestedDeviceName)
        XCTAssertFalse(try XCTUnwrap(actions.suggestedDeviceName).isEmpty)
        XCTAssertEqual(actions.deviceProfile, NativeEnrollmentDeviceType.currentProfile())
        XCTAssertEqual(actions.enrollmentProgressMessage, controller.enrollmentProgressMessage)
        XCTAssertEqual(actions.deliveryMessage, controller.deliveryMessage)
        XCTAssertNil(lifecycle.coordinator)
    }
    func testSceneEnrollmentPresentationPreservesRetainedWorkspaceAndNullLocation() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-scene-retained-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent)
        let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Original device", profile: "iPad",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 768, height: 1024))
        try journal.saveOriginal(intent)
        let controller = NativeEnrollmentSceneController(intentJournal: journal)
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        var captured: (UUID, UUID?, String)?
        let actions = CloudAccountJourneyActions.enrollment(lifecycle: lifecycle, presentation: CloudProviderPresentation(),
            availability: .qualified, controller: controller, connect: { captured = ($0, $1, $2) })
        XCTAssertEqual(actions.retainedAccountID, intent.accountID)
        XCTAssertNil(actions.retainedLocationID)
        XCTAssertEqual(actions.retainedDeviceName, intent.name)
        XCTAssertEqual(actions.deviceProfile, intent.profile)
        actions.connectDevice(accountID: intent.accountID, locationID: UUID(), name: "A newer editable name")
        XCTAssertEqual(captured?.0, intent.accountID)
        XCTAssertNil(captured?.1)
        XCTAssertEqual(captured?.2, intent.name)
        XCTAssertNil(lifecycle.coordinator)
    }
    func testMissingConfigurationIsUnavailableWithoutSessionFactory() {
        var validations = 0
        let sheet = CloudAccountSheet.requested(configuration: {
            validations += 1; throw CloudNativeIdentityError.notConfigured
        })
        guard case .unavailable(let message) = sheet.availability else { return XCTFail() }
        XCTAssertEqual(validations, 1)
        XCTAssertTrue(message.contains("not configured"))
    }
    func testCompleteConfigurationQualifiesOnlyHumanPresentation() throws {
        let client = "fixture.apps.googleusercontent.com", callback = "com.googleusercontent.apps.fixture"
        let info: [String: Any] = ["ScreenpunkCloudFirebaseProjectID": "fixture",
            "ScreenpunkCloudFirebaseAPIKey": "fixture-key", "ScreenpunkCloudFirebaseAppID": "1:123:ios:fixture",
            "ScreenpunkCloudFirebaseSenderID": "123", "ScreenpunkCloudGoogleClientID": client,
            "ScreenpunkCloudGoogleCallbackScheme": callback, "ScreenpunkCloudBundleID": "xyz.screenpunk.fixture",
            "ScreenpunkCloudAPIOrigin": "https://fixture.invalid", "CFBundleURLTypes": [["CFBundleURLName": "Screenpunk Cloud OAuth", "CFBundleURLSchemes": [callback]]]]
        let sheet = CloudAccountSheet.requested(configuration: { try CloudNativeConfiguration.load(info: info, bundleID: "xyz.screenpunk.fixture") })
        guard case .qualified = sheet.availability else { return XCTFail() }
        // No production session factory, SDK, network or enrollment is invoked.
    }
    private func waitFor(_ event: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard condition() else {
            XCTFail("Timed out waiting for " + event)
            throw NSError(domain: "CloudRouteHostedFixture", code: 1)
        }
    }
    func testHostedProviderCoverPreservesFlowButJourneyDismissalCancels() async throws {
        let fixture = RouteJourneyFixture(); fixture.holdAuthentication = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController(), window = UIWindow(windowScene: scene)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let hosting = UIHostingController(rootView: fixture.view); hosting.modalPresentationStyle = .fullScreen
        var presented = false
        root.present(hosting, animated: false) { presented = true }
        try await waitFor("journey presentation completion") { presented }
        let task = try fixture.actions.signIn(.google)
        // Register cleanup immediately: it covers late authentication entry and
        // every timeout/unwrap/error after task creation, not only a captured hold.
        let cleanup: () async throws -> Void = {
            fixture.holdAuthentication = false // BEFORE cancel or resuming a hold.
            fixture.actions.cancel()
            let continuation = fixture.authenticationContinuation
            fixture.authenticationContinuation = nil; continuation?.resume()
            var settled = false
            let monitor = Task { await task?.value; settled = true }
            do { try await self.waitFor("authentication cleanup settlement") { settled } }
            catch { monitor.cancel(); throw error }
            await monitor.value
        }
        do {
            try await waitFor("held fake authentication") { fixture.authenticationContinuation != nil }
            let before = fixture.cancellations
            let provider = UIViewController(); provider.modalPresentationStyle = .fullScreen
            var covered = false
            hosting.present(provider, animated: false) { covered = true }
            try await waitFor("provider presentation completion") { covered }
            XCTAssertEqual(fixture.cancellations, before)
            XCTAssertTrue(fixture.coordinator.isWorking)
            var uncovered = false
            provider.dismiss(animated: false) { uncovered = true }
            try await waitFor("provider dismissal completion") { uncovered }
            XCTAssertEqual(fixture.cancellations, before)
            var dismissed = false
            hosting.dismiss(animated: false) { dismissed = true }
            try await waitFor("journey dismissal completion") { dismissed }
            XCTAssertEqual(fixture.cancellations, before + 1)
            try await cleanup()
            XCTAssertNil(fixture.coordinator.humanIdentity)
        } catch {
            do { try await cleanup() }
            catch { XCTFail("Authentication cleanup did not settle: fixture remains unqualified") }
            throw error
        }
    }

}

@MainActor
private final class RouteJourneyFixture {
    let lifecycle: CloudHumanSessionLifecycle
    let journal = RouteJourneyJournal()
    private let accountID: UUID
    lazy var transport = RouteJourneyTransport(accountID: accountID)
    let availability: CloudJourneyAvailability
    private(set) var factories = 0, presentations = 0
    private(set) var providers: [CloudNativeSignInProvider] = []
    var holdAuthentication = false
    var authenticationContinuation: CheckedContinuation<Void, Never>?
    var cancellations = 0
    var holdSignOut = false
    var signOutContinuation: CheckedContinuation<Void, Error>?
    private let realPresentation: Bool
    lazy var presentation: CloudProviderPresentation = {
        if realPresentation { return CloudProviderPresentation() }
        return CloudProviderPresentation(testResolve: { [weak self] in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        self.presentations += 1; return .init(controller: UIViewController(), window: UIWindow())
        })
    }()
    lazy var coordinator = CloudConnectionCoordinator(authenticate: { [weak self] provider in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        _ = try self.presentation.resolve(); self.providers.append(provider)
        if self.holdAuthentication { await withCheckedContinuation { self.authenticationContinuation = $0 } }
        return RouteJourneyTokens()
    }, cancelIdentityFlow: { [weak self] in self?.cancellations += 1 }, signOutIdentity: { [weak self] in
        guard let self else { return }
        if self.holdSignOut { try await withCheckedThrowingContinuation { self.signOutContinuation = $0 } }
    }, makeClient: { [weak self] tokens in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        return try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: tokens, transport: self.transport)
    }, journal: journal)
    init(availability: CloudJourneyAvailability = .qualified, broker: CloudHumanSessionBroker? = nil, realPresentation: Bool = false,
         accountID: UUID = RouteJourneyTransport.accountID) {
        self.realPresentation = realPresentation; self.availability = availability; self.accountID = accountID
        lifecycle = CloudHumanSessionLifecycle(broker: broker ?? CloudHumanSessionBroker())
    }
    var actions: CloudAccountJourneyActions {
        .init(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: { _ in
            self.factories += 1; return CloudHumanSession(testCoordinator: self.coordinator, testCallback: { _ in false })
        })
    }
    var view: CloudAccountJourneyView {
        .init(lifecycle: lifecycle, presentation: presentation, availability: availability, makeSession: { _ in
            self.factories += 1; return CloudHumanSession(testCoordinator: self.coordinator, testCallback: { _ in false })
        })
    }
    func finishSignOut(failed: Bool) {
        let continuation = signOutContinuation; signOutContinuation = nil
        if failed { continuation?.resume(throwing: CloudNativeIdentityError.providerFailed) } else { continuation?.resume() }
    }
}
@MainActor
private final class RouteJourneyJournal: CloudWorkspaceSetupJournal {
    var record: CloudWorkspaceSetupJournalRecord?
    private var attempt: CloudWorkspaceSetupJournalRecord?
    var failSaveNumber = 0
    private var saves = 0
    func load() throws -> CloudWorkspaceSetupJournalRecord? { if attempt != nil { throw CocoaError(.fileWriteUnknown) }; return record }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws {
        saves += 1; attempt = record
        if saves == failSaveNumber { throw CocoaError(.fileWriteUnknown) }
        self.record = record; attempt = nil
    }
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws { try save(record) }
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord {
        let target = try XCTUnwrap(attempt)
        guard target.userID == expectedUserID else { throw CocoaError(.fileWriteUnknown) }
        record = target; attempt = nil; return target
    }
}
private struct RouteJourneyTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "fixture-token" } }
private actor RouteJourneyTransport: HTTPTransport {
    static let accountID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let selectedAccountID: UUID
    init(accountID: UUID = RouteJourneyTransport.accountID) { selectedAccountID = accountID }
    private var failure: Int?
    private var hasAccounts = false
    private(set) var posts: [CloudNativeWorkspaceSetupRequest] = []
    private(set) var lookups: [UUID] = []
    func setFailure(_ status: Int?) { failure = status }
    func setAccounts(_ value: Bool) { hasAccounts = value }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        let path = request.url.path
        if path == "/v1/native/sign-in" {
            return .init(status: 200, body: Data(#"{"user":{"id":"22222222-2222-4222-8222-222222222222","displayName":"Fixture person","email":null},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#.utf8))
        }
        if path == "/v1/native/accounts" {
            let body = (hasAccounts ? #"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Fixture workspace","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"owner":true,"administrator":true,"canEnroll":true}}],"nextCursor":null}"# : #"{"items":[],"nextCursor":null}"#)
                .replacingOccurrences(of: Self.accountID.uuidString.lowercased(), with: selectedAccountID.uuidString)
            return .init(status: 200, body: Data(body.utf8))
        }
        if path.hasSuffix("/locations") { return .init(status: 200, body: Data(#"{"items":[{"id":"33333333-3333-4333-8333-333333333333","name":"Fixture location","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"canView":true,"canOperate":false,"canEnroll":false}}],"nextCursor":null}"#.utf8)) }
        let id: UUID
        if request.method == "POST" {
            let setup = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(request.body)); posts.append(setup); id = setup.requestId
        } else { id = try XCTUnwrap(UUID(uuidString: request.url.lastPathComponent)); lookups.append(id) }
        if let failure { return .init(status: failure, body: Data(#"{"code":"workspace_setup_unavailable","message":"raw-fixture-diagnostic","requestId":"trace-fixture"}"#.utf8)) }
        return .init(status: 200, body: Data("{\"requestId\":\"\(id.uuidString)\",\"accountId\":\"11111111-1111-4111-8111-111111111111\",\"locationId\":\"33333333-3333-4333-8333-333333333333\",\"createdAt\":\"2026-10-02T16:00:00Z\"}".utf8))
    }
}

@MainActor
private final class WelcomeRootPresentationState: ObservableObject {
    enum Branch { case blocked, checking, runtime }
    @Published var branch = Branch.blocked
    @Published var sheet: CloudAccountSheet?
}

private struct WelcomeRootPresentationFixture: View {
    @ObservedObject var route: WelcomeRootPresentationState
    let fixture: RouteJourneyFixture
    let controller: NativeEnrollmentSceneController
    let connect: (UUID, UUID?, String) -> Void
    var body: some View {
        CloudSceneAccountPresentationRoot(item: $route.sheet) {
            Group {
                switch route.branch {
                case .blocked:
                    DeviceOnboardingWelcomeView(cloud: { route.sheet = .init(availability: .qualified) },
                        local: { route.branch = .checking })
                case .checking: ProgressView("Checking retained startup")
                case .runtime: Color.black.ignoresSafeArea()
                }
            }
        } journey: { sheet in
            CloudEnrollmentAccountJourneyView(lifecycle: fixture.lifecycle, presentation: fixture.presentation,
                availability: sheet.availability, controller: controller, connect: connect,
                makeSession: { _ in CloudHumanSession(testCoordinator: fixture.coordinator, testCallback: { _ in false },
                    testEnrollmentTokens: { RouteJourneyTokens() }) })
        }
    }
}

@MainActor
private final class NativeMenuFixtureState: ObservableObject {
    @Published var connection = NativeEnrollmentSceneController.CloudConnectionState.connected
    @Published var emptyGeneration = UUID()
    @Published var rendered = false
    @Published var logoutMessage: String?
    @Published var cloudLogoutCleanupPending = false
    @Published var installationID = UUID()
    var retryCalls = 0, logoutCalls = 0, resetCalls = 0
    var content: DeviceCloudMenuContent {
        .init(deviceName: "Office display", connectionDescription: CloudDeviceSettingsContent.description(connection), screenSummary: "No screens installed", screenCount: 0,
            settings: NativeSettingsLiveFixture(state: self, embedded: true), screens: CloudDeviceScreensView(inventory: .available([], selected: nil)))
    }
}
private struct NativeMenuDisplayFixture: View {
    @ObservedObject var state: NativeMenuFixtureState
    var body: some View {
        DeviceCloudDisplayView(host: nil, cloud: state.content, installationIdentity: state.installationID,
            emptyGeneration: state.emptyGeneration, hasDisplayContent: state.rendered) {
                Color.black.overlay(Text("Rendered Cloud screen").foregroundStyle(.white))
            }
    }
}
private struct NativeSettingsLiveFixture: View {
    @ObservedObject var state: NativeMenuFixtureState
    var embedded = false
    var settings: some View {
        CloudDeviceSettingsContent(state: state.connection, deviceName: "Office display", cloudLogoutCleanupPending: state.cloudLogoutCleanupPending, disconnectMessage: state.logoutMessage, canReset: true,
            retry: { state.retryCalls += 1; state.connection = .connecting },
            logOut: { state.logoutCalls += 1; state.logoutMessage = "The device could not log out. Try again." }, reset: { state.resetCalls += 1 })
    }
    var body: some View {
        if embedded { settings }
        else { DeviceCloudMenuView(host: nil, cloud: state.content, page: .cloud, availableSize: CGSize(width: 1024, height: 768)) }
    }
}
private struct NativeSettingsSheetFixture<Content: View>: View {
    let content: Content
    @State private var open = false
    var body: some View { Color.black.onAppear { open = true }.sheet(isPresented: $open) { content } }
}
@MainActor
private final class NativeJourneyModeFixtureState: ObservableObject {
    @Published var controller: NativeEnrollmentSceneController
    init(controller: NativeEnrollmentSceneController) { self.controller = controller }
}
private struct NativeJourneyModeFixture: View {
    @ObservedObject var state: NativeJourneyModeFixtureState
    let fixture: RouteJourneyFixture
    var body: some View {
        CloudEnrollmentAccountJourneyView(lifecycle: fixture.lifecycle, presentation: fixture.presentation, availability: .qualified,
            controller: state.controller, connect: { _, _, _ in },
            makeSession: { _ in CloudHumanSession(testCoordinator: fixture.coordinator, testCallback: { _ in false }, testEnrollmentTokens: { RouteJourneyTokens() }) },
            connectedSettings: { AnyView(Text("Existing installation Settings")) })
    }
}
