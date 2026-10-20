import XCTest
import SwiftUI
import UIKit
import ScreenpunkCore
@_spi(NativeInstallation) import ScreenpunkApple
@testable import Screenpunk

@MainActor
final class CloudAccountJourneyTests: XCTestCase {
    func testPresentedExplicitConnectionCompletionDismissesOnlyOriginatingAttempt() async throws {
        let fixture = JourneyFixture()
        await fixture.transport.setEnrollmentChoices(workspaces: 1, locations: 0)
        await (try fixture.actions.signIn(.google))?.value
        await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
        let completion = JourneyConnectionCompletionState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: JourneyActualSheetFixture(
            journey: JourneyConnectionCompletionFixture(fixture: fixture, completion: completion),
            dynamicTypeSize: .large, recordBounds: { _, _ in }))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let connect = try await waitForJourneyElement("cloud.connectDevice", label: "Connect device", hosting: hosting)
        let cancellations = fixture.cancellations
        XCTAssertTrue(connect.accessibilityActivate())
        let first = try XCTUnwrap(completion.admitted)
        completion.state = .needsAttention; completion.message = "Fixture delivery failed."
        _ = try await waitForJourneyElement("cloud.enrollmentError", label: "Fixture delivery failed.", hosting: hosting)
        XCTAssertNotNil(hosting.presentedViewController, "A failed attempt must retain its panel and visible error")
        let retry = try await waitForJourneyElement("cloud.connectDevice", label: "Connect device", hosting: hosting)
        XCTAssertTrue(retry.accessibilityActivate())
        let second = try XCTUnwrap(completion.admitted); XCTAssertNotEqual(first, second)
        completion.state = .currentInstallation; completion.completed = first
        _ = try await waitForJourneyElement("cloud.enrollmentProgress", label: "Connecting device…", hosting: hosting)
        XCTAssertNotNil(hosting.presentedViewController, "An earlier attempt cannot dismiss a later attempt")
        XCTAssertEqual(completion.verifications, 0)
        let renderedDeadline = ProcessInfo.processInfo.systemUptime + 5
        while (completion.renderedIntentID != second || completion.renderedState != .currentInstallation) &&
                ProcessInfo.processInfo.systemUptime < renderedDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completion.renderedIntentID, second, "The actual mounted sheet must retain its admitted operation")
        XCTAssertEqual(completion.renderedState, .currentInstallation)
        completion.confirmed = second; completion.completed = second
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while hosting.presentedViewController != nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(completion.renderedCompletionID, second, "The live presented child must receive the matching typed completion")
        XCTAssertNil(hosting.presentedViewController, "Only this sheet's verified explicit completion dismisses it")
        XCTAssertEqual(completion.verifications, 1)
        guard hosting.presentedViewController == nil else { throw NSError(domain: "CloudJourneyCompletionFixture", code: 1) }
        XCTAssertEqual(fixture.cancellations, cancellations, "Successful completion preserves the established foreground session")
        let reopened = UIHostingController(rootView: JourneyActualSheetFixture(
            journey: JourneyConnectionCompletionFixture(fixture: fixture, completion: completion),
            dynamicTypeSize: .large, recordBounds: { _, _ in }))
        defer { reopened.dismiss(animated: false) }
        window.rootViewController = reopened
        _ = try await waitForJourneyElement("cloud.enrollmentProgress", label: "Connecting device…", hosting: reopened)
        completion.completed = UUID() // A later sync publication has no explicit intent in this new sheet.
        _ = try await waitForJourneyElement("cloud.enrollmentProgress", label: "Connecting device…", hosting: reopened)
        XCTAssertNotNil(reopened.presentedViewController, "Opening Cloud account on a connected device must stay open")
        XCTAssertEqual(completion.verifications, 1)
        let close = try await waitForJourneyElement("cloud.close", label: "Close", hosting: reopened)
        XCTAssertTrue(close.accessibilityActivate())
        let closeDeadline = ProcessInfo.processInfo.systemUptime + 5
        while reopened.presentedViewController != nil && ProcessInfo.processInfo.systemUptime < closeDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(reopened.presentedViewController)
        XCTAssertEqual(fixture.cancellations, cancellations + 1, "Real Close retains its cancellation behavior")
    }
    func testPresentedOAuthReturnHidesProvidersAndCentersLoadingUntilDiscoveryFinishes() async throws {
        let fixture = JourneyFixture()
        await fixture.transport.setEnrollmentChoices(workspaces: 1, locations: 0)
        await fixture.transport.holdNativeSignInReturn()
        var actions = fixture.actions
        actions.enrollDevice = { _, _, _ in XCTFail("Loading must not enroll") }
        actions.suggestedDeviceName = "Draft device"
        var bounds: [CloudJourneyRenderedElement: CGRect] = [:]
        let hosting = UIHostingController(rootView: JourneyActualSheetFixture(
            journey: CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions), dynamicTypeSize: .large,
            recordBounds: { bounds[$0] = $1 }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        do {
            let google = try await waitForJourneyElement("cloud.signIn.google", label: "Continue with Google", hosting: hosting)
            let presented = try XCTUnwrap(hosting.presentedViewController)
            XCTAssertEqual(exposedProviderButtons(in: presented.view).count, 2, "Positive AX control before busy transition")
            XCTAssertTrue(google.accessibilityActivate())
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !(await fixture.transport.nativeSignInReturnIsHeld) && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let held = await fixture.transport.nativeSignInReturnIsHeld
            XCTAssertTrue(held, "Provider returned; hold the actual backend sign-in boundary")
            _ = try await waitForJourneyElement("cloud.progress", label: "Signing in…", hosting: hosting)
            try await assertCenteredProgress(bounds: { bounds }, window: window)
            XCTAssertTrue(exposedProviderButtons(in: presented.view).isEmpty, "Busy provider controls must leave the AX tree")
            XCTAssertEqual(fixture.providers, [.google])
            XCTAssertEqual(fixture.factories, 1)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "PresentedCloud-OAuthReturn-CenteredLoading"; attachment.lifetime = .keepAlways; add(attachment)
            await fixture.transport.releaseNativeSignInReturn()
            let completionDeadline = ProcessInfo.processInfo.systemUptime + 5
            while (fixture.coordinator.isWorking || fixture.coordinator.selectedAccountID == nil) &&
                    ProcessInfo.processInfo.systemUptime < completionDeadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let connect = try await waitForJourneyElement("cloud.connectDevice", hosting: hosting)
            XCTAssertFalse(connect.accessibilityTraits.contains(.notEnabled))
            func textFields(in view: UIView) -> [UITextField] {
                (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
            }
            XCTAssertEqual(textFields(in: presented.view).map(\.text), ["Draft device"], "Actual mounted draft survives the loading transition")
            XCTAssertEqual(fixture.coordinator.selectedAccountID, JourneyTransport.accountID)
            XCTAssertTrue(exposedProviderButtons(in: presented.view).isEmpty)
        } catch {
            fixture.actions.cancel()
            await fixture.transport.releaseNativeSignInReturn()
            throw error
        }
    }
    private func exposedProviderButtons(in view: UIView) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        func exposed(_ object: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(object)).inserted, !object.accessibilityElementsHidden else { return [] }
            var children = object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
            if #available(iOS 17, *) { children += object.automationElements?.compactMap { $0 as? NSObject } ?? [] }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1_000 { children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject } }
            return [object] + children.flatMap { exposed($0) }
        }
        return exposed(view).filter { $0.accessibilityTraits.contains(.button) &&
            ["Continue with Apple", "Continue with Google"].contains($0.accessibilityLabel ?? "") }
    }
    private func assertCenteredProgress(bounds: () -> [CloudJourneyRenderedElement: CGRect], window: UIWindow) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var last: [CloudJourneyRenderedElement: CGRect] = [:], stable = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            window.layoutIfNeeded()
            let current = bounds()
            if current[.progress] != nil, current[.bodyViewport] != nil, current == last { stable += 1 } else { stable = 0 }
            if stable >= 4 {
                let progress = try XCTUnwrap(current[.progress]), viewport = try XCTUnwrap(current[.bodyViewport])
                XCTAssertFalse(progress.isEmpty)
                XCTAssertTrue(viewport.contains(progress))
                XCTAssertEqual(progress.midX, viewport.midX, accuracy: 2)
                XCTAssertEqual(progress.midY, viewport.midY, accuracy: 2)
                for part in [CloudJourneyRenderedElement.header, .close, .footer, .progress] {
                    XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(try XCTUnwrap(current[part])))
                }
                return
            }
            last = current; try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Centered progress bounds did not settle")
        throw NSError(domain: "CloudJourneyLoadingFixture", code: 1)
    }
    func testPresentedConnectDispatchesRealControllerBusyProgressAndLocksRetry() async throws {
        let fixture = JourneyFixture()
        await fixture.transport.setEnrollmentChoices(workspaces: 1, locations: 0)
        await (try fixture.actions.signIn(.google))?.value
        await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
        XCTAssertEqual(fixture.lifecycle.accountEntryState, .ownedHere)
        XCTAssertNotNil(fixture.coordinator.humanIdentity)
        XCTAssertEqual(fixture.coordinator.selectedAccountID, JourneyTransport.accountID)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-live-enrollment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent)
        let intent = try NativeEnrollmentIntentRecord(accountID: JourneyTransport.accountID, locationID: nil,
            name: "Original device", profile: "iPad", origin: URL(string: "https://fixture.screenpunk.test")!,
            viewport: CGSize(width: 768, height: 1024))
        try journal.saveOriginal(intent)
        let originalBytes = try Data(contentsOf: parent.appendingPathComponent("original.json"))
        let gate = JourneyEnrollmentWorkGate()
        let pending = Task<Void, Never> { await gate.wait() }
        let controller = NativeEnrollmentSceneController(testIntentJournal: journal, pendingTask: pending, workKind: .reconnect)
        let bootstrap = DeviceManagementBootstrap() // Inert: no startup, owner, network, or credentials.
        var dispatches = 0
        let journey = CloudEnrollmentAccountJourneyView(lifecycle: fixture.lifecycle, presentation: fixture.presentation,
            availability: .qualified, controller: controller, connect: { account, location, name in
                dispatches += 1
                controller.enroll(lifecycle: fixture.lifecycle, bootstrap: bootstrap, accountID: account,
                    locationID: location, name: name, viewport: CGSize(width: 768, height: 1024))
            })
        var bounds: [CloudJourneyRenderedElement: CGRect] = [:]
        let hosting = UIHostingController(rootView: JourneyActualSheetFixture(journey: journey,
            dynamicTypeSize: .large, recordBounds: { bounds[$0] = $1 }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        do {
            let connect = try await waitForJourneyElement("cloud.connectDevice", hosting: hosting)
            XCTAssertFalse(connect.accessibilityTraits.contains(.notEnabled))
            XCTAssertTrue(connect.accessibilityActivate(), "Activate the actual presented SwiftUI Button")
            let progress = try await waitForJourneyElement("cloud.enrollmentProgress", label: "Connecting device…", hosting: hosting)
            try await assertCenteredProgress(bounds: { bounds }, window: window)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "PresentedCloud-NativeConnecting-CenteredLoading"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(dispatches, 1)
            XCTAssertEqual(controller.state, .enrolling)
            XCTAssertEqual(progress.accessibilityLabel, "Connecting device…")
            let disabledConnect = try await waitForJourneyElement("cloud.connectDevice", hosting: hosting)
            XCTAssertTrue(disabledConnect.accessibilityTraits.contains(.notEnabled))
            _ = disabledConnect.accessibilityActivate()
            XCTAssertEqual(dispatches, 1, "A stale busy control must not start another original operation")
            XCTAssertFalse(pending.isCancelled)
            XCTAssertNil(bootstrap.currentAuthority)
            XCTAssertEqual(try journal.load(), intent)
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("original.json")), originalBytes)
            await gate.release(); await pending.value
        } catch {
            await gate.release(); await pending.value; throw error
        }
    }
    func testPresentedConnectShowsRealControllerFailureAndPreservesOriginalRetry() async throws {
        let fixture = JourneyFixture()
        await fixture.transport.setEnrollmentChoices(workspaces: 1, locations: 0)
        await (try fixture.actions.signIn(.google))?.value
        await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
        XCTAssertEqual(fixture.lifecycle.accountEntryState, .ownedHere)
        XCTAssertNotNil(fixture.coordinator.humanIdentity)
        XCTAssertEqual(fixture.coordinator.selectedAccountID, JourneyTransport.accountID)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("screenpunk-live-enrollment-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent)
        let intent = try NativeEnrollmentIntentRecord(accountID: JourneyTransport.accountID, locationID: nil,
            name: "Original device", profile: "iPad", origin: URL(string: "https://fixture.screenpunk.test")!,
            viewport: CGSize(width: 768, height: 1024))
        try journal.saveOriginal(intent)
        let originalBytes = try Data(contentsOf: parent.appendingPathComponent("original.json"))
        let controller = NativeEnrollmentSceneController(testIntentJournal: journal)
        let bootstrap = DeviceManagementBootstrap()
        var dispatched: [(UUID, UUID?, String)] = []
        let journey = CloudEnrollmentAccountJourneyView(lifecycle: fixture.lifecycle, presentation: fixture.presentation,
            availability: .qualified, controller: controller, connect: { account, location, name in
                dispatched.append((account, location, name))
                controller.enroll(lifecycle: fixture.lifecycle, bootstrap: bootstrap, accountID: account,
                    locationID: location, name: name, viewport: CGSize(width: 768, height: 1024))
            })
        let hosting = UIHostingController(rootView: JourneyActualSheetFixture(journey: journey,
            dynamicTypeSize: .large, recordBounds: { _, _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { hosting.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let connect = try await waitForJourneyElement("cloud.connectDevice", hosting: hosting)
        XCTAssertTrue(connect.accessibilityActivate())
        let error = try await waitForJourneyElement("cloud.enrollmentError", label: controller.deliveryMessage, hosting: hosting)
        XCTAssertEqual(controller.state, .needsAttention)
        XCTAssertEqual(error.accessibilityLabel, controller.deliveryMessage)
        XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .selection)
        XCTAssertEqual(controller.enrollmentDiagnostic?.category, .authorization)
        XCTAssertFalse(error.accessibilityLabel?.contains("selection/authorization") == true, "Normal copy keeps fixed diagnostic codes internal")
        let retry = try await waitForJourneyElement("cloud.connectDevice", label: "Retry connection", hosting: hosting)
        XCTAssertEqual(retry.accessibilityLabel, "Retry connection")
        XCTAssertFalse(retry.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(retry.accessibilityActivate())
        let retryDeadline = ProcessInfo.processInfo.systemUptime + 5
        while dispatched.count < 2 && ProcessInfo.processInfo.systemUptime < retryDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(dispatched.count, 2)
        for input in dispatched {
            XCTAssertEqual(input.0, intent.accountID); XCTAssertNil(input.1); XCTAssertEqual(input.2, intent.name)
        }
        XCTAssertEqual(try journal.load(), intent)
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("original.json")), originalBytes)
        XCTAssertNil(bootstrap.currentAuthority)
    }
    private func waitForJourneyElement(_ identifier: String, label: String? = nil, hosting: UIViewController) async throws -> NSObject {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            hosting.view.window?.layoutIfNeeded()
            guard let presented = hosting.presentedViewController,
                  !presented.isBeingPresented, presented.transitionCoordinator == nil else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            var visited: Set<ObjectIdentifier> = []
            let roots: [NSObject] = [presented.view!]
            let expectedLabel = label ?? (identifier == "cloud.connectDevice" ? "Connect device" : nil)
            if let element = roots.flatMap({ journeyAccessibilityElements($0, visited: &visited) }).first(where: {
                let matches = ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier ||
                    (expectedLabel != nil && $0.accessibilityLabel == expectedLabel)
                return matches && (identifier != "cloud.connectDevice" || $0.accessibilityTraits.contains(.button))
            }) { return element }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if let window = hosting.view.window {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "MissingAction-\(identifier)"; attachment.lifetime = .keepAlways; add(attachment)
            var visited: Set<ObjectIdentifier> = []
            let elements = window.windowScene?.windows.filter { !$0.isHidden }.flatMap {
                journeyAccessibilityElements($0, visited: &visited)
            } ?? []
            let description = elements.map {
                "\(type(of: $0)) id=\(($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "nil") label=\($0.accessibilityLabel ?? "nil")"
            }.joined(separator: "\n")
            let tree = XCTAttachment(string: description)
            tree.name = "FixtureAccessibilityTree"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTFail("Missing presented accessibility element: \(identifier)")
        throw NSError(domain: "CloudJourneyActionFixture", code: 1)
    }
    private func journeyAccessibilityElements(_ object: NSObject, visited: inout Set<ObjectIdentifier>) -> [NSObject] {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
        var children = (object as? UIView)?.subviews.map { $0 as NSObject } ?? []
        if #available(iOS 17, *) { children += object.automationElements?.compactMap { $0 as? NSObject } ?? [] }
        children += object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
        let count = object.accessibilityElementCount()
        if count > 0 && count < 1_000 {
            children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        return [object] + children.flatMap { journeyAccessibilityElements($0, visited: &visited) }
    }
    func testNameSuggestionArrivingAfterMountIsAppliedOnce() {
        var draft = CloudEnrollmentNameDraft()
        draft.applySuggestion(nil)
        XCTAssertEqual(draft.name, "")
        draft.applySuggestion("iPad")
        XCTAssertEqual(draft.name, "iPad")
        draft.applySuggestion("A later OS name")
        XCTAssertEqual(draft.name, "iPad")
    }
    func testManualNameAndIntentionalEmptyEditSurviveAsyncSuggestions() {
        var draft = CloudEnrollmentNameDraft(suggestedName: "iPad")
        draft.edit("Office iPad")
        draft.applySuggestion("Another OS name")
        XCTAssertEqual(draft.name, "Office iPad")
        draft.edit("")
        draft.applySuggestion("iPad")
        XCTAssertEqual(draft.name, "")
        var beforeSuggestion = CloudEnrollmentNameDraft()
        beforeSuggestion.edit("Typed before metadata arrived")
        beforeSuggestion.applySuggestion("iPad")
        XCTAssertEqual(beforeSuggestion.name, "Typed before metadata arrived")
    }
    func testRetainedNameWinsWithoutDestroyingEditableDraft() {
        var draft = CloudEnrollmentNameDraft(suggestedName: "iPad")
        draft.edit("New draft")
        XCTAssertEqual(draft.displayedName(retainedName: "Original device"), "Original device")
        XCTAssertEqual(draft.displayedName(retainedName: nil), "New draft")
    }
    func testRetryUsesOriginalNameAndUnassignedLocationAndRefusesAnotherWorkspace() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        var actions = CloudAccountJourneyActions(lifecycle: lifecycle, presentation: CloudProviderPresentation(), availability: .qualified)
        let account = UUID()
        actions.retainedAccountID = account; actions.retainedLocationID = nil; actions.retainedDeviceName = "Original device"
        var captured: [(UUID, UUID?, String)] = []
        actions.enrollDevice = { captured.append(($0, $1, $2)) }
        actions.connectDevice(accountID: UUID(), locationID: UUID(), name: "Replacement")
        XCTAssertTrue(captured.isEmpty)
        actions.connectDevice(accountID: account, locationID: UUID(), name: "Replacement")
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.0, account)
        XCTAssertNil(captured.first?.1)
        XCTAssertEqual(captured.first?.2, "Original device")
    }
    func testHostedConfirmationReceivesLateDefaultPreservesTypingAndShowsRetainedName() async throws {
        let fixture = JourneyFixture()
        await fixture.transport.setAccounts(true)
        await (try fixture.actions.signIn(.google))?.value
        await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
        var actions = fixture.actions
        actions.enrollDevice = { _, _, _ in }
        actions.deviceProfile = "iPad"
        let hosting = UIHostingController(rootView: CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        hosting.view.layoutIfNeeded(); await Task.yield()
        func fields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        var deviceField = try XCTUnwrap(fields(in: hosting.view).first(where: { $0.placeholder == "Device name" }))
        XCTAssertEqual(fields(in: hosting.view).count, 1) // The compact form only edits the name.
        XCTAssertEqual(deviceField.text, "")
        actions.suggestedDeviceName = "iPad"
        hosting.rootView = CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions)
        hosting.view.layoutIfNeeded(); await Task.yield(); hosting.view.layoutIfNeeded()
        deviceField = try XCTUnwrap(fields(in: hosting.view).first(where: { $0.placeholder == "Device name" }))
        XCTAssertEqual(deviceField.text, "iPad")
        deviceField.text = "Office iPad"; deviceField.sendActions(for: .editingChanged)
        await Task.yield()
        actions.suggestedDeviceName = "Later OS name"
        hosting.rootView = CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions)
        hosting.view.layoutIfNeeded(); await Task.yield(); hosting.view.layoutIfNeeded()
        deviceField = try XCTUnwrap(fields(in: hosting.view).first(where: { $0.placeholder == "Device name" }))
        XCTAssertEqual(deviceField.text, "Office iPad")
        actions.retainedAccountID = JourneyTransport.accountID; actions.retainedDeviceName = "Saved original"
        hosting.rootView = CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions)
        hosting.view.layoutIfNeeded(); await Task.yield(); hosting.view.layoutIfNeeded()
        deviceField = try XCTUnwrap(fields(in: hosting.view).first(where: { $0.placeholder == "Device name" }))
        XCTAssertEqual(deviceField.text, "Saved original")
        XCTAssertFalse(deviceField.isEnabled)
    }
    func testCompactChoiceVisibilityPreservesUnassignedAndSavedLocation() async throws {
        let fixture = JourneyFixture()
        await fixture.transport.setEnrollmentChoices(workspaces: 1, locations: 1)
        await (try fixture.actions.signIn(.google))?.value
        await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
        let compact = CloudEnrollmentChoices(accounts: fixture.coordinator.accounts, locations: fixture.coordinator.locations,
            retainedAccountID: nil, retainedLocationID: nil, enrollment: true)
        XCTAssertFalse(compact.showsWorkspaceSelector)
        XCTAssertFalse(compact.showsLocationSelector)
        XCTAssertNil(compact.retainedLocationSummary)
        var actions = fixture.actions
        var selected: UUID?
        var connections = 0
        actions.enrollDevice = { _, location, _ in connections += 1; selected = location }
        actions.connectDevice(accountID: JourneyTransport.accountID, locationID: nil, name: "iPad")
        XCTAssertEqual(connections, 1)
        XCTAssertNil(selected, "Hiding a single named location must not assign it")
        let originalLocation = try XCTUnwrap(fixture.coordinator.locations.first?.id)
        let retained = CloudEnrollmentChoices(accounts: fixture.coordinator.accounts, locations: fixture.coordinator.locations,
            retainedAccountID: JourneyTransport.accountID, retainedLocationID: originalLocation, enrollment: true)
        XCTAssertFalse(retained.showsLocationSelector)
        XCTAssertEqual(retained.retainedLocationSummary, "Fixture location 1")
        actions.retainedAccountID = JourneyTransport.accountID; actions.retainedLocationID = originalLocation
        actions.connectDevice(accountID: JourneyTransport.accountID, locationID: nil, name: "iPad")
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(selected, originalLocation)
    }
    func testCompactProviderEntryFitsTabletWithPinnedLegalAndNoProviderEffects() async throws {
        let fixture = JourneyFixture()
        let hosting = UIHostingController(rootView: fixture.view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 768, height: 1024)
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<5 { hosting.view.layoutIfNeeded(); await Task.yield() }
        func scrollViews(in view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: hosting.view).first)
        XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 2)
        XCTAssertFalse(scroll.alwaysBounceVertical && scroll.bounces)
        let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "CompactCloud-ProviderEntry"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(fixture.factories, 0); XCTAssertEqual(fixture.presentations, 0)
        XCTAssertTrue(fixture.providers.isEmpty)
    }
    func testCompactEnrollmentLayoutsKeepFooterVisibleWithoutTabletScrolling() async throws {
        for scenario in [(1, 0, "SingleWorkspace-NoLocations"), (1, 1, "SingleWorkspace-OneLocation"), (2, 3, "MultipleChoices")] {
            let fixture = JourneyFixture()
            await fixture.transport.setEnrollmentChoices(workspaces: scenario.0, locations: scenario.1)
            await (try fixture.actions.signIn(.google))?.value
            await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
            var actions = fixture.actions
            actions.suggestedDeviceName = "iPad"
            actions.enrollDevice = { _, _, _ in }
            let choices = CloudEnrollmentChoices(accounts: fixture.coordinator.accounts, locations: fixture.coordinator.locations,
                retainedAccountID: nil, retainedLocationID: nil, enrollment: true)
            XCTAssertEqual(choices.showsWorkspaceSelector, scenario.0 > 1)
            XCTAssertEqual(choices.showsLocationSelector, scenario.1 > 1)
            let hosting = UIHostingController(rootView: CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 768, height: 1024)
            window.rootViewController = hosting; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            for _ in 0..<5 { hosting.view.layoutIfNeeded(); await Task.yield() }
            func scrollViews(in view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let scroll = try XCTUnwrap(scrollViews(in: hosting.view).first)
            XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 2)
            XCTAssertFalse(scroll.alwaysBounceVertical && scroll.bounces)
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "CompactCloud-\(scenario.2)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(fixture.factories, 1)
            XCTAssertEqual(fixture.providers, [.google])
        }
    }
    func testActualPresentedSheetsShareOrdinaryPanelSizeAndDisableScrolling() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        var ordinaryPanelSizes: [CGSize] = []
        for scenario in ["Provider", "Confirmation", "MultipleChoices", "LocationRequired", "Overflow"] {
            let fixture = JourneyFixture()
            var actions = fixture.actions
            if scenario != "Provider" {
                await fixture.transport.setEnrollmentChoices(workspaces: scenario == "MultipleChoices" ? 2 : 1,
                    locations: scenario == "MultipleChoices" ? 3 : scenario == "LocationRequired" ? 1 : 0)
                if scenario == "LocationRequired" { await fixture.transport.setUnassignedEnrollmentAllowed(false) }
                await (try fixture.actions.signIn(.google))?.value
                await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
                actions.suggestedDeviceName = "iPad"; actions.enrollDevice = { _, _, _ in }
                if scenario == "Overflow" {
                    actions.enrollmentState = .needsAttention
                    actions.deliveryMessage = String(repeating: "The saved connection needs recovery. Retry the original request. ", count: 20)
                }
            }
            let journey = CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions)
            var renderedBounds: [CloudJourneyRenderedElement: CGRect] = [:]
            let hosting = UIHostingController(rootView: JourneyActualSheetFixture(journey: journey,
                dynamicTypeSize: scenario == "Overflow" ? .accessibility3 : .large,
                recordBounds: { element, rect in renderedBounds[element] = rect }))
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while hosting.presentedViewController?.view.window == nil && ProcessInfo.processInfo.systemUptime < deadline {
                hosting.view.layoutIfNeeded(); try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let presented = try XCTUnwrap(hosting.presentedViewController)
            XCTAssertNotNil(presented.presentationController, "Use actual system sheet presentation, not a full-window hosting snapshot")
            func scrollViews(in view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let scroll = try XCTUnwrap(scrollViews(in: presented.view).first)
            try await waitForStableJourneyLayout(presented: presented, window: window, scroll: scroll,
                bounds: { renderedBounds }, scenario: scenario)
            let visible = window.bounds.insetBy(dx: -1, dy: -1)
            let required: [CloudJourneyRenderedElement] = [.header, .close, .footer, .bodyViewport]
                + (scenario == "Provider" ? [.appleCTA, .googleCTA] : [.primaryAction])
            for element in required {
                let rect = try XCTUnwrap(renderedBounds[element], "Missing actual rendered bounds for \(element)")
                XCTAssertFalse(rect.isEmpty)
                XCTAssertTrue(visible.contains(rect), "\(scenario): \(element) \(rect) must be inside visible window \(window.bounds)")
            }
            let viewport = try XCTUnwrap(renderedBounds[.bodyViewport])
            let scrollRect = scroll.convert(scroll.bounds, to: window)
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(scrollRect), "Scroll bounds must be the visible body viewport")
            XCTAssertLessThan(try XCTUnwrap(renderedBounds[.close]).maxX, try XCTUnwrap(renderedBounds[.header]).minX)
            if UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertEqual(presented.view.bounds.width, window.bounds.width, accuracy: 1)
                XCTAssertEqual(presented.view.bounds.height, window.bounds.height, accuracy: 1)
                XCTAssertEqual(ScreenpunkOnboardingOrientationPolicy.shared.supportedOrientations(window: window, idiom: .phone), .portrait)
            }
            if scenario == "Overflow" {
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                XCTAssertTrue(scroll.isScrollEnabled, "Real overflow must keep its scroll fallback")
            } else {
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 2)
                XCTAssertLessThanOrEqual(scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom,
                    scroll.bounds.height + 2, "Fitting content must have no native scroll range")
                XCTAssertFalse(scroll.alwaysBounceVertical && scroll.bounces, "Fitting content must not bounce")
            }
            if scenario == "Provider" || scenario == "Confirmation" { ordinaryPanelSizes.append(presented.view.bounds.size) }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "PresentedCloud-\(scenario)-NativeSheet"; attachment.lifetime = .keepAlways; add(attachment)
            if scenario == "LocationRequired" {
                let choices = CloudEnrollmentChoices(accounts: fixture.coordinator.accounts, locations: fixture.coordinator.locations,
                    retainedAccountID: nil, retainedLocationID: nil, enrollment: true)
                XCTAssertFalse(choices.showsLocationSelector)
                XCTAssertNotNil(choices.unassignedPermissionMessage(accountID: JourneyTransport.accountID, selectedLocationID: nil))
                XCTAssertNil(choices.unassignedPermissionMessage(accountID: JourneyTransport.accountID, selectedLocationID: fixture.coordinator.locations.first?.id))
            }
            if scenario == "Provider" { XCTAssertEqual(fixture.factories, 0); XCTAssertTrue(fixture.providers.isEmpty) }
            else { XCTAssertEqual(fixture.factories, 1); XCTAssertEqual(fixture.providers, [.google]) }
            await withCheckedContinuation { continuation in presented.dismiss(animated: false) { continuation.resume() } }
            for _ in 0..<3 { await Task.yield() }
            if UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertEqual(ScreenpunkOnboardingOrientationPolicy.shared.supportedOrientations(window: window, idiom: .phone), .allButUpsideDown)
            }
        }
        XCTAssertEqual(ordinaryPanelSizes.count, 2)
        XCTAssertEqual(ordinaryPanelSizes[0].width, ordinaryPanelSizes[1].width, accuracy: 2)
        XCTAssertEqual(ordinaryPanelSizes[0].height, ordinaryPanelSizes[1].height, accuracy: 2)
    }
    private func waitForStableJourneyLayout(presented: UIViewController, window: UIWindow, scroll: UIScrollView,
        bounds: () -> [CloudJourneyRenderedElement: CGRect], scenario: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var previousElements: [CloudJourneyRenderedElement: CGRect] = [:]
        var previousScrollRect = CGRect.null, previousContent = CGSize.zero, previousPanelRect = CGRect.null
        var stableSamples = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            window.layoutIfNeeded()
            let elements = bounds(), scrollRect = scroll.convert(scroll.bounds, to: window)
            let panelRect = presented.view.convert(presented.view.bounds, to: window)
            let animating = presented.isBeingPresented || presented.transitionCoordinator != nil ||
                !(presented.view.layer.animationKeys() ?? []).isEmpty
            if !animating, !elements.isEmpty, elements == previousElements,
               scrollRect == previousScrollRect, scroll.contentSize == previousContent, panelRect == previousPanelRect {
                stableSamples += 1
                if stableSamples >= 4 { return }
            } else { stableSamples = 0 }
            previousElements = elements; previousScrollRect = scrollRect
            previousContent = scroll.contentSize; previousPanelRect = panelRect
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("\(scenario) sheet layout did not settle before viewport assertions")
        throw NSError(domain: "CloudJourneyLayoutFixture", code: 1)
    }
    func testOnlyVerifiedViewScreenTransitionPreservesDismissal() throws {
        let state = CloudJourneyDismissalCancellation(); var revocations = 0
        enum Failure: Error { case stale }
        XCTAssertThrowsError(try state.preserveCompletedTransition { throw Failure.stale })
        state.cancel { revocations += 1 }
        XCTAssertEqual(revocations, 1)
        state.reset()
        try state.preserveCompletedTransition {}
        state.cancel { revocations += 1 }
        XCTAssertEqual(revocations, 1)
        state.reset(); state.cancel { revocations += 1 }
        XCTAssertEqual(revocations, 2)
    }

    func testEnrollmentActionPreservesActualSelectedIDsAndExplicitInputs() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        var actions = CloudAccountJourneyActions(lifecycle: lifecycle, presentation: CloudProviderPresentation(), availability: .qualified)
        let account = UUID(), location = UUID()
        var captured: (UUID, UUID?, String)?
        actions.enrollDevice = { captured = ($0, $1, $2) }
        actions.enrollDevice?(account, location, "Tester device")
        XCTAssertEqual(captured?.0, account); XCTAssertEqual(captured?.1, location)
        XCTAssertEqual(captured?.2, "Tester device")
        XCTAssertNil(lifecycle.coordinator)
    }

    func testOccupiedEntryRaceHasSpecificCopyAndZeroLosingFactoryEffects() async throws {
        let broker = CloudHumanSessionBroker()
        let owner = JourneyFixture(broker: broker), later = JourneyFixture(broker: broker)
        XCTAssertEqual(later.lifecycle.accountEntryState, .available)
        let hosting = UIHostingController(rootView: later.view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        hosting.view.layoutIfNeeded() // Entry rendered before ownership changes.
        await (try owner.actions.signIn(.google))?.value
        hosting.rootView = later.view; hosting.view.layoutIfNeeded(); await Task.yield()
        let occupiedImage = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
        let occupiedAttachment = XCTAttachment(image: occupiedImage); occupiedAttachment.name = "AccountEntry-Occupied"; occupiedAttachment.lifetime = .keepAlways; add(occupiedAttachment)
        XCTAssertEqual(later.lifecycle.accountEntryState, .occupiedElsewhere)
        XCTAssertThrowsError(try later.actions.signIn(.apple)) { error in
            XCTAssertEqual(CloudJourneyCopy.signInFailure(error), CloudJourneyCopy.occupiedWindow)
        }
        XCTAssertEqual(later.factories, 0); XCTAssertEqual(later.presentations, 0)
        later.actions.cancel(); later.lifecycle.didEnterBackground()
        XCTAssertNotNil(owner.coordinator.humanIdentity)
        await owner.actions.signOut()?.value
        XCTAssertEqual(later.lifecycle.accountEntryState, .available)
        XCTAssertEqual(later.factories, 0); XCTAssertNil(later.lifecycle.coordinator)
        let successor = JourneyFixture(broker: broker)
        await (try successor.actions.signIn(.google))?.value // Explicit acquisition constructs a fresh pair.
        later.lifecycle.retirePresentationContext(); later.actions.cancel(); later.lifecycle.didEnterBackground()
        XCTAssertEqual(later.lifecycle.accountEntryState, .retired)
        hosting.rootView = later.view; hosting.view.layoutIfNeeded(); await Task.yield()
        let retiredImage = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
        let retiredAttachment = XCTAttachment(image: retiredImage); retiredAttachment.name = "AccountEntry-Retired"; retiredAttachment.lifetime = .keepAlways; add(retiredAttachment)
        XCTAssertNotNil(successor.coordinator.humanIdentity)
    }

    func testRetiredEntryHasTerminalCopyAndNoSignInEffects() throws {
        let fixture = JourneyFixture()
        fixture.lifecycle.retirePresentationContext()
        XCTAssertEqual(fixture.lifecycle.accountEntryState, .retired)
        let hosting = UIHostingController(rootView: fixture.view)
        hosting.loadViewIfNeeded(); hosting.view.layoutIfNeeded()
        XCTAssertThrowsError(try fixture.actions.signIn(.google)) { error in
            XCTAssertEqual(CloudJourneyCopy.signInFailure(error), CloudJourneyCopy.retiredWindow)
        }
        XCTAssertEqual(fixture.factories, 0); XCTAssertEqual(fixture.presentations, 0)
        XCTAssertNil(fixture.lifecycle.coordinator)
    }

    func testLaterJourneyRendersCleanupAndRetriesWithoutFactoryOrPresentation() async throws {
        let broker = CloudHumanSessionBroker()
        let original = JourneyFixture(broker: broker); original.holdSignOut = true
        await (try original.actions.signIn(.google))?.value
        original.lifecycle.retirePresentationContext()
        while original.signOutContinuation == nil { await Task.yield() }
        let later = JourneyFixture(broker: broker)
        XCTAssertEqual(later.lifecycle.retiredCleanupState, .pending)
        XCTAssertEqual(later.lifecycle.accountEntryState, .occupiedElsewhere) // Cleanup UI takes precedence.
        let hosting = UIHostingController(rootView: later.view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        hosting.view.layoutIfNeeded(); await Task.yield()
        let pendingImage = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
        let pendingAttachment = XCTAttachment(image: pendingImage); pendingAttachment.name = "RetiredCleanup-Pending"; pendingAttachment.lifetime = .keepAlways; add(pendingAttachment)
        original.finishSignOut(failed: true)
        while broker.state == .retiring { await Task.yield() }
        guard case .failed(let handle) = later.lifecycle.retiredCleanupState else { return XCTFail("Missing failure control") }
        hosting.rootView = later.view; hosting.view.layoutIfNeeded(); await Task.yield()
        let failedImage = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
        let failedAttachment = XCTAttachment(image: failedImage); failedAttachment.name = "RetiredCleanup-Failed"; failedAttachment.lifetime = .keepAlways; add(failedAttachment)
        XCTAssertThrowsError(try later.actions.signIn(.google))
        XCTAssertEqual(later.factories, 0); XCTAssertEqual(later.presentations, 0)
        let retry = later.actions.retryRetiredCleanup(handle)
        while original.signOutContinuation == nil { await Task.yield() }
        later.actions.cancel(); later.lifecycle.didEnterBackground()
        XCTAssertEqual(later.lifecycle.retiredCleanupState, .pending)
        XCTAssertNil(later.lifecycle.coordinator)
        original.finishSignOut(failed: false); await retry?.value
        XCTAssertEqual(later.lifecycle.retiredCleanupState, .none)
        XCTAssertEqual(later.factories, 0); XCTAssertEqual(later.presentations, 0)
        XCTAssertNil(later.lifecycle.coordinator)
    }

    func testUnavailableAndRenderingNeverConstructOrAuthenticate() throws {
        let fixture = JourneyFixture(availability: .unavailable("Unavailable fixture"))
        let hosting = UIHostingController(rootView: fixture.view)
        hosting.loadViewIfNeeded(); hosting.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568); hosting.view.layoutIfNeeded()
        XCTAssertEqual(fixture.factories, 0); XCTAssertEqual(fixture.presentations, 0)
        XCTAssertThrowsError(try fixture.actions.signIn(.google))
        XCTAssertEqual(fixture.factories, 0); XCTAssertNil(fixture.lifecycle.coordinator)
        fixture.actions.recover(); fixture.actions.retry(); fixture.actions.create(workspace: "Ignored", location: "Ignored")
        XCTAssertNil(fixture.lifecycle.coordinator)
    }

    func testUnconfiguredExplicitFactoryFailsClosedWithoutInstalling() {
        let broker = CloudHumanSessionBroker()
        var validations = 0
        let lifecycle = CloudHumanSessionLifecycle(broker: broker, loadConfiguration: {
            validations += 1
            XCTAssertEqual(broker.state, .reserving)
            return try CloudNativeConfiguration.load(info: [:], bundleID: "xyz.screenpunk.unconfigured-fixture")
        })
        var resolutions = 0
        let presentation = CloudProviderPresentation(testResolve: { resolutions += 1; return .init(controller: UIViewController(), window: UIWindow()) })
        let actions = CloudAccountJourneyActions(lifecycle: lifecycle, presentation: presentation, availability: .qualified)
        XCTAssertThrowsError(try actions.signIn(.apple)) { XCTAssertEqual($0 as? CloudNativeIdentityError, .notConfigured) }
        XCTAssertEqual(validations, 1)
        XCTAssertNil(lifecycle.coordinator); XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(broker.state, .vacant)
        XCTAssertEqual(lifecycle.accountEntryState, .available)
    }

    func testExplicitSignInInstallsOnceAndNeverAutoCreatesWorkspace() async throws {
        let fixture = JourneyFixture()
        await (try fixture.actions.signIn(.google))?.value
        XCTAssertTrue(fixture.lifecycle.coordinator === fixture.coordinator)
        XCTAssertEqual(fixture.factories, 1); XCTAssertEqual(fixture.presentations, 1)
        XCTAssertTrue(fixture.coordinator.canCreateFirstWorkspace)
        let firstPosts = await fixture.transport.posts; XCTAssertTrue(firstPosts.isEmpty)
        fixture.actions.cancel()
        await (try fixture.actions.signIn(.apple))?.value
        XCTAssertEqual(fixture.factories, 1); XCTAssertEqual(fixture.providers, [.google, .apple])
    }

    func testPendingRequestLocksNewInputsAndIdenticalRetryRecovers() async throws {
        let fixture = JourneyFixture()
        await (try fixture.actions.signIn(.google))?.value
        await fixture.transport.setFailure(404)
        await fixture.actions.create(workspace: " Cafe\u{301} ", location: " Home ")?.value
        let pending = try XCTUnwrap(fixture.coordinator.pendingWorkspaceSetup)
        XCTAssertFalse(fixture.coordinator.canCreateFirstWorkspace)
        XCTAssertNil(fixture.actions.create(workspace: "Replacement", location: "Replacement"))
        await fixture.actions.recover()?.value
        XCTAssertEqual(fixture.journal.record, pending)
        await fixture.transport.setFailure(nil)
        await fixture.actions.retry()?.value
        let posts = await fixture.transport.posts, lookups = await fixture.transport.lookups
        XCTAssertEqual(posts, [pending.request, pending.request]); XCTAssertEqual(lookups, [pending.request.requestId])
        XCTAssertNotNil(fixture.coordinator.workspaceSetupReceipt)
        let count = posts.count
        await fixture.actions.recover()?.value
        let finalPosts = await fixture.transport.posts; XCTAssertEqual(finalPosts.count, count)
    }

    func testReceiptWriteRepairSendsNoAdditionalNetworkAndUnreadableBlocksCreate() async throws {
        let fixture = JourneyFixture(); fixture.journal.failSaveNumber = 2
        await (try fixture.actions.signIn(.google))?.value
        await fixture.actions.create(workspace: "Workspace", location: "Location")?.value
        XCTAssertEqual(fixture.coordinator.failure, .persistence)
        XCTAssertNil(fixture.actions.create(workspace: "Another", location: "Another"))
        await fixture.actions.recover()?.value
        XCTAssertNotNil(fixture.coordinator.workspaceSetupReceipt)
        let posts = await fixture.transport.posts, lookups = await fixture.transport.lookups
        XCTAssertEqual(posts.count, 1); XCTAssertTrue(lookups.isEmpty)
    }

    func testAnotherUserCannotRecoverOrReplaceSavedRequest() async throws {
        let fixture = JourneyFixture()
        let original = try CloudWorkspaceSetupJournalRecord(userID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            request: .init(requestId: UUID(), workspaceName: "Other workspace", locationName: "Other location"))
        fixture.journal.record = original
        await (try fixture.actions.signIn(.google))?.value
        XCTAssertEqual(fixture.coordinator.failure, .pendingOtherUser)
        XCTAssertNil(fixture.actions.create(workspace: "New", location: "New"))
        fixture.actions.recover(); fixture.actions.retry()
        XCTAssertEqual(fixture.journal.record, original)
        let posts = await fixture.transport.posts, lookups = await fixture.transport.lookups
        XCTAssertTrue(posts.isEmpty); XCTAssertTrue(lookups.isEmpty)
    }

    func testLocationsAreLoadedOnlyForExplicitAccountChoice() async throws {
        let fixture = JourneyFixture(); await fixture.transport.setAccounts(true)
        await (try fixture.actions.signIn(.google))?.value
        XCTAssertTrue(fixture.coordinator.locations.isEmpty)
        await fixture.actions.chooseAccount(JourneyTransport.accountID)?.value
        XCTAssertEqual(fixture.coordinator.locations.map(\.name), ["Fixture location"])
        let posts = await fixture.transport.posts; XCTAssertTrue(posts.isEmpty)
    }

    func testSignOutPendingAndFailedRemainObservableAndRetryExplicit() async throws {
        let fixture = JourneyFixture(); fixture.holdSignOut = true
        await (try fixture.actions.signIn(.google))?.value
        let signOut = fixture.actions.signOut()
        while fixture.signOutContinuation == nil { await Task.yield() }
        XCTAssertEqual(fixture.coordinator.signOutState, .pending)
        XCTAssertNil(fixture.coordinator.humanIdentity)
        XCTAssertNil(try fixture.actions.signIn(.google))
        fixture.actions.cancel()
        fixture.finishSignOut(failed: true)
        await signOut?.value
        XCTAssertEqual(fixture.coordinator.signOutState, .failed)
        XCTAssertNil(try fixture.actions.signIn(.apple))
        fixture.holdSignOut = false
        await fixture.actions.retrySignOut()?.value
        XCTAssertEqual(fixture.coordinator.signOutState, .succeeded)
        XCTAssertEqual(fixture.factories, 1)
    }

    func testCopyNeverDisplaysRawAPIMessageOrClaimsDeviceConnection() throws {
        let error = try JSONDecoder().decode(CloudNativeAPIError.self, from: Data(#"{"code":"workspace_setup_unavailable","message":"secret-fixture-diagnostic","requestId":"trace-fixture"}"#.utf8))
        for status in [401, 404, 409, 429, 503] {
            let copy = try XCTUnwrap(CloudJourneyCopy.failure(.workspaceSetup, setup: .api(status: status, error: error)))
            XCTAssertFalse(copy.contains(error.message)); XCTAssertFalse(copy.contains(error.requestId))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("device connected"))
        }
    }

    func testExplicitCloseAndUIKitDismissalShareOneRevocation() async throws {
        let fixture = JourneyFixture(); fixture.holdAuthentication = true
        let task = try fixture.actions.signIn(.google)
        while fixture.authenticationContinuation == nil { await Task.yield() }
        let cancellation = CloudJourneyDismissalCancellation(), before = fixture.cancellations
        cancellation.cancel(fixture.actions.cancel) // Explicit Close.
        cancellation.cancel(fixture.actions.cancel) // Its UIKit disappearance.
        XCTAssertEqual(fixture.cancellations, before + 1)
        fixture.authenticationContinuation?.resume(); fixture.authenticationContinuation = nil
        await task?.value
        XCTAssertNil(fixture.coordinator.humanIdentity)
    }

    func testProviderFullScreenCoverDoesNotRevokeActiveJourney() async throws {
        let fixture = JourneyFixture(); fixture.holdAuthentication = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let hosting = UIHostingController(rootView: fixture.view)
        let window = UIWindow(windowScene: scene); window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        hosting.view.layoutIfNeeded(); await Task.yield()
        let task = try fixture.actions.signIn(.google)
        while fixture.authenticationContinuation == nil { await Task.yield() }
        let beforeCover = fixture.cancellations
        let covered = UIViewController(); covered.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in hosting.present(covered, animated: false) { continuation.resume() } }
        XCTAssertEqual(fixture.cancellations, beforeCover, "A provider cover must not revoke sign-in")
        XCTAssertTrue(fixture.coordinator.isWorking)
        await withCheckedContinuation { continuation in covered.dismiss(animated: false) { continuation.resume() } }
        fixture.authenticationContinuation?.resume(); fixture.authenticationContinuation = nil
        await task?.value
        XCTAssertNotNil(fixture.coordinator.humanIdentity)
    }

    func testDismissedJourneyRevokesHeldAuthentication() async throws {
        let fixture = JourneyFixture(); fixture.holdAuthentication = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController(), window = UIWindow(windowScene: scene)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let hosting = UIHostingController(rootView: fixture.view); hosting.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in root.present(hosting, animated: false) { continuation.resume() } }
        let task = try fixture.actions.signIn(.google)
        while fixture.authenticationContinuation == nil { await Task.yield() }
        let beforeDismissal = fixture.cancellations
        await withCheckedContinuation { continuation in hosting.dismiss(animated: false) { continuation.resume() } }
        XCTAssertEqual(fixture.cancellations, beforeDismissal + 1)
        XCTAssertFalse(fixture.coordinator.isWorking)
        fixture.authenticationContinuation?.resume(); fixture.authenticationContinuation = nil
        await task?.value
        XCTAssertNil(fixture.coordinator.humanIdentity)
    }

    func testPhoneTabletAndAccessibilityLayoutsRenderWithoutFactoryCalls() async throws {
        let fixture = JourneyFixture()
        for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852), CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768)] {
            let hosting = UIHostingController(rootView: fixture.view.environment(\.dynamicTypeSize, .accessibility3))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size); window.rootViewController = hosting
            window.makeKeyAndVisible(); hosting.view.layoutIfNeeded()
            await Task.yield(); hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "CloudJourney-\(Int(size.width))x\(Int(size.height))-Accessibility3"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(hosting.view.bounds.size, size)
            XCTAssertEqual(fixture.factories, 0); XCTAssertEqual(fixture.presentations, 0)
            window.isHidden = true; window.rootViewController = nil
        }
    }
}

private struct JourneyActualSheetFixture<Journey: View>: View {
    let journey: Journey
    let dynamicTypeSize: DynamicTypeSize
    let recordBounds: (CloudJourneyRenderedElement, CGRect) -> Void
    @State private var item: CloudAccountSheet?
    @State private var requestedPresentation = false
    var body: some View {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            .modifier(CloudAccountPresentation(item: $item) { _ in
                journey.environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.cloudJourneyRenderedBoundsObserver, recordBounds)
            })
            .onAppear {
                guard !requestedPresentation else { return }
                requestedPresentation = true; item = .init(availability: .qualified)
            }
    }
}

@MainActor
private final class JourneyConnectionCompletionState: ObservableObject {
    @Published var state = NativeEnrollmentSceneController.State.idle
    @Published var admitted: UUID?
    @Published var completed: UUID?
    @Published var message: String?
    var confirmed: UUID?
    var verifications = 0
    var renderedIntentID: UUID?
    var renderedCompletionID: UUID?
    var renderedState = NativeEnrollmentSceneController.State.idle
    func connect() { admitted = UUID(); state = .enrolling; message = nil }
    func verify(_ operationID: UUID) throws {
        guard completed == operationID, confirmed == operationID, state == .currentInstallation else { throw CancellationError() }
        verifications += 1
    }
}
private struct JourneyConnectionCompletionFixture: View {
    let fixture: JourneyFixture
    @ObservedObject var completion: JourneyConnectionCompletionState
    @State private var intent = CloudConnectPresentationIntent()
    private var actions: CloudAccountJourneyActions {
        var actions = fixture.actions
        actions.suggestedDeviceName = "Fixture device"
        actions.enrollmentState = completion.state; actions.deliveryMessage = completion.message
        actions.enrollDevice = { _, _, _ in
            let previous = completion.admitted
            completion.connect()
            intent.captureAdmission(previous: previous, admitted: completion.admitted)
        }
        completion.renderedIntentID = intent.operationID
        completion.renderedState = completion.state
        completion.renderedCompletionID = intent.matchingCompletion(completion.completed)
        if let operationID = completion.renderedCompletionID {
            actions.connectionCompletion = .init(operationID: operationID, verify: { try completion.verify(operationID) })
        }
        return actions
    }
    var body: some View { CloudAccountJourneyView(lifecycle: fixture.lifecycle, actions: actions) }
}

private actor JourneyEnrollmentWorkGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}

@MainActor
private final class JourneyFixture {
    let lifecycle: CloudHumanSessionLifecycle
    let journal = JourneyJournal()
    let transport = JourneyTransport()
    let availability: CloudJourneyAvailability
    private(set) var factories = 0, presentations = 0
    private(set) var providers: [CloudNativeSignInProvider] = []
    var holdAuthentication = false
    var authenticationContinuation: CheckedContinuation<Void, Never>?
    var cancellations = 0
    var holdSignOut = false
    var signOutContinuation: CheckedContinuation<Void, Error>?
    lazy var presentation = CloudProviderPresentation(testResolve: { [weak self] in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        self.presentations += 1; return .init(controller: UIViewController(), window: UIWindow())
    })
    lazy var coordinator = CloudConnectionCoordinator(authenticate: { [weak self] provider in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        _ = try self.presentation.resolve(); self.providers.append(provider)
        if self.holdAuthentication { await withCheckedContinuation { self.authenticationContinuation = $0 } }
        return JourneyTokens()
    }, cancelIdentityFlow: { [weak self] in self?.cancellations += 1 }, signOutIdentity: { [weak self] in
        guard let self else { return }
        if self.holdSignOut { try await withCheckedThrowingContinuation { self.signOutContinuation = $0 } }
    }, makeClient: { [weak self] tokens in
        guard let self else { throw CloudNativeIdentityError.cancelled }
        return try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: tokens, transport: self.transport)
    }, journal: journal)
    init(availability: CloudJourneyAvailability = .qualified, broker: CloudHumanSessionBroker? = nil) { self.availability = availability; lifecycle = CloudHumanSessionLifecycle(broker: broker ?? CloudHumanSessionBroker()) }
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
private final class JourneyJournal: CloudWorkspaceSetupJournal {
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
private struct JourneyTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "fixture-token" } }
private actor JourneyTransport: HTTPTransport {
    static let accountID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var failure: Int?
    private var hasAccounts = false
    private var enrollmentChoices: (workspaces: Int, locations: Int)?
    private var unassignedEnrollmentAllowed = true
    private var nativeSignInHeld = false
    private var nativeSignInContinuation: CheckedContinuation<Void, Never>?
    var nativeSignInReturnIsHeld: Bool { nativeSignInContinuation != nil }
    func holdNativeSignInReturn() { nativeSignInHeld = true }
    func releaseNativeSignInReturn() {
        nativeSignInHeld = false
        let continuation = nativeSignInContinuation; nativeSignInContinuation = nil
        continuation?.resume()
    }
    private(set) var posts: [CloudNativeWorkspaceSetupRequest] = []
    private(set) var lookups: [UUID] = []
    func setFailure(_ status: Int?) { failure = status }
    func setAccounts(_ value: Bool) { hasAccounts = value }
    func setEnrollmentChoices(workspaces: Int, locations: Int) { enrollmentChoices = (workspaces, locations) }
    func setUnassignedEnrollmentAllowed(_ allowed: Bool) { unassignedEnrollmentAllowed = allowed }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        let path = request.url.path
        if path == "/v1/native/sign-in" {
            if nativeSignInHeld { await withCheckedContinuation { nativeSignInContinuation = $0 } }
            return .init(status: 200, body: Data(#"{"user":{"id":"22222222-2222-4222-8222-222222222222","displayName":"Fixture person","email":null},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#.utf8))
        }
        if path == "/v1/native/accounts" {
            if let enrollmentChoices {
                let items = (0..<enrollmentChoices.workspaces).map { index in
                    ["id": index == 0 ? Self.accountID.uuidString : "55555555-5555-4555-8555-555555555555",
                     "name": "Fixture workspace \(index + 1)", "createdAt": "2026-10-02", "updatedAt": "2026-10-02",
                     "capabilities": ["owner": unassignedEnrollmentAllowed, "administrator": unassignedEnrollmentAllowed, "canEnroll": true]] as [String: Any]
                }
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["items": items, "nextCursor": NSNull()]))
            }
            return .init(status: 200, body: Data((hasAccounts ? #"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Fixture workspace","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"owner":true,"administrator":true,"canEnroll":true}}],"nextCursor":null}"# : #"{"items":[],"nextCursor":null}"#).utf8))
        }
        if path.hasSuffix("/locations") {
            if let enrollmentChoices {
                let items = (1...max(1, enrollmentChoices.locations)).prefix(enrollmentChoices.locations).map { index in
                    ["id": "33333333-3333-4333-8333-\(String(format: "%012d", index))", "name": "Fixture location \(index)",
                     "createdAt": "2026-10-02", "updatedAt": "2026-10-02",
                     "capabilities": ["canView": true, "canOperate": true, "canEnroll": true]] as [String: Any]
                }
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["items": items, "nextCursor": NSNull()]))
            }
            return .init(status: 200, body: Data(#"{"items":[{"id":"33333333-3333-4333-8333-333333333333","name":"Fixture location","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"canView":true,"canOperate":false,"canEnroll":false}}],"nextCursor":null}"#.utf8))
        }
        let id: UUID
        if request.method == "POST" {
            let setup = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(request.body)); posts.append(setup); id = setup.requestId
        } else { id = try XCTUnwrap(UUID(uuidString: request.url.lastPathComponent)); lookups.append(id) }
        if let failure { return .init(status: failure, body: Data(#"{"code":"workspace_setup_unavailable","message":"raw-fixture-diagnostic","requestId":"trace-fixture"}"#.utf8)) }
        return .init(status: 200, body: Data("{\"requestId\":\"\(id.uuidString)\",\"accountId\":\"11111111-1111-4111-8111-111111111111\",\"locationId\":\"33333333-3333-4333-8333-333333333333\",\"createdAt\":\"2026-10-02T16:00:00Z\"}".utf8))
    }
}
