import XCTest
import Darwin
import Security
import Combine
import WebKit
import SwiftUI
import UIKit
@_spi(NativeFilesystem) @_spi(NativeInstallation) @_spi(DeviceGrantTransport) @_spi(ManagedRender) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple
@testable import Screenpunk

final class NativeEnrollmentSceneControllerTests: XCTestCase {
    @MainActor func testMountedDetachedLocalRootKeepsDOMAcrossOrdinarySuspensionAndCoalescedResume() async throws {
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        defer { deviceTLS.close() }
        var localSource: DeviceLegacyMigrationSession?
        let fixture = try await GenuineUnifiedInventoryFixture.make(prepareLocal: { authority, parent in
            let local = try NativePreparedConnectionFixture.prepareRetainedLocalScreen(authority: authority, parent: parent)
            localSource = local
            return local
        })
        defer { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let revoke = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await revoke.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation(), namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for credential in retirement.credentials { try fixture.removeCloudCredentialExact(credential) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let admission = NativeSessionAdmissionProbe()
        // Reopen the actual persisted completed Local graph, with its real owner
        // validation. The existing synchronous fixture checkpoint only holds a
        // genuine worker admission; it cannot authorize a mount or alter storage.
        let session = try DeviceUnifiedInventorySession.restoreDetached(local: XCTUnwrap(localSource),
            commonRoot: candidate.commonRoot, commonRootID: candidate.commonRootID,
            validateOriginal: {
                try fixture.authority.validateDetachedLocalResources(candidate)
                try admission.checkpoint()
                try Task.checkCancellation()
            }, validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(session, context: candidate)
        let expected = try session.validatedAssociation()
        XCTAssertEqual(expected.entries.count, 1)
        XCTAssertEqual(expected.entries.first?.provenance, "retainedLocal")
        XCTAssertNotNil(expected.configuredEntryID)
        let journal = NativeEnrollmentIntentJournal(directory: fixture.parent.appendingPathComponent("continuity-intent"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var admissions = 0
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty }, hostFactory: { context in
            admissions += 1
            return try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("continuity-host-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let scene = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: session,
            context: candidate, bootstrap: bootstrap) { _, _ in throw NativeRecoveryFixtureFailure.unexpectedEffect }
        defer { admission.release(); scene.didEnterBackground() }
        let currentURL = candidate.commonRoot.appendingPathComponent("mixed-current.json")
        let currentBytes = try Data(contentsOf: currentURL), requests = fixture.http.requestCount
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene), phase = SceneLANPhaseDriver(phase: .active)
        var observedPhase: ScenePhase?
        let hosting = UIHostingController(rootView: SceneLANLifecycleFixture(driver: phase, content:
            SceneLANPhaseObserver(content: CloudSceneRoot(cloud: CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()),
                bootstrap: bootstrap, enrollment: scene), observe: { observedPhase = $0 })))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return scene.candidateMounted && !sceneLANWebViews(in: hosting.view).isEmpty
        }
        let content = try XCTUnwrap(scene.content), lifetime = try XCTUnwrap(scene.presentationLifetime)
        let host = try XCTUnwrap(scene.commonHost)
        let runtime = try XCTUnwrap(scene.presentationFrames.first { $0.candidate }?.runtime)
        let web = try XCTUnwrap(sceneLANWebViews(in: hosting.view).first)
        XCTAssertEqual(admissions, 1)
        XCTAssertEqual(content.generationID, expected.generationID); XCTAssertEqual(content.entryID, expected.configuredEntryID)
        let mountedURL = candidate.commonRoot.appendingPathComponent("mixed-mounted.json")
        let mountedBytes = try Data(contentsOf: mountedURL)
        let nonce = UUID().uuidString
        _ = try await web.evaluateJavaScript("globalThis.__continuityNonce='\(nonce)'; globalThis.__continuityReplies=[]; const previous=globalThis.__screenpunkDispatch; globalThis.__screenpunkDispatch=(message)=>{if(message.id && message.id.startsWith('continuity-'))globalThis.__continuityReplies.push(message);if(typeof previous==='function')previous(message);}; void 0;")
        func sameFrameAndWeb() -> Bool {
            scene.content === content && scene.presentationLifetime === lifetime && !lifetime.isRetired
                && scene.commonHost === host && scene.presentationFrames.first { $0.candidate }?.runtime === runtime
                && sceneLANWebViews(in: hosting.view).contains { $0 === web }
        }
        func postNative(_ id: String) async throws {
            _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.screenpunk.postMessage({protocolVersion:1,kind:'request',id:'\(id)',method:'navigation.get'}); void 0;")
        }
        func replyCount(_ id: String) async throws -> Int {
            (try await web.evaluateJavaScript("globalThis.__continuityReplies.filter(message=>message.id==='\(id)' && message.ok===true).length") as? Int) ?? -1
        }
        phase.phase = .background
        try await waitForProductionSequence { hosting.view.layoutIfNeeded(); return observedPhase == .background }
        XCTAssertTrue(sameFrameAndWeb(), "Ordinary suspension must keep the genuinely mounted WK document and frame")
        // Stop the old-production counterfactual here after its decisive real
        // teardown failure; subsequent assertions require that retained document.
        guard sameFrameAndWeb() else { return }
        let pausedEntries = admission.entries
        try await postNative("continuity-background")
        let backgroundReplies = try await replyCount("continuity-background")
        XCTAssertEqual(backgroundReplies, 0)
        XCTAssertEqual(admission.entries, pausedEntries, "Closed native input must deny BEFORE Core graph locks")
        do {
            _ = try await scene.invokeService(expectedContent: content, expectedLifetime: lifetime,
                invocationID: UUID(), bindingID: UUID(), operation: "weather.read", input: "synthetic")
            XCTFail("Suspended native effect was admitted")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(admission.entries, pausedEntries)
        admission.arm()
        let boundedRelease = NativeSessionAdmissionEscape(admission: admission, after: 10)
        defer { boundedRelease.cancel() }
        phase.phase = .active
        try await waitForProductionSequence { observedPhase == .active && admission.entered }
        let heldEntries = admission.entries
        let layoutStarted = ProcessInfo.processInfo.systemUptime
        for _ in 0..<8 { hosting.view.setNeedsLayout(); hosting.view.layoutIfNeeded() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - layoutStarted, 1)
        XCTAssertTrue(sameFrameAndWeb())
        let heldNonce = try await web.evaluateJavaScript("globalThis.__continuityNonce") as? String
        XCTAssertEqual(heldNonce, nonce, "Same pixels must be the same document, not a new load")
        try await postNative("continuity-pending")
        let pendingReplies = try await replyCount("continuity-pending")
        XCTAssertEqual(pendingReplies, 0)
        XCTAssertEqual(admission.entries, heldEntries, "Pending resume callbacks cannot enter held verification on MainActor")
        // Multiple real phase changes arrive while a cancelled synchronous unit
        // still owns its session. No overlapping resume or late reopening.
        phase.phase = .background
        try await waitForProductionSequence { observedPhase == .background }
        phase.phase = .active
        try await waitForProductionSequence { observedPhase == .active }
        phase.phase = .background
        try await waitForProductionSequence { observedPhase == .background }
        XCTAssertEqual(admission.entries, heldEntries)
        boundedRelease.cancel()
        XCTAssertFalse(boundedRelease.fired, "The independent escape must not be needed for UI/lifecycle progress")
        admission.release()
        try await waitForProductionSequence { !scene.hasActiveEnrollmentWork }
        XCTAssertTrue(sameFrameAndWeb())
        try await postNative("continuity-stale")
        let staleReplies = try await replyCount("continuity-stale")
        XCTAssertEqual(staleReplies, 0, "Finishing the cancelled owner cannot reopen a background document")
        let beforeFinalResume = admission.entries
        phase.phase = .active
        try await waitForProductionSequence {
            observedPhase == .active && admission.entries > beforeFinalResume && !scene.hasActiveEnrollmentWork
        }
        try await postNative("continuity-resumed")
        var resumedReplies = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while resumedReplies == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            resumedReplies = try await replyCount("continuity-resumed")
            if resumedReplies == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(resumedReplies, 1, "After current verification the retained native bridge must be interactive again")
        XCTAssertTrue(sameFrameAndWeb()); XCTAssertEqual(admissions, 1)
        let resumedNonce = try await web.evaluateJavaScript("globalThis.__continuityNonce") as? String
        XCTAssertEqual(resumedNonce, nonce)
        XCTAssertEqual(try Data(contentsOf: currentURL), currentBytes)
        XCTAssertEqual(try Data(contentsOf: mountedURL), mountedBytes)
        XCTAssertEqual(fixture.http.requestCount, requests, "No Cloud authorization or new delivery on ordinary resume")
        XCTAssertNil(try journal.load())
        // Explicit terminal retirement remains separate from ordinary OS phase.
        scene.didEnterBackground()
        XCTAssertTrue(lifetime.isRetired); XCTAssertNil(scene.content); XCTAssertNil(scene.commonHost)
        try await waitForProductionSequence { hosting.view.layoutIfNeeded(); return sceneLANWebViews(in: hosting.view).isEmpty }
    }

    @MainActor func testInitialCloudManagedLocalFrameMountsWithoutOptionalLANHost() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(retainedLocalScreen: true, cloudProtocolFixture: true)
        defer { fixture.close(); fixture.controller.didEnterBackground() }
        let expected = try fixture.unified.validatedAssociation()
        XCTAssertEqual(expected.entries.first?.provenance, "retainedLocal")
        XCTAssertNil(fixture.controller.commonHost)
        XCTAssertFalse(fixture.controller.isCloudLoggedOut)
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene)
        let phase = SceneLANPhaseDriver(phase: .active)
        let hosting = UIHostingController(rootView: SceneLANLifecycleFixture(driver: phase,
            content: CloudSceneRoot(cloud: CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()),
                bootstrap: fixture.bootstrap, enrollment: fixture.controller)))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        // Exercise the genuine Cloud-owned selected Local frame path before an
        // optional Host exists. This fixture has no completed Cloud static-delivery
        // graph to cold-restore; Root/WK alone supplies the actual mount proof.
        let prepared = try await fixture.controller.prepareUnifiedContent(fixture.unified, operationID: UUID())
        fixture.controller.stagePresentation(prepared, current: nil)
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return fixture.controller.candidateMounted && !sceneLANWebViews(in: hosting.view).isEmpty
        }
        let content = try XCTUnwrap(fixture.controller.content)
        let frame = try XCTUnwrap(fixture.controller.presentationFrames.first { $0.candidate })
        let runtime = try XCTUnwrap(frame.runtime)
        XCTAssertTrue(frame.content === content); XCTAssertTrue(runtime.content === content)
        XCTAssertEqual(content.generationID, expected.generationID)
        XCTAssertEqual(content.entryID, expected.configuredEntryID)
        XCTAssertNil(fixture.controller.commonHost, "Cloud does not require an optional LAN host to render")
        XCTAssertNoThrow(try runtime.verifyActive(), "Only the real Root/WK mount callback admits this runtime")
        XCTAssertEqual(try fixture.unified.mountedAssociation()?.entryID, expected.configuredEntryID)
        let web = try XCTUnwrap(sceneLANWebViews(in: hosting.view).first)
        let body = try await web.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(body?.contains("Retained Local presentation") == true)
    }

    @MainActor func testScreenInventoryMenuLayoutDoesNotEnterHeldGenuineLocalValidator() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(retainedLocalScreen: true, cloudProtocolFixture: true)
        defer { fixture.close() }
        let admission = NativeSessionAdmissionProbe()
        let session = try fixture.makeContendedSession { try admission.checkpoint() }
        let controller = try fixture.makeAutomaticDriverController(session: session)
        defer { admission.release(); controller.didEnterBackground() }
        let expected = try session.validatedAssociation()
        XCTAssertEqual(expected.entries.count, 1)
        XCTAssertEqual(expected.entries.first?.provenance, "retainedLocal")
        XCTAssertEqual(try controller.installedCloudScreens().entries.map(\.id), expected.entries.map(\.entryID))
        XCTAssertEqual(try controller.installedCloudScreens().selectedEntryID, expected.configuredEntryID)
        try await waitForProductionSequence { controller.displayInstalledManifests.count == expected.entries.count }

        // Own the real session gate on a non-main thread. The same validator
        // previously entered from menu layout must not run on this UI path.
        admission.arm()
        let validation = Task.detached { () -> (Bool, Bool) in
            let wasMain = Thread.isMainThread
            do { _ = try session.validatedAssociation(); return (true, wasMain) } catch { return (false, wasMain) }
        }
        try await waitForProductionSequence { admission.entered }
        let heldEntries = admission.entries
        // Bounded escape for the counterfactual synchronous getter, so a RED
        // assertion does not strand the test's UI thread or fixture teardown.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { admission.release() }
        let began = ProcessInfo.processInfo.systemUptime
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene)
        let hosting = UIHostingController(rootView: CloudDeviceScreensView(inventory: CloudDeviceScreenList(enrollment: controller)))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for _ in 0..<12 {
            XCTAssertEqual(try controller.installedCloudScreens().selectedEntryID, expected.configuredEntryID)
            let list = CloudDeviceScreenList(enrollment: controller)
            XCTAssertEqual(list.count, 1)
            hosting.rootView = CloudDeviceScreensView(inventory: list)
            hosting.view.setNeedsLayout(); hosting.view.layoutIfNeeded()
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5, "Menu layout cannot wait for graph IO held on another executor")
        XCTAssertEqual(admission.entries, heldEntries, "Repeated layout/getters cannot request another qualification")
        let uiTurn = Task { @MainActor in true }
        let uiTurnCompleted = await uiTurn.value
        XCTAssertTrue(uiTurnCompleted)
        controller.didEnterBackground()
        XCTAssertNil(controller.displayScreenInventory)
        XCTAssertThrowsError(try controller.installedCloudScreens())
        XCTAssertNil(CloudDeviceScreenList(enrollment: controller).count, "Unavailable is not a qualified empty inventory")
        admission.release()
        let (_, validationWasMain) = await validation.value
        XCTAssertFalse(validationWasMain)
        XCTAssertNil(controller.displayScreenInventory, "Finishing old validation cannot publish into a retired lifecycle")
    }

    @MainActor func testInstalledManifestProjectionRejectsRetiredInFlightGenuineCapture() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(retainedLocalScreen: true, cloudProtocolFixture: true)
        defer { fixture.close() }
        let admission = NativeSessionAdmissionProbe()
        let session = try fixture.makeContendedSession { try admission.checkpoint() }
        let controller = try fixture.makeAutomaticDriverController(session: session)
        defer { admission.release(); controller.didEnterBackground() }
        admission.arm()
        try await waitForProductionSequence { admission.entered }
        XCTAssertEqual(admission.firstThreadAfterArmWasMain, false)
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<12 {
            XCTAssertEqual(controller.displayScreenInventory?.entries.count, 1)
            XCTAssertTrue(controller.displayInstalledManifests.isEmpty, "A held graph cannot fabricate installed manifest metadata")
            await Task.yield()
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5, "Metadata layout/getters must not wait for the real held validator")
        controller.didEnterBackground()
        admission.release()
        try await waitForProductionSequence { !controller.hasPendingDisplayMetadataCaptureForTesting }
        XCTAssertNil(controller.displayScreenInventory)
        XCTAssertTrue(controller.displayInstalledManifests.isEmpty, "The completed old worker cannot publish metadata after its owner/epoch retired")
        XCTAssertNil(controller.content); XCTAssertNil(controller.commonHost)
    }

    @MainActor func testInstalledManifestProjectionRejectsSelectionChangedDuringGenuineCapture() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(retainedLocalScreen: true, cloudProtocolFixture: true)
        defer { fixture.close() }
        let admission = NativeSessionAdmissionProbe()
        // Two genuine sessions share the same original durable store. The held
        // reader owns only its session gate, so a real command can change the CAS.
        let session = try fixture.makeContendedSession { try admission.checkpoint() }
        let controller = try fixture.makeAutomaticDriverController(session: session)
        defer { admission.release(); controller.didEnterBackground() }
        let initial = try controller.installedCloudScreens()
        admission.arm()
        try await waitForProductionSequence { admission.entered }
        _ = try await fixture.commitCloudSelection(retainingLocalEntries: true)
        let changed = try fixture.unified.validatedAssociation()
        XCTAssertNotEqual(changed.configuredEntryID, initial.selectedEntryID)
        XCTAssertEqual(changed.entries.filter { $0.provenance == "retainedLocal" }.map(\.entryID), initial.entries.map(\.id))
        admission.release()
        try await waitForProductionSequence { !controller.hasPendingDisplayMetadataCaptureForTesting }
        XCTAssertTrue(controller.displayInstalledManifests.isEmpty, "The old capture must fail exact-current validation after a genuine selection CAS")
        let replacement = try fixture.makeAutomaticDriverController(session: fixture.unified)
        defer { replacement.didEnterBackground() }
        try await waitForProductionSequence { replacement.displayInstalledManifests.count == changed.entries.count }
        XCTAssertEqual(replacement.displayInstalledManifests.map(\.dashboardId), changed.entries.map(\.dashboardID))
        XCTAssertTrue(controller.displayInstalledManifests.isEmpty, "A separate qualified owner cannot populate the old projection")
    }

    @MainActor func testScreenInventoryProjectionFencesGenerationLifecycleAndOwner() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        let controller = fixture.controller
        defer { controller.didEnterBackground() }
        let initial = try controller.installedCloudScreens()
        XCTAssertTrue(initial.entries.isEmpty)
        XCTAssertNil(initial.selectedEntryID)
        XCTAssertEqual(CloudDeviceScreenList(enrollment: controller).count, 0, "Qualified empty is available, not an unavailable projection")
        let (_, current) = try await fixture.commitCloudSelection()
        let selected = try fixture.unified.selectedContent(operationID: UUID())
        controller.stagePresentation(selected, current: current)
        XCTAssertNil(controller.displayScreenInventory, "A newly staged generation cannot borrow the previous projection")
        XCTAssertThrowsError(try controller.installedCloudScreens())
        let prepared = try await controller.prepareUnifiedContent(fixture.unified, operationID: UUID())
        controller.stagePresentation(prepared, current: current)
        let actual = try fixture.unified.validatedAssociation()
        let refreshed = try controller.installedCloudScreens()
        XCTAssertEqual(refreshed.entries.map(\.id), actual.entries.map(\.entryID))
        XCTAssertEqual(refreshed.selectedEntryID, actual.configuredEntryID)
        XCTAssertEqual(refreshed.entries.first { $0.id == refreshed.selectedEntryID }?.source, "cloud")
        controller.didEnterBackground()
        XCTAssertNil(controller.displayScreenInventory)
        let replacement = try await NativePreparedConnectionFixture.make(retainedLocalScreen: true, cloudProtocolFixture: true)
        defer { replacement.controller.didEnterBackground(); replacement.close() }
        let replacementInventory = try replacement.controller.installedCloudScreens()
        XCTAssertEqual(replacementInventory.entries.count, 1)
        XCTAssertNotEqual(replacementInventory.selectedEntryID, refreshed.selectedEntryID)
        XCTAssertNil(controller.displayScreenInventory, "A different admitted owner cannot repopulate the old lifecycle")
    }

    @MainActor func testProductionAutomaticDriverDoesNotRejectCloudDeliveryAsReentrant() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        fixture.http.productionSequenceEnabled = true
        let overlap = NativeAutomaticDriverOverlap()
        let admission = NativeSessionAdmissionProbe()
        var nested: (() throws -> Void)?
        let session = try fixture.makeContendedSession {
            try nested?()
            try admission.checkpoint()
            try overlap.checkpoint()
        }
        // True synchronous recursion still fails immediately; this guard must
        // survive automatic-driver scheduling changes.
        nested = { _ = try session.validatedAssociation() }
        XCTAssertThrowsError(try session.validatedAssociation()) {
            XCTAssertEqual($0 as? DeviceLocalResourceGateFailure, .reentrant)
        }
        nested = nil
        let driver = session.makeTemporaryActivationDriver(http: URLSessionHTTPTransport(), resolver: LiteralOrResolvedDestinationResolver())
        // A real ordinary session owner blocks the actual driver's admission;
        // after release the original validators must still run successfully.
        admission.arm()
        let sessionOwner = Task.detached { try session.validatedAssociation() }
        try await waitForProductionSequence { admission.entered }
        let before = admission.entries
        let polling = Task { try await driver.poll() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(admission.entries, before, "Contending driver must wait before validator entry")
        admission.release()
        let firstPoll = try await polling.value
        XCTAssertFalse(firstPoll)
        _ = try await sessionOwner.value
        // Reverse ownership: the actual driver owns a synchronous session phase.
        // Registry-held callers must reject BEFORE waiting, and ordinary callers
        // wait until the owner exits, then revalidate the genuine association.
        admission.arm()
        let driverOwner = Task { try await driver.poll() }
        try await waitForProductionSequence { admission.entered }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { admission.release() }
        try DeviceLocalResourceRegistry.beginOrdinary()
        let rejectedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try session.validatedAssociation()) {
            XCTAssertEqual($0 as? DeviceLocalResourceGateFailure, .reentrant)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - rejectedAt, 0.5, "Registry-held caller cannot wait on the owner")
        DeviceLocalResourceRegistry.endOrdinary()
        let ownedEntries = admission.entries
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { admission.release() }
        let association = try session.validatedAssociation()
        XCTAssertGreaterThan(admission.entries, ownedEntries, "Ordinary caller revalidates after serialized admission")
        XCTAssertEqual(association.commonRootID, try fixture.unified.validatedAssociation().commonRootID)
        let secondPoll = try await driverOwner.value
        XCTAssertFalse(secondPoll)
        await driver.cancel()
        let controller = try fixture.makeAutomaticDriverController(session: session)
        defer { overlap.release(); controller.didEnterBackground() }
        overlap.arm()
        try controller.startPreparedTemporaryActivationForTesting()
        try await waitForProductionSequence { overlap.entered }
        // Release the controlled startup owner from a separate thread so the
        // synchronous Scene caller can legitimately wait without a busy retry.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { overlap.release() }
        try fixture.offerCloudCommand()
        try await controller.runPreparedDeviceOnlyConnectionForTesting()
        XCTAssertEqual(controller.state, .currentInstallation, controller.deliveryMessage ?? "")
        guard let content = controller.content, let lifetime = controller.presentationLifetime else {
            XCTFail("Automatic driver must not reject genuine Cloud delivery at session admission")
            return
        }
        overlap.release()
        XCTAssertNil(controller.presentationFrames.first?.runtime)
        let outcome = try fixture.retainedCloudOutcomeBytes()
        let mounted = NativeProductionMountCallbacks(controller: controller, content: content, lifetime: lifetime)
        defer { mounted.close() }
        mounted.finish()
        try await waitForProductionSequence { fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/receipt") } }
        XCTAssertEqual(mounted.mounts, 1); XCTAssertEqual(mounted.failures, 0)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/receipt") }.map(\.bytes), [outcome])
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1)
        XCTAssertTrue(overlap.entered)
        let order = fixture.http.sequenceRequests.map(\.path)
        let structural = try XCTUnwrap(order.lastIndex(where: { $0.hasSuffix("/delivery/observations") }))
        let runtime = try XCTUnwrap(order.lastIndex(where: { $0.hasSuffix("/services/runtime-observations") }))
        let receipt = try XCTUnwrap(order.lastIndex(where: { $0.hasSuffix("/delivery/receipt") }))
        XCTAssertLessThan(structural, runtime); XCTAssertLessThan(runtime, receipt)
    }
    @MainActor func testProductionCloudReportingFailuresKeepGenuineMountAndColdStaticRestore() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        fixture.http.productionSequenceEnabled = true
        try fixture.offerCloudCommand()
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        let content = try XCTUnwrap(fixture.controller.content), lifetime = try XCTUnwrap(fixture.controller.presentationLifetime)
        let outcome = try fixture.retainedCloudOutcomeBytes()
        fixture.http.sequenceObservationFailures = 1
        let first = NativeProductionMountCallbacks(controller: fixture.controller, content: content, lifetime: lifetime)
        defer { first.close() }
        first.finish()
        try await waitForProductionSequence { first.mounts == 1 || first.failures == 1 }
        XCTAssertEqual(first.mounts, 1); XCTAssertEqual(first.failures, 0)
        XCTAssertEqual(try fixture.unified.mountStateAssociation().state, "ready")
        XCTAssertNil(try fixture.mountFailureBytes())
        fixture.http.sequenceRuntimeFailures = 1
        let second = NativeProductionMountCallbacks(controller: fixture.controller, content: content, lifetime: lifetime)
        defer { second.close() }
        second.finish()
        try await waitForProductionSequence { second.mounts == 1 || second.failures == 1 }
        XCTAssertEqual(second.mounts, 1); XCTAssertEqual(second.failures, 0)
        XCTAssertEqual(try fixture.unified.mountStateAssociation().state, "ready")
        XCTAssertNil(try fixture.mountFailureBytes())
        let coldFixture = try await fixture.makeColdProductionController()
        let cold = coldFixture.controller
        defer { cold.didEnterBackground(); _ = coldFixture.bootstrap }
        try await cold.runPreparedDeviceOnlyConnectionForTesting(restorePresentation: true)
        let restored = try XCTUnwrap(cold.content), restoredLifetime = try XCTUnwrap(cold.presentationLifetime)
        XCTAssertFalse(restored === content)
        XCTAssertEqual(restored.generationID, content.generationID); XCTAssertEqual(restored.entryID, content.entryID)
        XCTAssertNil(cold.presentationFrames.first?.runtime, "Cold Cloud restoration must use the genuine static projection")
        let mounted = NativeProductionMountCallbacks(controller: cold, content: restored, lifetime: restoredLifetime)
        defer { mounted.close() }
        mounted.finish()
        try await waitForProductionSequence { fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/receipt") } }
        XCTAssertNil(try fixture.mountFailureBytes())
        let structural = fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/observations") }
        XCTAssertEqual(structural.count, 2); XCTAssertEqual(structural.first?.bytes, structural.last?.bytes)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/services/runtime-observations") }.count, 2)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/receipt") }.count, 1)
        XCTAssertEqual(fixture.http.sequenceRequests.last(where: { $0.path.hasSuffix("/delivery/receipt") })?.bytes, outcome)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1)
    }
    @MainActor func testProductionCloudColdRestoreRevalidatesSameGenerationMountedValidationFailure() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        fixture.http.productionSequenceEnabled = true
        try fixture.offerCloudCommand()
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        let content = try XCTUnwrap(fixture.controller.content), lifetime = try XCTUnwrap(fixture.controller.presentationLifetime)
        let outcome = try fixture.retainedCloudOutcomeBytes()
        fixture.http.sequenceObservationFailures = 1
        let first = NativeProductionMountCallbacks(controller: fixture.controller, content: content, lifetime: lifetime)
        defer { first.close() }
        first.finish()
        try await waitForProductionSequence { first.mounts == 1 }
        // Historical input reproduces the real pre-repair host callbacks: a
        // qualified mounted success followed by mount-validation failure. No
        // outbox, credential, grant, or journal bytes are manually fabricated.
        fixture.http.sequenceMountFailureReportFailures = 1
        await fixture.controller.reportMountFailed(expectedContent: content, expectedLifetime: lifetime, code: "mount_validation_failed")
        let failedBytes = try XCTUnwrap(fixture.mountFailureBytes())
        XCTAssertEqual(try fixture.unified.mountedAssociation()?.generationID, content.generationID)
        XCTAssertEqual(try fixture.unified.mountStateAssociation().failureCode, "mount_validation_failed")
        let failureRequests = failedProgressCount(fixture.http)
        let coldFixture = try await fixture.makeColdProductionController()
        let cold = coldFixture.controller
        defer { cold.didEnterBackground(); _ = coldFixture.bootstrap }
        try await cold.runPreparedDeviceOnlyConnectionForTesting(restorePresentation: true)
        XCTAssertNotNil(cold.content, cold.deliveryMessage ?? "The genuine failed Cloud restore did not stage content")
        guard let restored = cold.content, let restoredLifetime = cold.presentationLifetime else { return }
        XCTAssertEqual(cold.state, .currentInstallation, cold.deliveryMessage ?? "")
        XCTAssertFalse(restored === content); XCTAssertFalse(restoredLifetime === lifetime)
        XCTAssertEqual(restored.generationID, content.generationID); XCTAssertEqual(restored.entryID, content.entryID)
        XCTAssertNil(cold.presentationFrames.first?.runtime)
        XCTAssertFalse(cold.candidateMounted)
        XCTAssertEqual(try fixture.mountFailureBytes(), failedBytes, "Only the NEW real mount callback may clear the failure")
        XCTAssertEqual(failedProgressCount(fixture.http), failureRequests)
        XCTAssertFalse(fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/receipt") })
        let mounted = NativeProductionMountCallbacks(controller: cold, content: restored, lifetime: restoredLifetime)
        defer { mounted.close() }
        mounted.finish()
        try await waitForProductionSequence { fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/receipt") } }
        XCTAssertEqual(mounted.failures, 0)
        XCTAssertNil(try fixture.mountFailureBytes())
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/services/runtime-observations") }.count, 1)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/receipt") }.count, 1)
        XCTAssertEqual(fixture.http.sequenceRequests.last(where: { $0.path.hasSuffix("/delivery/receipt") })?.bytes, outcome)
        XCTAssertEqual(try fixture.retainedCloudOutcomeBytes(), outcome)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1)
        await fixture.controller.reportMountFailed(expectedContent: content, expectedLifetime: lifetime, code: "mount_validation_failed")
        XCTAssertNil(try fixture.mountFailureBytes(), "A stale renderer cannot poison the restored exact frame")
    }
    @MainActor func testProductionCloudNavigationFailureRemainsFailedAcrossColdRestore() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        fixture.http.productionSequenceEnabled = true
        try fixture.offerCloudCommand()
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        let content = try XCTUnwrap(fixture.controller.content), lifetime = try XCTUnwrap(fixture.controller.presentationLifetime)
        let callbacks = NativeProductionMountCallbacks(controller: fixture.controller, content: content, lifetime: lifetime)
        defer { callbacks.close() }
        callbacks.failNavigation()
        try await waitForProductionSequence { callbacks.failures == 1 }
        XCTAssertEqual(callbacks.failureCodes, ["navigation_failed"])
        XCTAssertEqual(try fixture.unified.mountStateAssociation().failureCode, "navigation_failed")
        let bytes = try XCTUnwrap(fixture.mountFailureBytes())
        let coldFixture = try await fixture.makeColdProductionController()
        let cold = coldFixture.controller
        defer { cold.didEnterBackground(); _ = coldFixture.bootstrap }
        try await cold.runPreparedDeviceOnlyConnectionForTesting(restorePresentation: true)
        XCTAssertNil(cold.content, "A genuine navigation failure must not be turned into a validation retry")
        XCTAssertEqual(try fixture.mountFailureBytes(), bytes)
        XCTAssertFalse(fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/services/runtime-observations") || $0.path.hasSuffix("/delivery/receipt") })
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1)
    }
    @MainActor func testProductionCloudInitialActivationReportsStructureThenRuntimeThenOriginalReceipt() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        fixture.http.productionSequenceEnabled = true
        try fixture.offerCloudCommand()
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        XCTAssertEqual(fixture.controller.state, .currentInstallation, fixture.controller.deliveryMessage ?? "")
        XCTAssertTrue(fixture.http.sequenceRequests.contains { $0.path == "/v1/native/installations/status" },
            "The real fixed HTTPS collector must reach the host-scoped protocol fixture")
        let content = try XCTUnwrap(fixture.controller.content, fixture.controller.deliveryMessage ?? "No production presentation")
        let lifetime = try XCTUnwrap(fixture.controller.presentationLifetime)
        XCTAssertFalse(fixture.controller.candidateMounted)
        try await fixture.controller.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        try assertProductionReportOrder(fixture.http, generation: content.generationID)
        XCTAssertTrue(fixture.controller.candidateMounted)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1)
        let outcome = try fixture.retainedCloudOutcomeBytes()
        XCTAssertEqual(fixture.http.sequenceRequests.last(where: { $0.path.hasSuffix("/delivery/receipt") })?.bytes, outcome)
    }
    @MainActor func testProductionCloudRestartMountBeforeStatusFinishesOriginalBeforeAnyNewCommand() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        // Genuine pre-repair crash boundary: the old route committed through Core,
        // with no manual observation seeding or successful renderer callback.
        let (outcome, _) = try await fixture.commitCloudSelection()
        let coldFixture = try await fixture.makeColdProductionController()
        let cold = coldFixture.controller
        defer { cold.didEnterBackground(); _ = coldFixture.bootstrap }
        fixture.http.productionSequenceEnabled = true; fixture.http.holdSequenceStatus = true
        let connection = Task { @MainActor in try await cold.runPreparedDeviceOnlyConnectionForTesting(restorePresentation: true) }
        try await waitForProductionSequence { cold.content != nil && fixture.http.sequenceHeldCount == 1 }
        let content = try XCTUnwrap(cold.content), lifetime = try XCTUnwrap(cold.presentationLifetime)
        try await cold.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        XCTAssertTrue(cold.candidateMounted)
        XCTAssertFalse(fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/services/runtime-observations") })
        fixture.http.releaseSequenceRequests()
        try await connection.value
        XCTAssertEqual(cold.state, .currentInstallation, cold.deliveryMessage ?? "")
        try assertProductionReportOrder(fixture.http, generation: content.generationID)
        XCTAssertFalse(fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/command") || $0.path.hasSuffix("/delivery/progress") || $0.path.contains("/delivery/plan/") || $0.path.contains("/delivery/package/") || $0.path.hasSuffix("/delivery/activation") },
            "A pending committed original must finish without accepting the same old command again")
        XCTAssertEqual(fixture.http.sequenceRequests.last(where: { $0.path.hasSuffix("/delivery/receipt") })?.bytes, outcome.bytes)
        XCTAssertEqual(try fixture.retainedCloudOutcomeBytes(), outcome.bytes)
    }
    @MainActor func testProductionCloudAutomaticDiscoveryRefreshRetriesMountedOriginalWithEmptyCommandQueue() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        let (outcome, _) = try await fixture.commitCloudSelection()
        let coldFixture = try await fixture.makeColdProductionController(automaticDiscovery: true)
        let cold = coldFixture.controller
        defer { cold.didEnterBackground(); _ = coldFixture.bootstrap }
        fixture.http.productionSequenceEnabled = true
        fixture.http.holdSequenceStatus = true
        fixture.http.sequenceObservationFailures = 1
        // The approved original is already committed. Discovery must handle an
        // empty queue without requiring another command to finish its reports.
        fixture.http.sequenceEmptyCommand = true
        let connection = Task { @MainActor in try await cold.runPreparedDeviceOnlyConnectionForTesting(restorePresentation: true) }
        try await waitForProductionSequence { cold.content != nil && fixture.http.sequenceHeldCount == 1 }
        let content = try XCTUnwrap(cold.content), lifetime = try XCTUnwrap(cold.presentationLifetime)
        try await cold.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        XCTAssertTrue(cold.candidateMounted)
        fixture.http.releaseSequenceRequests()
        try await connection.value
        try await waitForProductionSequence {
            fixture.http.sequenceRequests.filter { $0.path == "/v1/native/installations/status" }.count >= 2 &&
            fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/command") }
        }
        // The actual scheduler/collector has completed status and the empty
        // command response. Give its existing bounded replay a chance to run.
        for _ in 0..<100 {
            if fixture.http.sequenceRequests.contains(where: { $0.path.hasSuffix("/delivery/receipt") }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let paths = fixture.http.sequenceRequests.map(\.path)
        print("AUTOMATIC_DISCOVERY_HTTP_ORDER " + paths.joined(separator: " -> "))
        XCTAssertTrue(paths.contains("/v1/native/installations/status"), "Configured HTTPS status must actually intercept")
        XCTAssertTrue(paths.contains("/v1/native/installations/delivery/command"), "Configured HTTPS discovery command must actually intercept")
        XCTAssertTrue(cold.content === content)
        XCTAssertTrue(cold.presentationLifetime === lifetime)
        XCTAssertTrue(cold.candidateMounted)
        XCTAssertEqual(try fixture.retainedCloudOutcomeBytes(), outcome.bytes)
        XCTAssertFalse(paths.contains { $0.hasSuffix("/delivery/activation") || $0.contains("/delivery/plan/") || $0.contains("/delivery/package/") })
        let observations = fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/observations") }
        XCTAssertEqual(observations.count, 2, "A fresh authenticated empty-queue reconciliation must retry the mounted original's pending structural report")
        guard observations.count == 2 else { return }
        XCTAssertEqual(observations[0].bytes, observations[1].bytes)
        try assertProductionReportOrder(fixture.http, generation: content.generationID)
        XCTAssertEqual(fixture.http.sequenceRequests.last(where: { $0.path.hasSuffix("/delivery/receipt") })?.bytes, outcome.bytes)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/services/runtime-observations") }.count, 1)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/receipt") }.count, 1)
        try await cold.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/receipt") }.count, 1)
    }
    @MainActor func testProductionCloudReport503RetriesExactStateAndCoalescesDuplicateMounts() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true)
        defer { fixture.close() }
        fixture.http.productionSequenceEnabled = true
        try fixture.offerCloudCommand()
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        let content = try XCTUnwrap(fixture.controller.content), lifetime = try XCTUnwrap(fixture.controller.presentationLifetime)
        let outcome = try fixture.retainedCloudOutcomeBytes()
        fixture.http.sequenceObservationFailures = 1
        try await fixture.controller.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        let failed = fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/observations") }
        XCTAssertEqual(failed.count, 1)
        XCTAssertFalse(fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/services/runtime-observations") || $0.path.hasSuffix("/delivery/receipt") })
        fixture.http.holdSequenceRuntime = true
        let oldReport = Task { @MainActor in try await fixture.controller.reportMountedContent(expectedContent: content, expectedLifetime: lifetime) }
        try await waitForProductionSequence { fixture.http.sequenceHeldCount == 1 }
        try await fixture.controller.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        XCTAssertEqual(fixture.http.sequenceHeldCount, 1, "A duplicate with the same dispatch coalesces")
        // A fresh real status invalidates the old dispatch while its transport is
        // held. The valid blocked report must survive the old attempt's failure.
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        fixture.http.sequenceRuntimeFailures = 1
        fixture.http.releaseSequenceRequests()
        try await oldReport.value
        try await waitForProductionSequence { fixture.http.sequenceRequests.contains { $0.path.hasSuffix("/delivery/receipt") } }
        try assertProductionReportOrder(fixture.http, generation: content.generationID)
        let observations = fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/observations") }
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[0].bytes, observations[1].bytes, "An issued observation retries its exact durable wire body")
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/services/runtime-observations") }.count, 2,
            "Only the failed old dispatch and one valid replay may send a runtime proof")
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/receipt") }.count, 1)
        XCTAssertEqual(fixture.http.sequenceRequests.last(where: { $0.path.hasSuffix("/delivery/receipt") })?.bytes, outcome)
        let count = fixture.http.sequenceRequests.count
        try await fixture.controller.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
        XCTAssertEqual(fixture.http.sequenceRequests.count, count, "An already confirmed exact mount must not report twice")
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1)
    }
    @MainActor private func waitForProductionSequence(_ predicate: () -> Bool) async throws {
        for _ in 0..<1500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Production sequence did not reach its bounded held request/presentation")
        throw CancellationError()
    }
    private func failedProgressCount(_ http: FreshOwnerHTTP) -> Int {
        http.sequenceRequests.filter { request in
            guard request.path.hasSuffix("/delivery/progress"), let bytes = request.bytes,
                let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            return object["phase"] as? String == "failed"
        }.count
    }
    private func assertProductionReportOrder(_ http: FreshOwnerHTTP, generation: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let requests = http.sequenceRequests
        let structural = try XCTUnwrap(requests.lastIndex(where: { $0.path.hasSuffix("/delivery/observations") }), file: file, line: line)
        let runtime = try XCTUnwrap(requests.firstIndex(where: { $0.path.hasSuffix("/services/runtime-observations") }), file: file, line: line)
        let receipt = try XCTUnwrap(requests.firstIndex(where: { $0.path.hasSuffix("/delivery/receipt") }), file: file, line: line)
        XCTAssertLessThan(structural, runtime, file: file, line: line)
        XCTAssertLessThan(runtime, receipt, file: file, line: line)
        XCTAssertEqual(http.acceptedStateGenerationID, generation, file: file, line: line)
    }
    @MainActor func testRetainedLocalSelectionStillPreparesManagedPresentation() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(retainedLocalScreen: true)
        defer { fixture.close() }
        let association = try fixture.unified.validatedAssociation()
        XCTAssertEqual(association.entries.first?.provenance, "retainedLocal")
        let content = try await fixture.controller.prepareUnifiedContent(fixture.unified, operationID: UUID())
        XCTAssertEqual(content.entryID, association.configuredEntryID)
        fixture.controller.stagePresentation(content, current: nil)
        let localFrame = try XCTUnwrap(fixture.controller.presentationFrames.first)
        XCTAssertTrue(localFrame.content === content)
        let runtime = try XCTUnwrap(localFrame.runtime, "Retained Local must preserve its private managed runtime")
        XCTAssertThrowsError(try runtime.verifyActive(), "Preparation cannot grant private runtime admission")
        try content.verifyResources()
        XCTAssertNil(try fixture.unified.mountedAssociation())
        try fixture.unified.confirmMountedLocalContent(content)
        XCTAssertEqual(try fixture.unified.mountedAssociation()?.entryID, content.entryID)
        XCTAssertNoThrow(try runtime.verifyActive(), "Only the exact successful mount admits the Local runtime")
        let cloudFixture = try await NativePreparedConnectionFixture.make()
        defer { cloudFixture.close() }
        let (outcome, _) = try await cloudFixture.commitCloudSelection()
        let cloud = try await fixture.controller.prepareUnifiedContent(cloudFixture.unified, operationID: UUID())
        XCTAssertNotEqual(cloud.entryID, content.entryID, "Cloud preparation must not borrow the previously selected local package")
        XCTAssertEqual(cloud.entryID, try cloudFixture.unified.validatedAssociation().configuredEntryID)
        fixture.controller.stagePresentation(cloud, current: nil)
        let cloudFrame = try XCTUnwrap(fixture.controller.presentationFrames.first)
        XCTAssertTrue(cloudFrame.content === cloud)
        XCTAssertNil(cloudFrame.runtime, "Cloud must not carry the previously prepared Local runtime")
        XCTAssertFalse(outcome.bytes.isEmpty)
    }
    @MainActor func testCommittedCloudSelectionPreparesNativePresentationAndReportsOriginalOutcomeAfterRestart() async throws {
        let fixture = try await NativePreparedConnectionFixture.make()
        defer { fixture.close() }
        let (outcome, current) = try await fixture.commitCloudSelection()
        let committed = try fixture.unified.validatedAssociation()
        XCTAssertEqual(committed.entries.count, 1)
        XCTAssertEqual(committed.entries.first?.provenance, "cloud")
        XCTAssertNil(try fixture.unified.mountedAssociation())
        let activationRequests = fixture.http.deliveryPaths.filter { $0.hasSuffix("/activation") }.count
        let first = try await fixture.controller.prepareUnifiedContent(fixture.unified, operationID: UUID())
        XCTAssertEqual(first.entryID, committed.configuredEntryID)
        XCTAssertEqual(first.generationID, committed.generationID)
        fixture.controller.stagePresentation(first, current: current)
        XCTAssertTrue(fixture.controller.presentationFrames.first?.content === first)
        XCTAssertNil(fixture.controller.presentationFrames.first?.runtime)
        try first.verifyResources()
        XCTAssertNil(try fixture.unified.mountedAssociation(), "Projection preparation is not a successful render")

        // Model the physical failure boundary: CAS and the original outcome are
        // durable, but the app stopped before a renderer could confirm a mount.
        let restored = try fixture.restoreCommittedCloudSelection(current: current)
        let pending = try XCTUnwrap(restored.restorePendingCloudOutcome(current: current))
        XCTAssertEqual(pending.bytes, outcome.bytes)
        let content = try await fixture.controller.prepareUnifiedContent(restored, operationID: UUID())
        XCTAssertEqual(content.entryID, first.entryID)
        XCTAssertEqual(content.generationID, first.generationID)
        fixture.controller.stagePresentation(content, current: current)
        XCTAssertTrue(fixture.controller.presentationFrames.first?.content === content)
        XCTAssertNil(fixture.controller.presentationFrames.first?.runtime)
        XCTAssertThrowsError(try restored.confirmMountedLocalContent(first), "A prior renderer cannot confirm the restored presentation")
        try restored.confirmMountedLocalContent(content)
        let mounted = try restored.confirmMountedContent(content, current: current)
        _ = try fixture.installation.makeMountedContentObservationRequest(origin: fixture.http.origin,
            current: current, observation: mounted)
        while let observation = try restored.pendingCloudObservation() {
            try await fixture.installation.makeUnifiedCloudObservationRequest(origin: fixture.http.origin,
                current: current, observation: observation).performFixedTransport(configuration: fixture.http.configuration)
        }
        let acknowledgment = try await NativeDeliveryReceiptHTTPObservation.collect(body: pending,
            installation: fixture.installation, origin: fixture.http.origin, configuration: fixture.http.configuration)
        _ = try restored.retainCloudOutcomeAcknowledgment(body: pending, observation: acknowledgment)
        XCTAssertNil(try restored.restorePendingCloudOutcome(current: current))
        XCTAssertEqual(try restored.mountedAssociation()?.entryID, committed.configuredEntryID)
        XCTAssertEqual(try restored.mountStateAssociation().state, "ready")
        XCTAssertEqual(fixture.http.deliveryPaths.filter { $0.hasSuffix("/activation") }.count, activationRequests,
            "Restart presentation and historical reporting must not request another activation grant")
    }
    @MainActor func testLegacyContainerBindingsPreserveGenuineEnrollmentAcrossColdRestoreAndRealtime() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(legacyContainerLocators: true)
        defer { fixture.close() }
        let before = try NativeLegacyContainerLocatorFixture.retainedMetadata(fixture.parent)
        XCTAssertEqual(before.filter { $0.key.hasSuffix("root-binding.json") || $0.key.hasSuffix("mixed-root.json") }.count, 6)
        let first = try await fixture.restoreAfterContainerRelocation()
        let second = try await fixture.restoreAfterContainerRelocation()
        XCTAssertEqual(first.installationID, second.installationID)
        XCTAssertEqual(first.credentialGenerationID, second.credentialGenerationID)
        XCTAssertEqual(try NativeLegacyContainerLocatorFixture.retainedMetadata(fixture.parent), before,
            "Repeated current-home qualification must not rewrite any binding/genesis/original bytes")
    }
    @MainActor func testLegacyContainerMappingDoesNotAdoptWrongRootIDsOrSymlinkedCurrentNodes() async throws {
        let fixture = try await NativePreparedConnectionFixture.make(legacyContainerLocators: true)
        defer { fixture.close() }
        let before = try NativeLegacyContainerLocatorFixture.retainedMetadata(fixture.parent)
        for index in 0..<6 {
            do { _ = try await fixture.restoreAfterContainerRelocation(changedRoot: index); XCTFail("Different root ID must remain denied: \(index)") }
            catch { }
        }
        let package = fixture.parent.appendingPathComponent("Application Support/xyz.screenpunk.native-managed/packages")
        let retained = package.deletingLastPathComponent().appendingPathComponent("packages-retained")
        try FileManager.default.moveItem(at: package, to: retained)
        do {
            try FileManager.default.createSymbolicLink(at: package, withDestinationURL: retained)
            defer { try? FileManager.default.removeItem(at: package) }
            do { _ = try await fixture.restoreAfterContainerRelocation(); XCTFail("A current-path symlink must remain denied") }
            catch { }
        }
        try FileManager.default.moveItem(at: retained, to: package)
        _ = try await fixture.restoreAfterContainerRelocation()
        XCTAssertEqual(try NativeLegacyContainerLocatorFixture.retainedMetadata(fixture.parent), before)
    }
    func testLegacyLocalGrantBindingKeepsBytesAndRejectsWrongIDAndReplacementIdentity() throws {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("grants")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let scope = DevicePackageProtectedScope(legacyStateRoot: parent.appendingPathComponent("legacy"),
            legacyArchiveRoot: parent.appendingPathComponent("archives"), resetRoot: parent.appendingPathComponent("reset"),
            cloudRoot: parent.appendingPathComponent("cloud"), managementRoot: parent.appendingPathComponent("management"),
            preferencesRoot: parent.appendingPathComponent("preferences"), otherProtectedRoots: [])
        let id = UUID(), backend = NativeRelocationEmptyGrantBackend()
        func store(_ rootID: UUID) -> DeviceGrantPreparationStore {
            .init(root: root, rootID: rootID, protectedScope: scope, backend: backend)
        }
        try store(id).initializeExplicit()
        try NativeLegacyContainerLocatorFixture.seedInitialBinding(root)
        let binding = root.appendingPathComponent("root-binding.json"), bytes = try Data(contentsOf: binding)
        try store(id).initializeExplicit(); try store(id).initializeExplicit()
        XCTAssertEqual(try Data(contentsOf: binding), bytes)
        XCTAssertThrowsError(try store(UUID()).initializeExplicit())
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var identity = try XCTUnwrap(value["rootIdentity"] as? [String: Any])
        identity["inode"] = UInt64.max; value["rootIdentity"] = identity
        try NativeLegacyContainerLocatorFixture.writeExisting(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), at: binding)
        XCTAssertThrowsError(try store(id).initializeExplicit())
        try NativeLegacyContainerLocatorFixture.writeExisting(bytes, at: binding)
        try store(id).initializeExplicit()
        XCTAssertEqual(backend.mutations, 0)
    }
    func testRealtimeRolloutSuppressesFrequentSQLTicksAndDisabledBuildKeepsExistingFallback() {
        XCTAssertFalse(NativeCloudRealtimeConfiguration.enabled(info: [:]))
        XCTAssertFalse(NativeCloudRealtimeConfiguration.enabled(info: ["ScreenpunkCloudRealtimeEnabled": false]))
        let enabled = NativeCloudRealtimeConfiguration.enabled(info: ["ScreenpunkCloudRealtimeEnabled": true])
        XCTAssertTrue(enabled)
        XCTAssertEqual(NativeCloudRealtimeConfiguration.reconciliationSeconds(realtimeEnabled: enabled, concurrentControl: true), 900)
        XCTAssertEqual(NativeCloudRealtimeConfiguration.reconciliationSeconds(realtimeEnabled: enabled, concurrentControl: false), 900)
        XCTAssertEqual(NativeCloudRealtimeConfiguration.reconciliationSeconds(realtimeEnabled: enabled, concurrentControl: true, realtimeHealthy: true), 21600)
        XCTAssertEqual(NativeCloudRealtimeConfiguration.reconciliationSeconds(realtimeEnabled: false, concurrentControl: true), 5)
        XCTAssertEqual(NativeCloudRealtimeConfiguration.reconciliationSeconds(realtimeEnabled: false, concurrentControl: false), 60)
    }
    @MainActor func testRealtimeFixedSessionTransportAndRetiredOwnerCannotReconnect() async throws {
        let fixture = try await NativePreparedConnectionFixture.make()
        defer { fixture.close() }
        let session = try await fixture.fetchRealtimeSession()
        XCTAssertEqual(session.installationID, fixture.http.installationID)
        XCTAssertEqual(session.credentialGenerationID, fixture.http.generationID)
        XCTAssertEqual(session.cursor, "7")
        XCTAssertEqual(session.reconciliationMaxSeconds, 21600)
        XCTAssertTrue(fixture.http.deliveryPaths.contains("/v1/native/installations/realtime/session"))
        fixture.controller.didEnterBackground()
        do { _ = try await fixture.fetchRealtimeSession(); XCTFail("A retired native owner cannot obtain a realtime session") }
        catch { }
    }
    @MainActor func testRealtimeSessionRejectsCrossInstallationGenerationAndUnsafeEndpoints() async throws {
        let fixture = try await NativePreparedConnectionFixture.make()
        defer { fixture.close() }
        let valid = try JSONSerialization.jsonObject(with: fixture.http.realtimeSessionBytes()) as! [String: Any]
        for (key, bad) in [("installationId", UUID().uuidString), ("accountId", UUID().uuidString),
            ("transitionId", UUID().uuidString), ("credentialGenerationId", UUID().uuidString),
            ("firebaseUID", "different-owner"), ("wakePath", "v1/installations/other/wake"),
            ("presencePath", "v1/installations/other/presence"), ("cursor", "01")] {
            var object = valid; object[key] = bad
            XCTAssertThrowsError(try NativeInstallationRealtimeSession.decode(JSONSerialization.data(withJSONObject: object), activation: fixture.realtimeActivation), key)
        }
        for bad: Any in [true, 1.5, 0, 900, 21599, 21601] {
            var object = valid; object["reconciliationMaxSeconds"] = bad
            XCTAssertThrowsError(try NativeInstallationRealtimeSession.decode(JSONSerialization.data(withJSONObject: object), activation: fixture.realtimeActivation))
        }
        for bad: Any in [["0", "1"], (0..<9).map(String.init), ["0", "../other"], true] {
            var object = valid; object["presenceSlots"] = bad
            XCTAssertThrowsError(try NativeInstallationRealtimeSession.decode(JSONSerialization.data(withJSONObject: object), activation: fixture.realtimeActivation))
        }
        var invalidConnection = valid; invalidConnection["presenceConnectionId"] = "invalid"
        XCTAssertThrowsError(try NativeInstallationRealtimeSession.decode(JSONSerialization.data(withJSONObject: invalidConnection), activation: fixture.realtimeActivation))
        for url in ["http://fixture.firebaseio.com", "https://evil.test", "https://fixture.firebaseio.com/other", "https://user@fixture.firebaseio.com", "https://fixture.firebaseio.com?auth=secret"] {
            var object = valid, firebase = valid["firebase"] as! [String: Any]
            firebase["databaseURL"] = url; object["firebase"] = firebase
            XCTAssertThrowsError(try NativeInstallationRealtimeSession.decode(JSONSerialization.data(withJSONObject: object), activation: fixture.realtimeActivation))
        }
    }
    @MainActor func testRealtimeConsumerReconnectsWithoutHumanSessionAndIgnoresRetiredCallbacks() async throws {
        let fixture = try await NativePreparedConnectionFixture.make()
        defer { fixture.close() }
        let session = try await fixture.fetchRealtimeSession()
        let driver = NativeRealtimeFixtureDriver()
        let consumer = NativeCloudRealtimeConsumer(driver: driver)
        var reconciliations = 0, health: [Bool] = []
        try await consumer.start(session, healthChanged: { health.append($0) }) { reconciliations += 1 }
        let old = try XCTUnwrap(driver.event)
        old(.connected); old(.cursor("7"))
        XCTAssertEqual(reconciliations, 1, "Every connection reconciles; its unchanged snapshot does not duplicate work")
        old(.cursor("8")); old(.cursor("8")); old(.cursor("invalid"))
        XCTAssertEqual(reconciliations, 2)
        old(.disconnected)
        XCTAssertEqual(health.suffix(2), [true, false])
        consumer.acknowledgeReconciliation()
        old(.sessionRefreshRequired)
        XCTAssertFalse(consumer.isStarted, "A network reconnect requires a fresh native session/connection claim, not human OAuth")
        XCTAssertEqual(reconciliations, 3)
        old(.connected); old(.cursor("9"))
        XCTAssertEqual(reconciliations, 3)
        try await consumer.start(session) { reconciliations += 1 }
        old(.connected)
        XCTAssertEqual(reconciliations, 3, "A previous connection cannot wake a replacement owner")
        driver.event?(.connected)
        XCTAssertEqual(reconciliations, 4)
        consumer.stop()
    }
    func testCloudTargetUsesFullScreenDimensionsIndependentOfKeyboardViewport() throws {
        let physical = CGSize(width: 834, height: 1112)
        XCTAssertEqual(try NativeEnrollmentActionInput.screenViewport(screen: physical, landscape: true), CGSize(width: 1112, height: 834))
        XCTAssertEqual(try NativeEnrollmentActionInput.screenViewport(screen: physical, landscape: false), physical)
        XCTAssertThrowsError(try NativeEnrollmentActionInput.screenViewport(screen: .zero, landscape: true))
    }

    @MainActor func testPresenceFailureNotifiesConnectionRecoveryUI() async {
        let clock = EnrollmentPresenceClock()
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() })
        var failures = 0
        enum Offline: Error { case disconnected }
        scheduler.start(onFailure: { failures += 1 }) { throw Offline.disconnected }
        defer { scheduler.stop(); clock.cancel() }
        await clock.untilWaiting()
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(failures, 1)
    }

    @MainActor func testRealtimeHealthRearmsSixHourTimerWithoutInventingReconciliation() async {
        let clock = EnrollmentPresenceClock()
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() }, interval: 900)
        var requests = 0
        scheduler.start { requests += 1 }
        defer { scheduler.stop(); clock.cancel() }
        await clock.untilWaiting()
        scheduler.setInterval(21600)
        await clock.untilWaiting()
        XCTAssertEqual(scheduler.reconciliationInterval, 21600)
        XCTAssertEqual(requests, 0, "Healthy transport changes cadence; only a hint/reconnect/fallback authorizes another lookup")
        scheduler.requestReconciliation()
        for _ in 0..<1000 { if requests == 1 { break }; await Task.yield() }
        XCTAssertEqual(requests, 1, "Changed cursor does not wait six hours")
        await clock.untilWaiting()
        scheduler.setInterval(900)
        await clock.untilWaiting()
        XCTAssertEqual(scheduler.reconciliationInterval, 900)
        XCTAssertEqual(requests, 1)
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(requests, 2, "Transport-down fallback remains fifteen minutes on the controlled clock")
    }
    @MainActor func testRealtimeWakeCoalescesAcrossMainWorkWithoutFrequentPolling() async {
        let clock = EnrollmentPresenceClock()
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() })
        var reconciliations = 0
        scheduler.start { reconciliations += 1 }
        defer { scheduler.stop(); clock.cancel() }
        await clock.untilWaiting()
        scheduler.setMainWorkActive(true)
        for _ in 0..<20 { scheduler.requestReconciliation() }
        await Task.yield()
        XCTAssertEqual(reconciliations, 0)
        scheduler.setMainWorkActive(false)
        for _ in 0..<1000 { if reconciliations == 1 { break }; await Task.yield() }
        XCTAssertEqual(reconciliations, 1, "All notifications during a user operation coalesce into one authoritative lookup")
        scheduler.beginCallback()
        scheduler.requestReconciliation()
        await Task.yield(); XCTAssertEqual(reconciliations, 1)
        scheduler.endCallback()
        for _ in 0..<1000 { if reconciliations == 2 { break }; await Task.yield() }
        XCTAssertEqual(reconciliations, 2)
        scheduler.stop(); scheduler.requestReconciliation()
        await Task.yield(); XCTAssertEqual(reconciliations, 2, "Background/logout has no active worker to wake")
    }
    @MainActor func testGenuineConnectionReadyPrecedesActualEmptyMountAndBackgroundRevokesCompletion() async throws {
        let fixture = try await NativePreparedConnectionFixture.make()
        defer { fixture.close() }
        XCTAssertFalse(fixture.controller.hasRecordedCloudInstallation)
        XCTAssertNil(fixture.controller.completedExplicitConnectionOperationID)
        XCTAssertNil(try fixture.unified.mountedAssociation())
        XCTAssertFalse(fixture.http.deliveryPaths.contains { $0.hasSuffix("/services/runtime-observations") })
        let task = try fixture.connect()
        let operation = try XCTUnwrap(fixture.controller.explicitConnectionOperationID)
        XCTAssertThrowsError(try fixture.controller.requireExplicitConnectionCompletion(operationID: operation))
        try await task.value
        XCTAssertEqual(fixture.controller.completedExplicitConnectionOperationID, operation)
        XCTAssertNoThrow(try fixture.controller.requireExplicitConnectionCompletion(operationID: operation))
        XCTAssertThrowsError(try fixture.controller.requireExplicitConnectionCompletion(operationID: UUID()))
        XCTAssertNil(try fixture.unified.mountedAssociation(), "Connection readiness must never manufacture a mounted receipt")
        XCTAssertFalse(fixture.http.deliveryPaths.contains { $0.hasSuffix("/services/runtime-observations") })
        let generation = try XCTUnwrap(fixture.controller.emptyDisplayGeneration)
        await fixture.controller.reportEmptyDisplayMounted(expectedGeneration: generation)
        let mounted = try XCTUnwrap(fixture.unified.mountedAssociation())
        XCTAssertEqual(mounted.generationID, generation); XCTAssertNil(mounted.entryID)
        XCTAssertTrue(fixture.http.deliveryPaths.contains { $0.hasSuffix("/services/runtime-observations") }, "Actual later mount uses the genuine fixed HTTP request")
        XCTAssertNoThrow(try fixture.controller.requireExplicitConnectionCompletion(operationID: operation))
        fixture.controller.didEnterBackground()
        XCTAssertNil(fixture.controller.completedExplicitConnectionOperationID)
        XCTAssertThrowsError(try fixture.controller.requireExplicitConnectionCompletion(operationID: operation))
    }
    @MainActor func testForegroundDiscoveryHandsOffNonemptyCommandOnlyAfterRequestClears() async {
        let clock = EnrollmentPresenceClock()
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() })
        var polls = 0, handoffs: [UUID] = []
        var discovered: UUID?
        let operation = UUID()
        scheduler.start(afterRequest: {
            guard let discovered else { return }
            XCTAssertFalse(scheduler.hasInFlightRequest, "Normal delivery cannot start inside the discovery request it drains")
            handoffs.append(discovered)
            scheduler.setMainWorkActive(true)
        }) {
            polls += 1
            discovered = polls == 1 ? nil : operation
        }
        defer { scheduler.stop(); clock.cancel() }
        await clock.untilWaiting(); clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(polls, 1); XCTAssertTrue(handoffs.isEmpty, "Empty queues never create user work")
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(handoffs, [operation])
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(polls, 2, "The existing main delivery slot excludes the next automatic request")
        scheduler.setMainWorkActive(false); scheduler.beginCallback()
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(polls, 2, "Mounted/service reporting retains its existing exclusion")
        scheduler.endCallback()
    }
    @MainActor func testForegroundDiscoveryLateCancelledCommandCannotHandoffAfterBackgroundOrLogout() async {
        let clock = EnrollmentPresenceClock(), response = EnrollmentGuardTaskGate()
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() })
        let started = expectation(description: "authenticated discovery request in progress")
        var handoffs = 0
        scheduler.start(afterRequest: { handoffs += 1 }) {
            started.fulfill()
            await response.wait() // Models a transport finishing after cancellation.
        }
        defer { scheduler.stop(); clock.cancel(); Task { await response.release() } }
        await clock.untilWaiting(); clock.tick()
        await fulfillment(of: [started], timeout: 2)
        scheduler.stop() // Same existing stop path used by background/context/logout/reset.
        await response.release(); await scheduler.drain(); await Task.yield()
        XCTAssertEqual(handoffs, 0)
    }

    @MainActor func testNativePresenceForegroundTicksExcludeMainWorkAndMountCallbacks() async {
        let clock = EnrollmentPresenceClock()
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() })
        var sends = 0
        scheduler.start { sends += 1 }
        defer { scheduler.stop(); clock.cancel() }
        await clock.untilWaiting()
        clock.tick()
        await clock.untilWaiting()
        XCTAssertEqual(sends, 1)
        scheduler.setMainWorkActive(true)
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(sends, 1, "Presence never overlaps main enrollment/delivery/relay work")
        scheduler.setMainWorkActive(false)
        scheduler.beginCallback(); scheduler.beginCallback()
        clock.tick(); await clock.untilWaiting()
        scheduler.endCallback()
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(sends, 1, "Nested mounted/service reports retain exclusion until all finish")
        scheduler.endCallback()
        clock.tick(); await clock.untilWaiting()
        XCTAssertEqual(sends, 2, "Foreground presence resumes after the existing operation drains")
        scheduler.stop()
        clock.tick()
        await Task.yield()
        XCTAssertEqual(sends, 2, "Background/reset stop prevents further requests")
    }
    @MainActor func testNativePresenceUserActionCancelsAndDrainsLateReplyBeforeContinuing() async {
        let clock = EnrollmentPresenceClock()
        let response = EnrollmentGuardTaskGate()
        let started = expectation(description: "presence transport started")
        let continued = expectation(description: "user work admitted after drain")
        let scheduler = NativeEnrollmentPresenceScheduler(wait: { try await clock.wait() })
        var accepted = 0
        scheduler.start {
            started.fulfill()
            await response.wait() // Deliberately models a transport that finishes after cancellation.
            try Task.checkCancellation()
            accepted += 1
        }
        defer { scheduler.stop(); clock.cancel(); Task { await response.release() } }
        await clock.untilWaiting(); clock.tick()
        await fulfillment(of: [started], timeout: 2)
        scheduler.setMainWorkActive(true)
        var userWorkStarted = false
        let action = Task { @MainActor in
            await scheduler.drain()
            userWorkStarted = true; continued.fulfill()
        }
        await Task.yield()
        XCTAssertFalse(userWorkStarted, "Cancellation must drain before another status clears the owner observation")
        await response.release()
        await fulfillment(of: [continued], timeout: 2)
        await action.value
        XCTAssertEqual(accepted, 0, "The cancelled reply cannot accept or revive a replaced/background context")
        XCTAssertTrue(userWorkStarted, "Presence never occupies the visible user-action busy slot")
        scheduler.stop()
    }

    @MainActor func testDisconnectWaitsForNestedMountedAndServiceCallbacksToDrain() async {
        let scheduler = NativeEnrollmentPresenceScheduler()
        scheduler.beginCallback(); scheduler.beginCallback()
        let started = expectation(description: "disconnect reached callback drain")
        var admitted = false
        let disconnect = Task { @MainActor in
            started.fulfill()
            await scheduler.drainCallbacks()
            admitted = true
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(admitted, "Credential retirement cannot overlap an existing mounted or service request")
        scheduler.endCallback()
        await Task.yield()
        XCTAssertFalse(admitted, "Nested callback ownership remains until both requests finish")
        scheduler.stop() // Foreground cancellation cannot erase an in-flight callback owner.
        XCTAssertFalse(admitted)
        scheduler.endCallback()
        await disconnect.value
        XCTAssertTrue(admitted)
        await scheduler.drainCallbacks() // An already drained owner is immediately reusable.
    }
    @MainActor func testSavedConnectionRetryNeedsNoHumanSessionAndFailedDisconnectPreservesOriginal() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Saved display", profile: "ipad",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 768, height: 1024))
        try journal.saveOriginal(intent); try journal.markRecordedInstallation(intent)
        let saved = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
        let controller = NativeEnrollmentSceneController(intentJournal: journal)
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let bootstrap = DeviceManagementBootstrap()
        XCTAssertNil(lifecycle.coordinator?.humanIdentity)
        // The device-only retry has no lifecycle/token argument. Before native
        // owner readiness it waits, preserving every original identifier.
        controller.retryCloudConnection(bootstrap: bootstrap)
        XCTAssertEqual(controller.cloudConnectionIdentity, intent.enrollmentID)
        XCTAssertTrue(controller.hasRecordedCloudInstallation)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.enrollmentDiagnostic)
        XCTAssertNil(controller.explicitConnectionOperationID)
        // No original native capability was admitted in this fixture. Log out
        // must fail before revocation/retirement, never imitate sign-out success.
        await controller.disconnectCloudDevice(lifecycle: lifecycle)
        XCTAssertFalse(controller.disconnectInProgress)
        XCTAssertNotNil(controller.disconnectMessage)
        XCTAssertFalse(controller.isCloudLoggedOut)
        XCTAssertTrue(controller.hasRecordedCloudInstallation)
        XCTAssertEqual(controller.cloudConnectionIdentity, intent.enrollmentID)
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("xyz.screenpunk.native-managed").path))
        controller.didEnterBackground()
        controller.retryCloudConnection(bootstrap: bootstrap)
        XCTAssertTrue(controller.hasRecordedCloudInstallation)
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), saved)
        XCTAssertNil(lifecycle.coordinator?.humanIdentity)
    }

#if targetEnvironment(simulator)
    @MainActor func testReceivedDetachedLocalColdRestoreAndForegroundActuallyMountWithoutAnotherInstall() async throws {
        let fixtureCleanup = SceneLANFixtureCleanup()
        addTeardownBlock { await fixtureCleanup.run() }
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        fixtureCleanup.add { deviceTLS.close() }
        let controllerTLS = try makeSceneLANTLSIdentity(role: .controller)
        fixtureCleanup.add { controllerTLS.close() }
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        fixtureCleanup.add { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let revoke = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await revoke.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation(), namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let initialListener = SceneLANListenerProbe()
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty }, hostFactory: { context in
            let host = try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("detached-real-lan-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
            host.server?.managementBoundary = { initialListener.observe($0) }
            return host
        })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let scene = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap) { _, _ in throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let grants = SceneLANOwnedGrantObserver(directory: journal.directory)
        fixtureCleanup.add { await scene.drainRetiredWorkForTesting(); grants.close() }
        let requests = fixture.http.requestCount
        let startupFailure = await scene.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNil(startupFailure)
        let host = try XCTUnwrap(scene.commonHost)
        guard case .localReady(let admitted) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(admitted === host)
        let expected = try await exerciseAuthenticatedSceneLANInstall(host: host, unified: detached, commonRoot: candidate.commonRoot,
            controllerIdentity: controllerTLS.identity, deviceIdentity: deviceTLS.identity, grants: grants,
            expectRetainedCloud: false, verifyStaticProjection: false, initialListener: initialListener)
        XCTAssertNil(try detached.mountedAssociation(), "Received-only inventory must not be mistaken for a real mounted frame")
        let currentURL = candidate.commonRoot.appendingPathComponent("mixed-current.json")
        let receivedBytes = try Data(contentsOf: currentURL)
        let saved = try detached.detachedAssociation().metadata
        scene.didEnterBackground()
        XCTAssertNil(scene.content); XCTAssertNil(scene.commonHost)

        // A fresh owner and ordinary Scene discover the exact durable roots. No old
        // inventory/context is injected, and no LAN write is made after this point.
        let coldAuthority = DeviceManagementAuthority(journal: AuthorityJournal(),
            credentials: .init(backend: AuthorityBackend(), random: { Data() }), reset: NativeColdDetachedResetEvidence(),
            managedNamespace: try .fixture(existingPhysicalAnchor: fixture.parent.appendingPathComponent("Application Support")),
            supportAnchorSetup: try .fixture(existingPhysicalParent: fixture.parent),
            commandIntents: .init(root: fixture.parent.appendingPathComponent("command-intents")), concurrentControlQualified: true)
        var coldAdmissions = 0
        let coldBootstrap = DeviceManagementBootstrap(preparationFactory: {
            .init(authority: coldAuthority, constructLifecycle: {
                XCTFail("Completed detached restore cannot fall through to legacy admission")
                throw NativeRecoveryFixtureFailure.unexpectedEffect
            })
        }, retained: { XCTFail("No legacy fallback"); return .empty }, hostFactory: { context in
            try context.validate()
            try context.withAuthority {
                XCTAssertNil(try context.qualifiedCloudInstallationIDUnderAuthority())
                try context.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: saved.commonRootID,
                    installationID: saved.retiredInstallationID)
            }
            coldAdmissions += 1
            return try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("cold-real-lan-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        let coldAdmission = NativeSessionAdmissionProbe()
        let coldPresentation = EnrollmentGuardTaskGate()
        var coldPreparing = false
        let coldScene = NativeEnrollmentSceneController(testColdDetachedJournal: journal,
            resourceCheckpoint: { try coldAdmission.checkpoint() }, presentationCheckpoint: { stage in
                if case .preparing = stage { coldPreparing = true; await coldPresentation.wait() }
            })
        coldAdmission.arm()
        fixtureCleanup.add {
            coldAdmission.release()
            await coldPresentation.release()
            await coldScene.drainRetiredWorkForTesting()
        }
        var testPhase = "coldSetup"
        defer { print("Received cold scene diagnostic phase=\(testPhase) mounted=\(coldScene.candidateMounted) frames=\(coldScene.presentationFrames.count) work=\(coldScene.hasActiveEnrollmentWork)") }
        XCTAssertTrue(coldScene.requiresDeviceOwnedStartup); XCTAssertTrue(coldScene.isCloudLoggedOut)
        XCTAssertNil(coldScene.content); XCTAssertTrue(coldScene.presentationFrames.isEmpty)
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene)
        // Standalone UIKit hosting defaults to background. Model the verified
        // active UIWindowScene, then drive real Root lifecycle transitions below.
        let phaseDriver = SceneLANPhaseDriver(phase: .active)
        var observedPhase: ScenePhase?
        let hosting = UIHostingController(rootView: SceneLANLifecycleFixture(driver: phaseDriver, content:
            SceneLANPhaseObserver(content:
                CloudSceneRoot(cloud: CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()),
                    bootstrap: coldBootstrap, enrollment: coldScene), observe: { observedPhase = $0 })))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        fixtureCleanup.add {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        // Root.onAppear/readiness follows the same recorded-startup entry path as
        // a normal fresh process. Success requires the actual WK didFinish callback.
        testPhase = "heldColdValidator"
        try await waitForProductionSequence { coldAdmission.entered }
        XCTAssertEqual(coldAdmission.firstThreadAfterArmWasMain, false)
        func assertOnlySavedRestoreProgress() async throws {
            _ = try await waitForLocalStartupElement("Starting local connection", in: hosting.view)
            let began = ProcessInfo.processInfo.systemUptime
            for _ in 0..<8 {
                hosting.view.layoutIfNeeded()
                var visited: Set<ObjectIdentifier> = []
                let elements = localStartupAccessibilityElements(hosting.view, visited: &visited)
                XCTAssertTrue(elements.contains { $0.accessibilityLabel?.contains("Starting local connection") == true })
                XCTAssertFalse(elements.contains { $0.accessibilityTraits.contains(.button) &&
                    ["Local", "Cloud", "Your screens", "Settings"].contains($0.accessibilityLabel ?? "") },
                    "Saved Local restore cannot route through fresh Welcome or the temporary legacy Connected landing")
                await Task.yield()
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5, "UI turns and actual layout must remain responsive while cold qualification is held")
        }
        try await assertOnlySavedRestoreProgress()
        XCTAssertEqual(coldAdmissions, 0); XCTAssertNil(coldScene.content)
        coldAdmission.release()
        testPhase = "heldAdmittedPresentation"
        try await waitForProductionSequence { coldPreparing }
        guard case .localReady = coldBootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertNil(coldScene.content)
        try await assertOnlySavedRestoreProgress()
        testPhase = "firstColdMount"
        await coldPresentation.release()
        do {
            try await waitForProductionSequence {
                hosting.view.layoutIfNeeded()
                return coldScene.candidateMounted && coldScene.content?.generationID == expected.operationID
                    && coldScene.content?.entryID == expected.entryID && !sceneLANWebViews(in: hosting.view).isEmpty
            }
        } catch {
            let phase: String
            switch observedPhase {
            case .active?: phase = "active"
            case .inactive?: phase = "inactive"
            case .background?: phase = "background"
            case nil: phase = "unobserved"
            @unknown default: phase = "unknown"
            }
            let startup: String
            switch coldBootstrap.state {
            case .checking: startup = "checking"
            case .resetting: startup = "resetting"
            case .cloudReady: startup = "cloudReady"
            case .localReady: startup = "localReady"
            case .blocked: startup = "blocked"
            }
            let stage = coldBootstrap.startupDiagnostic?.stage.rawValue ?? "none"
            let exact = coldScene.content?.generationID == expected.operationID && coldScene.content?.entryID == expected.entryID
            let lifetime = coldScene.presentationLifetime.map { !$0.isRetired } ?? false
            print("Detached cold diagnostic phase=\(phase) bootstrap=\(startup) stage=\(stage) ready=\(coldBootstrap.readyToValidateRecordedDetachedRestore) authorityMatch=\(coldBootstrap.currentAuthority === coldAuthority) admissions=\(coldAdmissions) work=\(coldScene.hasActiveEnrollmentWork) contentExact=\(exact) frames=\(coldScene.presentationFrames.count) lifetime=\(lifetime) webViews=\(sceneLANWebViews(in: hosting.view).count) mounted=\(coldScene.candidateMounted)")
            throw error
        }
        XCTAssertEqual(coldAdmissions, 1)
        let coldContent = try XCTUnwrap(coldScene.content), coldLifetime = try XCTUnwrap(coldScene.presentationLifetime)
        let frame = try XCTUnwrap(coldScene.presentationFrames.first { $0.candidate })
        XCTAssertTrue(frame.content === coldContent); XCTAssertTrue(frame.lifetime === coldLifetime)
        XCTAssertTrue(frame.runtime?.content === coldContent); XCTAssertFalse(coldLifetime.isRetired)
        XCTAssertEqual(coldContent.revision, expected.revision)
        let web = try XCTUnwrap(sceneLANWebViews(in: hosting.view).first)
        let body = try await web.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(body?.contains("Authenticated Scene LAN legacy Screen") == true)
        func assertOriginalMountedJournal() throws {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                candidate.commonRoot.appendingPathComponent("mixed-mounted.json"))) as? [String: Any])
            XCTAssertEqual(UUID(uuidString: try XCTUnwrap(object["generationID"] as? String)), expected.operationID)
            XCTAssertEqual(UUID(uuidString: try XCTUnwrap(object["entryID"] as? String)), expected.entryID)
            XCTAssertEqual(try Data(contentsOf: currentURL), receivedBytes, "Restore/mount cannot perform a new selection CAS")
            XCTAssertEqual(fixture.http.requestCount, requests, "Detached cold/resume cannot perform Cloud OAuth or delivery")
            XCTAssertNil(try journal.load())
        }
        try assertOriginalMountedJournal()

        // Explicit hard retirement remains the cold-remount control. Ordinary
        // mounted suspension continuity is qualified by its separate Root test.
        coldScene.didEnterBackground()
        phaseDriver.phase = .background
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return observedPhase == .background && coldLifetime.isRetired && coldScene.content == nil
                && coldScene.commonHost == nil && sceneLANWebViews(in: hosting.view).isEmpty
        }
        XCTAssertTrue(coldLifetime.isRetired); XCTAssertNil(coldScene.content); XCTAssertNil(coldScene.commonHost)
        // Root.onChange drives foreground restore in the same visible root;
        // the test never invokes the Scene startup or mounted callback here.
        testPhase = "cancelledColdRestore"
        coldAdmission.arm()
        phaseDriver.phase = .active
        try await waitForProductionSequence { coldAdmission.entered }
        try await assertOnlySavedRestoreProgress()
        phaseDriver.phase = .background
        try await waitForProductionSequence { observedPhase == .background }
        coldAdmission.release()
        try await waitForProductionSequence { !coldScene.hasActiveEnrollmentWork }
        XCTAssertNil(coldScene.content); XCTAssertNil(coldScene.commonHost)
        XCTAssertNil(coldScene.displayScreenInventory); XCTAssertTrue(coldScene.displayInstalledManifests.isEmpty)
        XCTAssertEqual(coldAdmissions, 1, "A cancelled fresh-owner result cannot publish or admit a host after background")
        XCTAssertEqual(try Data(contentsOf: currentURL), receivedBytes)
        testPhase = "freshRetryMount"
        phaseDriver.phase = .active
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return coldScene.candidateMounted && coldScene.content?.generationID == expected.operationID
                && coldScene.content?.entryID == expected.entryID && !sceneLANWebViews(in: hosting.view).isEmpty
        }
        XCTAssertEqual(coldAdmissions, 2)
        let resumedContent = try XCTUnwrap(coldScene.content), resumedLifetime = try XCTUnwrap(coldScene.presentationLifetime)
        XCTAssertFalse(resumedContent === coldContent); XCTAssertFalse(resumedLifetime === coldLifetime)
        XCTAssertFalse(resumedLifetime.isRetired)
        try assertOriginalMountedJournal()
        let localFailure = await coldScene.requestLocalConnection(bootstrap: coldBootstrap)
        XCTAssertNil(localFailure)
        let repeatedLocalFailure = await coldScene.requestLocalConnection(bootstrap: coldBootstrap)
        XCTAssertNil(repeatedLocalFailure)
        try await waitForProductionSequence { !coldScene.hasActiveEnrollmentWork }
        XCTAssertTrue(coldScene.content === resumedContent); XCTAssertTrue(coldScene.presentationLifetime === resumedLifetime)
        XCTAssertEqual(coldAdmissions, 2, "Repeated explicit Local reuses the foreground-restored admitted host/frame")
        try assertOriginalMountedJournal()
        testPhase = "completed"
    }

    @MainActor func testForegroundRequestSurvivesBothCancelledDetachedTasksAndBackgroundDoesNotRestart() async throws {
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        defer { deviceTLS.close() }
        let controllerTLS = try makeSceneLANTLSIdentity(role: .controller)
        defer { controllerTLS.close() }
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let revoke = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await revoke.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation(), namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var admissions = 0
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty }, hostFactory: { context in
            admissions += 1
            return try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("detached-real-lan-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let admittedGate = EnrollmentGuardTaskGate(), restoredGate = EnrollmentGuardTaskGate(), backgroundGate = EnrollmentGuardTaskGate()
        defer { Task { await admittedGate.release(); await restoredGate.release(); await backgroundGate.release() } }
        var nextGate: EnrollmentGuardTaskGate? = admittedGate
        var preparing = 0, joining = 0, foregroundEntries = 0
        let scene = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap, presentationCheckpoint: { stage in
                switch stage {
                case .preparing:
                    preparing += 1
                    let held = nextGate; nextGate = nil
                    if let held { await held.wait() }
                case .joining: joining += 1
                }
            }, foregroundReconnectObserver: { foregroundEntries += 1 }) { _, _ in throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let grants = SceneLANOwnedGrantObserver(directory: journal.directory)
        defer { scene.commonHost?.retireForReset(); grants.close() }
        let requests = fixture.http.requestCount
        let startupFailure = await scene.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNil(startupFailure)
        let host = try XCTUnwrap(scene.commonHost)
        guard case .localReady(let admitted) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(admitted === host)
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene)
        let phaseDriver = SceneLANPhaseDriver(phase: .active)
        var observedPhase: ScenePhase?
        let hosting = UIHostingController(rootView: SceneLANLifecycleFixture(driver: phaseDriver, content:
            SceneLANPhaseObserver(content:
                CloudSceneRoot(cloud: CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()),
                    bootstrap: bootstrap, enrollment: scene), observe: { observedPhase = $0 })))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            scene.didEnterBackground()
        }
        _ = try await waitForLocalStartupElement("Local Screenpunk", in: hosting.view, button: true)
        try await waitForProductionSequence { observedPhase == .active && !scene.hasActiveEnrollmentWork }
        let expected = try await exerciseAuthenticatedSceneLANInstall(host: host, unified: detached, commonRoot: candidate.commonRoot,
            controllerIdentity: controllerTLS.identity, deviceIdentity: deviceTLS.identity, grants: grants,
            expectRetainedCloud: false, verifyStaticProjection: false)
        let before = try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json"))
        try await waitForProductionSequence { preparing == 1 }
        XCTAssertNil(scene.content); XCTAssertNil(try detached.mountedAssociation())

        // A: the actual Root's active event joins the installed handler's held
        // preparation through the admitted-session reconnect task (first defer).
        phaseDriver.phase = .inactive
        try await waitForProductionSequence { observedPhase == .inactive }
        phaseDriver.phase = .active
        try await waitForProductionSequence { joining >= 1 && scene.hasActiveEnrollmentWork }
        phaseDriver.phase = .background
        try await waitForProductionSequence { observedPhase == .background && scene.commonHost == nil }
        XCTAssertTrue(scene.hasActiveEnrollmentWork, "Cancelled old work is still held, not already drained")
        phaseDriver.phase = .active
        try await waitForProductionSequence { observedPhase == .active && foregroundEntries == 1 }
        XCTAssertEqual(preparing, 1); XCTAssertEqual(admissions, 1)
        await admittedGate.release()
        func waitForActualOriginalMount() async throws {
            try await waitForProductionSequence {
                hosting.view.layoutIfNeeded()
                return observedPhase == .active && !scene.hasActiveEnrollmentWork && scene.candidateMounted
                    && scene.content?.generationID == expected.operationID && scene.content?.entryID == expected.entryID
                    && !sceneLANWebViews(in: hosting.view).isEmpty
            }
            let content = try XCTUnwrap(scene.content), lifetime = try XCTUnwrap(scene.presentationLifetime)
            let frame = try XCTUnwrap(scene.presentationFrames.first { $0.candidate })
            XCTAssertEqual(scene.presentationFrames.count, 1)
            XCTAssertTrue(frame.content === content); XCTAssertTrue(frame.lifetime === lifetime)
            XCTAssertTrue(frame.runtime?.content === content); XCTAssertFalse(lifetime.isRetired)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                candidate.commonRoot.appendingPathComponent("mixed-mounted.json"))) as? [String: Any])
            XCTAssertEqual(UUID(uuidString: try XCTUnwrap(object["generationID"] as? String)), expected.operationID)
            XCTAssertEqual(UUID(uuidString: try XCTUnwrap(object["entryID"] as? String)), expected.entryID)
            let body = try await XCTUnwrap(sceneLANWebViews(in: hosting.view).first).evaluateJavaScript("document.body.textContent") as? String
            XCTAssertTrue(body?.contains("Authenticated Scene LAN legacy Screen") == true)
            XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before)
            XCTAssertEqual(fixture.http.requestCount, requests, "A foreground replay cannot reactivate or deploy")
            XCTAssertNil(try journal.load())
        }
        try await waitForActualOriginalMount()
        XCTAssertEqual(admissions, 2); XCTAssertEqual(preparing, 2)

        // B: a real journal restore is now the held outer task (second defer).
        nextGate = restoredGate
        // This branch explicitly qualifies cold retirement/restoration; ordinary
        // mounted suspension is covered by the separate continuity Root case.
        scene.didEnterBackground()
        phaseDriver.phase = .background
        try await waitForProductionSequence { observedPhase == .background && scene.commonHost == nil && scene.content == nil }
        phaseDriver.phase = .active
        try await waitForProductionSequence { preparing == 3 && scene.hasActiveEnrollmentWork }
        XCTAssertEqual(admissions, 3)
        phaseDriver.phase = .background
        try await waitForProductionSequence { observedPhase == .background && scene.commonHost == nil }
        phaseDriver.phase = .active
        try await waitForProductionSequence { observedPhase == .active && foregroundEntries == 2 }
        XCTAssertEqual(preparing, 3); XCTAssertEqual(admissions, 3)
        await restoredGate.release()
        try await waitForActualOriginalMount()
        XCTAssertEqual(admissions, 4); XCTAssertEqual(preparing, 4)

        // C: draining cancelled work while staying background must NOT replay.
        nextGate = backgroundGate
        // This branch explicitly qualifies cold retirement/restoration; ordinary
        // mounted suspension is covered by the separate continuity Root case.
        scene.didEnterBackground()
        phaseDriver.phase = .background
        try await waitForProductionSequence { observedPhase == .background && scene.commonHost == nil && scene.content == nil }
        phaseDriver.phase = .active
        try await waitForProductionSequence { preparing == 5 && scene.hasActiveEnrollmentWork }
        phaseDriver.phase = .background
        try await waitForProductionSequence { observedPhase == .background && scene.commonHost == nil }
        await backgroundGate.release()
        try await waitForProductionSequence { !scene.hasActiveEnrollmentWork }
        XCTAssertEqual(foregroundEntries, 2); XCTAssertEqual(admissions, 5); XCTAssertEqual(preparing, 5)
        XCTAssertNil(scene.commonHost); XCTAssertNil(scene.content); XCTAssertFalse(scene.candidateMounted)
        XCTAssertTrue(scene.presentationFrames.isEmpty)
        XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before)
        phaseDriver.phase = .active
        try await waitForActualOriginalMount()
        XCTAssertEqual(admissions, 6); XCTAssertEqual(preparing, 6)
        XCTAssertNil(scene.deliveryMessage); XCTAssertNil(scene.disconnectMessage)
    }

    @MainActor func testDetachedStartupAndInstalledCallbackCoalesceBeforeRealRuntimeAndWKMount() async throws {
        let fixtureCleanup = SceneLANFixtureCleanup()
        addTeardownBlock { await fixtureCleanup.run() }
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        fixtureCleanup.add { deviceTLS.close() }
        let controllerTLS = try makeSceneLANTLSIdentity(role: .controller)
        fixtureCleanup.add { controllerTLS.close() }
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        fixtureCleanup.add { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let revoke = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await revoke.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation(), namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let initialListener = SceneLANListenerProbe()
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty }, hostFactory: { context in
            let host = try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("detached-real-lan-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
            host.server?.managementBoundary = { initialListener.observe($0) }
            return host
        })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let gate = EnrollmentGuardTaskGate()
        var preparing = 0, joining = 0
        let scene = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap, presentationCheckpoint: { stage in
                switch stage {
                case .preparing:
                    preparing += 1
                    await gate.wait()
                case .joining: joining += 1
                }
            }) { _, _ in throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let grants = SceneLANOwnedGrantObserver(directory: journal.directory)
        var ownedLocalStartup: Task<String?, Never>?
        fixtureCleanup.add {
            await gate.release()
            ownedLocalStartup?.cancel()
            await scene.drainRetiredWorkForTesting()
            if let ownedLocalStartup { _ = await ownedLocalStartup.value }
            grants.close()
        }
        var testPhase = "localStartup"
        defer { print("Coalesced scene diagnostic phase=\(testPhase) mounted=\(scene.candidateMounted) frames=\(scene.presentationFrames.count) work=\(scene.hasActiveEnrollmentWork)") }
        let requests = fixture.http.requestCount
        let startupFailure = await scene.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNil(startupFailure)
        let host = try XCTUnwrap(scene.commonHost)
        guard case .localReady(let admitted) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(admitted === host)
        testPhase = "authenticatedInstall"
        let expected = try await exerciseAuthenticatedSceneLANInstall(host: host, unified: detached, commonRoot: candidate.commonRoot,
            controllerIdentity: controllerTLS.identity, deviceIdentity: deviceTLS.identity, grants: grants,
            expectRetainedCloud: false, verifyStaticProjection: false, initialListener: initialListener)
        testPhase = "heldPresentation"
        try await waitForProductionSequence { preparing == 1 }
        let before = try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json"))
        XCTAssertNil(scene.content); XCTAssertFalse(scene.candidateMounted)
        // This is the actual installed handler, used only to request competing
        // presentation work. It never bypasses preparation or reports a mount.
        let installedPresentationRequest = try XCTUnwrap(host.server?.onCommonContentChanged)
        installedPresentationRequest()
        try await waitForProductionSequence { joining >= 1 }
        let explicitLocal = Task { @MainActor in await scene.requestLocalConnection(bootstrap: bootstrap) }
        ownedLocalStartup = explicitLocal
        try await waitForProductionSequence { joining >= 2 }
        scene.reconnectInstallation(bootstrap: bootstrap)
        try await waitForProductionSequence { joining >= 3 }
        XCTAssertEqual(preparing, 1, "All competitors entered while the sole real preparation was held")
        XCTAssertNil(scene.content); XCTAssertNil(try detached.mountedAssociation())
        testPhase = "hostingRoot"
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene)
        let hosting = UIHostingController(rootView: CloudSceneRoot(cloud: CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()),
            bootstrap: bootstrap, enrollment: scene))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        fixtureCleanup.add {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        XCTAssertTrue(sceneLANWebViews(in: hosting.view).isEmpty)
        testPhase = "mount"
        await gate.release()
        let localFailure = await explicitLocal.value
        XCTAssertNil(localFailure)
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return scene.candidateMounted && !sceneLANWebViews(in: hosting.view).isEmpty && !scene.hasActiveEnrollmentWork
        }
        XCTAssertEqual(preparing, 1, "Joining callbacks cannot issue a second Core presentation identity")
        let content = try XCTUnwrap(scene.content), lifetime = try XCTUnwrap(scene.presentationLifetime)
        let frame = try XCTUnwrap(scene.presentationFrames.first { $0.candidate })
        XCTAssertTrue(frame.content === content); XCTAssertTrue(frame.lifetime === lifetime)
        XCTAssertTrue(frame.runtime?.content === content); XCTAssertFalse(lifetime.isRetired)
        XCTAssertEqual(content.generationID, expected.operationID); XCTAssertEqual(content.entryID, expected.entryID)
        let mounted = try XCTUnwrap(detached.mountedAssociation())
        XCTAssertEqual(mounted.generationID, expected.operationID); XCTAssertEqual(mounted.entryID, expected.entryID)
        let body = try await XCTUnwrap(sceneLANWebViews(in: hosting.view).first).evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(body?.contains("Authenticated Scene LAN legacy Screen") == true)
        XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before)
        XCTAssertEqual(fixture.http.requestCount, requests)
        testPhase = "idempotentCallback"
        installedPresentationRequest()
        scene.reconnectInstallation(bootstrap: bootstrap)
        try await waitForProductionSequence { !scene.hasActiveEnrollmentWork }
        XCTAssertEqual(preparing, 1)
        XCTAssertTrue(scene.content === content); XCTAssertTrue(scene.presentationLifetime === lifetime)
        scene.didEnterBackground()
        installedPresentationRequest()
        await Task.yield()
        XCTAssertNil(scene.content); XCTAssertTrue(lifetime.isRetired)
        XCTAssertNil(scene.deliveryMessage, "A stale retired callback cannot publish a presentation failure")
        testPhase = "completed"
    }

    @MainActor func testDetachedLANInstallPublishesCurrentManagedFrameAndActuallyMountsInCloudSceneRoot() async throws {
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        defer { deviceTLS.close() }
        let controllerTLS = try makeSceneLANTLSIdentity(role: .controller)
        defer { controllerTLS.close() }
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let revoke = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await revoke.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation(), namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty }, hostFactory: { context in
            try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("detached-real-lan-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let scene = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap) { _, _ in throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let grants = SceneLANOwnedGrantObserver(directory: journal.directory)
        defer { scene.commonHost?.retireForReset(); grants.close() }
        let requests = fixture.http.requestCount
        let startupFailure = await scene.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNil(startupFailure)
        let host = try XCTUnwrap(scene.commonHost)
        guard case .localReady(let admitted) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(admitted === host)
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = uiScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: uiScene)
        let hosting = UIHostingController(rootView: CloudSceneRoot(cloud: CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()),
            bootstrap: bootstrap, enrollment: scene))
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            scene.didEnterBackground()
        }
        _ = try await waitForLocalStartupElement("Local Screenpunk", in: hosting.view, button: true)
        XCTAssertNil(scene.content); XCTAssertNil(scene.presentationLifetime)
        XCTAssertTrue(scene.presentationFrames.isEmpty); XCTAssertFalse(scene.candidateMounted)
        XCTAssertTrue(sceneLANWebViews(in: hosting.view).isEmpty,
            "The same visible root starts on the empty Local/Welcome route before the LAN callback")
        let expected = try await exerciseAuthenticatedSceneLANInstall(host: host, unified: detached, commonRoot: candidate.commonRoot,
            controllerIdentity: controllerTLS.identity, deviceIdentity: deviceTLS.identity, grants: grants,
            expectRetainedCloud: false, verifyStaticProjection: false)
        try await waitForProductionSequence {
            scene.content?.generationID == expected.operationID && scene.content?.entryID == expected.entryID
        }
        let content = try XCTUnwrap(scene.content), lifetime = try XCTUnwrap(scene.presentationLifetime)
        let frame = try XCTUnwrap(scene.presentationFrames.first { $0.candidate })
        let runtime = try XCTUnwrap(frame.runtime)
        XCTAssertTrue(scene.isCloudLoggedOut)
        XCTAssertTrue(frame.content === content); XCTAssertTrue(frame.lifetime === lifetime)
        XCTAssertTrue(runtime.content === content); XCTAssertFalse(lifetime.isRetired)
        XCTAssertEqual(content.generationID, expected.operationID); XCTAssertEqual(content.entryID, expected.entryID)
        XCTAssertEqual(content.revision, expected.revision)
        try runtime.verifyResources()
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return scene.candidateMounted && !sceneLANWebViews(in: hosting.view).isEmpty
        }
        let webView = try XCTUnwrap(sceneLANWebViews(in: hosting.view).first)
        XCTAssertFalse(webView.isLoading)
        let body = try await webView.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(body?.contains("Authenticated Scene LAN legacy Screen") == true,
            "The actual WKWebView loaded the synthetic package; no delegate or mounted callback is invoked by the test")
        let mounted = try XCTUnwrap(detached.mountedAssociation())
        XCTAssertEqual(mounted.generationID, expected.operationID); XCTAssertEqual(mounted.entryID, expected.entryID)
        let mountedBytes = try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-mounted.json"))
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: mountedBytes) as? [String: Any])
        XCTAssertEqual(UUID(uuidString: try XCTUnwrap(persisted["generationID"] as? String)), expected.operationID)
        XCTAssertEqual(UUID(uuidString: try XCTUnwrap(persisted["entryID"] as? String)), expected.entryID)
        XCTAssertEqual(persisted["manifestDigest"] as? String, mounted.manifestDigest)
        XCTAssertTrue(scene.content === content); XCTAssertTrue(scene.presentationLifetime === lifetime)
        XCTAssertEqual(fixture.http.requestCount, requests, "Detached rendering cannot reactivate Cloud")
        XCTAssertTrue(try detached.detachedAssociation().metadata.cleanupCompleted)
        scene.didEnterBackground()
        XCTAssertTrue(lifetime.isRetired)
        XCTAssertNil(scene.content)
        try await waitForProductionSequence {
            hosting.view.layoutIfNeeded()
            return sceneLANWebViews(in: hosting.view).isEmpty
        }
        XCTAssertThrowsError(try runtime.verifyResources(), "The retired detached authority cannot qualify the old frame")
    }

    @MainActor func testAuthenticatedTLSLegacyScreenInstallThroughDetachedSceneHandlerAndReplay() async throws {
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        defer { deviceTLS.close() }
        let controllerTLS = try makeSceneLANTLSIdentity(role: .controller)
        defer { controllerTLS.close() }
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let revoke = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await revoke.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation(), namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty }, hostFactory: { context in
            try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("detached-real-lan-state")),
                identityProvider: { deviceTLS.identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let scene = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap) { _, _ in throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let grants = SceneLANOwnedGrantObserver(directory: journal.directory)
        defer { scene.commonHost?.retireForReset(); grants.close() }
        let requests = fixture.http.requestCount
        let startupFailure = await scene.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNil(startupFailure)
        let host = try XCTUnwrap(scene.commonHost)
        guard case .localReady(let admitted) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(admitted === host)
        try await exerciseAuthenticatedSceneLANInstall(host: host, unified: detached, commonRoot: candidate.commonRoot,
            controllerIdentity: controllerTLS.identity, deviceIdentity: deviceTLS.identity, grants: grants,
            expectRetainedCloud: false)
        XCTAssertEqual(fixture.http.requestCount, requests, "Detached LAN install cannot reactivate Cloud")
        XCTAssertTrue(try detached.detachedAssociation().metadata.cleanupCompleted)
    }

    @MainActor func testAuthenticatedTLSLegacyScreenInstallThroughCloudSceneHandlerPreservesCloudAndReplay() async throws {
        let deviceTLS = try makeSceneLANTLSIdentity(role: .device)
        defer { deviceTLS.close() }
        let controllerTLS = try makeSceneLANTLSIdentity(role: .controller)
        defer { controllerTLS.close() }
        let stateRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("scene-cloud-lan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let fixture = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true, hostFactory: { context in
            try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: stateRoot.appendingPathComponent("state")), identityProvider: { deviceTLS.identity },
                homeAssistantVault: .init(store: MemoryCredentialStore()), genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        let journal = NativeEnrollmentIntentJournal(directory: fixture.parent.appendingPathComponent("Application Support/xyz.screenpunk.enrollment-intent"))
        let grants = SceneLANOwnedGrantObserver(directory: journal.directory)
        defer { fixture.controller.commonHost?.retireForReset(); grants.close(); fixture.close() }
        fixture.http.productionSequenceEnabled = true
        // This prepared fixture already owns the genuine empty common inventory.
        // Traverse normal empty-connection host admission before offering its Cloud update.
        let genesis = try fixture.unified.validatedAssociation()
        XCTAssertTrue(genesis.entries.isEmpty); XCTAssertNil(genesis.configuredEntryID)
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        let admittedHost = try XCTUnwrap(fixture.controller.commonHost)
        XCTAssertNotNil(admittedHost.server); XCTAssertFalse(admittedHost.lifetime.isRetired)
        let admittedRootGeneration = fixture.bootstrap.rootGeneration
        let admittedDeviceID = admittedHost.runtime.profile.deviceId
        let empty = try fixture.unified.validatedAssociation()
        XCTAssertEqual(empty.generationID, genesis.generationID)
        XCTAssertTrue(empty.entries.isEmpty); XCTAssertNil(empty.configuredEntryID)
        try fixture.offerCloudCommand()
        try await fixture.controller.runPreparedDeviceOnlyConnectionForTesting()
        XCTAssertTrue(fixture.controller.commonHost === admittedHost)
        XCTAssertFalse(admittedHost.lifetime.isRetired)
        XCTAssertEqual(fixture.bootstrap.rootGeneration, admittedRootGeneration)
        XCTAssertEqual(admittedHost.runtime.profile.deviceId, admittedDeviceID)
        let before = try fixture.unified.validatedAssociation()
        XCTAssertEqual(before.entries.count, 1); XCTAssertEqual(before.entries.first?.provenance, "cloud")
        XCTAssertEqual(fixture.http.sequenceRequests.filter { $0.path.hasSuffix("/delivery/activation") }.count, 1,
            "Setup must activate the genuine offered Cloud command before the LAN installation")
        let cloudContent = try XCTUnwrap(fixture.controller.content, fixture.controller.deliveryMessage ?? "No Cloud presentation")
        XCTAssertEqual(cloudContent.entryID, before.configuredEntryID)
        XCTAssertEqual(cloudContent.generationID, before.generationID)
        let host = try XCTUnwrap(fixture.controller.commonHost)
        try await exerciseAuthenticatedSceneLANInstall(host: host, unified: fixture.unified,
            commonRoot: fixture.parent.appendingPathComponent("Application Support/xyz.screenpunk.unified-inventory"),
            controllerIdentity: controllerTLS.identity, deviceIdentity: deviceTLS.identity, grants: grants,
            expectRetainedCloud: true)
        let after = try fixture.unified.validatedAssociation() // Revalidates all retained Cloud package/resource proofs.
        let cloud = try XCTUnwrap(after.entries.first { $0.entryID == before.entries.first?.entryID })
        XCTAssertEqual(cloud.provenance, "cloud"); XCTAssertEqual(cloud.dashboardID, before.entries.first?.dashboardID)
        XCTAssertEqual(cloud.revision, before.entries.first?.revision); XCTAssertEqual(cloud.manifestDigest, before.entries.first?.manifestDigest)
        XCTAssertEqual(after.installationID, before.installationID); XCTAssertEqual(after.commonRootID, before.commonRootID)
    }

    @MainActor private func sceneLANWebViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { sceneLANWebViews(in: $0) }
    }

    /// Real pinned TLS/envelope/pairing/admission, then the unchanged Scene adapter and common CAS.
    /// Only the validator is decorated to prove ownership before any fixture grant secret is written.
    @discardableResult @MainActor private func exerciseAuthenticatedSceneLANInstall(host: DeviceLANHost, unified: DeviceUnifiedInventorySession,
        commonRoot: URL, controllerIdentity: TLSIdentityMaterial, deviceIdentity: TLSIdentityMaterial,
        grants: SceneLANOwnedGrantObserver, expectRetainedCloud: Bool, verifyStaticProjection: Bool = true,
        initialListener: SceneLANListenerProbe? = nil) async throws
        -> (operationID: UUID, entryID: UUID, revision: String) {
        let server = try XCTUnwrap(host.server), actualPrepare = try XCTUnwrap(host.server?.prepareIncomingLocalScreens)
        server.prepareIncomingLocalScreens = { operation, peer, screens, selected, original in
            try actualPrepare(operation, peer, screens, selected, {
                try original()
                try grants.observeFreshGrant(operation: operation)
            })
        }
        defer { server.prepareIncomingLocalScreens = actualPrepare }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while host.port == 0 && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(host.port, 0)
        let port = host.port, client = ControllerLANClient(identity: controllerIdentity)
        defer { client.cancel() }
        func assertStableInitialListener() {
            guard let initialListener else { return }
            let observed = initialListener.snapshot
            XCTAssertEqual(observed.starts, 1, "Initial host readiness cannot rotate a live authenticated listener")
            XCTAssertEqual(observed.ready, 1, "The same initial listener remains ready throughout the authenticated flow")
            XCTAssertEqual(host.port, port)
            XCTAssertEqual(server.advertisedDevice.port, Int(port))
        }
        assertStableInitialListener()
        defer { assertStableInitialListener() }
        let nonce = PairingIdentityFactory.nonce()
        let begin = try await Task.detached {
            try SceneLANCallDiagnostic.run(.connect) {
                try client.connect(host: "127.0.0.1", port: port, pinnedDevice: deviceIdentity.pin, timeout: 10)
            }
            let hello = try SceneLANCallDiagnostic.run(.hello) { try client.hello() }
            XCTAssertEqual(client.observedDevicePin, deviceIdentity.pin)
            XCTAssertEqual(hello.pinHex, PeerPin.hex(deviceIdentity.pin))
            XCTAssertTrue(hello.capabilities?.contains("unified-local-screen-install-v1") == true)
            return try SceneLANCallDiagnostic.run(.begin) { try client.beginPairing(nonce: nonce) }
        }.value
        assertStableInitialListener()
        XCTAssertEqual(begin.code, PairingSAS.matchingCode(for: .init(devicePublicKey: deviceIdentity.pin,
            controllerPublicKey: controllerIdentity.pin, sessionNonce: nonce)))
        try SceneLANCallDiagnostic.run(.localConfirm) {
            try server.confirmLocally(expectedSessionNonceHex: PeerPin.hex(nonce))
        }
        let baseline = try await Task.detached {
            try SceneLANCallDiagnostic.run(.confirm) { try client.confirmPairing(code: begin.code) }
            return try SceneLANCallDiagnostic.run(.query) { try client.queryActiveState() }
        }.value
        assertStableInitialListener()
        XCTAssertEqual(baseline.controllerApproved, true)
        let before = try unified.validatedAssociation()
        XCTAssertEqual(UUID(uuidString: try XCTUnwrap(baseline.stateGenerationId)), before.generationID)
        XCTAssertEqual(baseline.commonEntries?.contains(where: { $0.origin == "cloud" }), expectRetainedCloud)
        let profile = host.runtime.profile
        var declared = profile; declared.apply(orientation: .landscape)
        let operation = UUID(), entry = UUID(), revisionID = UUID().uuidString.lowercased()
        let bytes = Data("<html><body>Authenticated Scene LAN legacy Screen</body></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: "google-tv-test", name: "Legacy LAN Screen",
            revision: revisionID, entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: profile.deviceId, width: declared.width, height: declared.height, scale: 2,
                orientation: "landscape"), connections: [],
            files: [.init(path: "index.html", bytes: bytes.count, sha256: AuthorityStaticDeliveryFixture.hash(bytes))])
        manifest.digest = AuthorityStaticDeliveryFixture.hash(try AuthorityStaticDeliveryFixture.encoded(manifest))
        let manifestBytes = try AuthorityStaticDeliveryFixture.encoded(manifest)
        let revision = StoredRevision(revision: revisionID, dashboardId: "google-tv-test", name: manifest.name,
            digest: try XCTUnwrap(manifest.digest), orientation: .landscape, width: declared.width, height: declared.height)
        let files = [("manifest.json", manifestBytes), ("index.html", bytes)].map { path, data in
            LANFileBlob(path: path, sha256: AuthorityStaticDeliveryFixture.hash(data), dataBase64: data.base64EncodedString())
        }
        let deployment = DeploymentRecord(deploymentId: operation.uuidString.lowercased(), revision: revisionID,
            dashboardId: "google-tv-test", deviceId: profile.deviceId, phase: .queued)
        let plan = LANUnifiedScreenInstall(operationId: operation.uuidString.lowercased(),
            expectedGenerationId: try XCTUnwrap(baseline.stateGenerationId),
            retainedEntryIds: before.entries.map { $0.entryID.uuidString.lowercased() }, selectedEntryId: entry.uuidString.lowercased(),
            incoming: [.init(entryId: entry.uuidString.lowercased(), screen: .init(name: manifest.name,
                deployment: .init(deployment: deployment, revision: revision, files: files)))])
        let installed = try await Task.detached {
            try SceneLANCallDiagnostic.run(.install) { try client.installUnifiedScreens(plan) }
        }.value
        assertStableInitialListener()
        XCTAssertEqual(UUID(uuidString: try XCTUnwrap(installed.stateGenerationId)), operation)
        XCTAssertEqual(UUID(uuidString: try XCTUnwrap(installed.configuredEntryId)), entry)
        let local = try XCTUnwrap(installed.commonEntries?.first { UUID(uuidString: $0.entryId) == entry })
        XCTAssertEqual(local.dashboardId, "google-tv-test"); XCTAssertEqual(local.revision, revisionID)
        XCTAssertEqual(local.origin, "retainedLocal")
        XCTAssertEqual(installed.commonEntries?.count, before.entries.count + 1)
        let association = try unified.validatedAssociation()
        XCTAssertEqual(association.generationID, operation); XCTAssertEqual(association.configuredEntryID, entry)
        XCTAssertEqual(association.entries.first { $0.entryID == entry }?.manifestDigest, manifest.digest)
        if verifyStaticProjection {
            let content = try unified.selectedContent(operationID: UUID())
            try content.verifyResources()
            XCTAssertEqual(content.entryID, entry); XCTAssertEqual(content.revision, revisionID)
            XCTAssertEqual(content.assets.first { $0.path == "manifest.json" }?.bytes, manifestBytes)
            XCTAssertEqual(content.assets.first { $0.path == "index.html" }?.bytes, bytes)
        }
        let onDisk = try Data(contentsOf: commonRoot.appendingPathComponent("mixed-current.json"))
        let replay = try await Task.detached {
            try SceneLANCallDiagnostic.run(.replay) { try client.installUnifiedScreens(plan) }
        }.value
        let readback = try await Task.detached {
            try SceneLANCallDiagnostic.run(.readback) { try client.queryActiveState() }
        }.value
        assertStableInitialListener()
        XCTAssertEqual(replay.stateGenerationId, installed.stateGenerationId); XCTAssertEqual(readback.stateGenerationId, installed.stateGenerationId)
        XCTAssertEqual(replay.commonEntries, installed.commonEntries); XCTAssertEqual(readback.commonEntries, installed.commonEntries)
        XCTAssertEqual(readback.configuredEntryId, installed.configuredEntryId)
        XCTAssertEqual(try Data(contentsOf: commonRoot.appendingPathComponent("mixed-current.json")), onDisk,
            "Exact authenticated replay must read its completed receipt, without another common CAS")
        XCTAssertTrue(grants.hasOwnedGrant, "The real Scene handler must have prepared its fixture-owned grant")
        return (operation, entry, revisionID)
    }

    private final class SceneLANOwnedGrantObserver: @unchecked Sendable {
        let directory: URL
        private let lock = NSLock()
        private var service: String?
        init(directory: URL) { self.directory = directory }
        var hasOwnedGrant: Bool { lock.lock(); defer { lock.unlock() }; return service != nil }
        private func query(_ service: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
             kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        }
        func observeFreshGrant(operation: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            if service != nil { return }
            let file = directory.appendingPathComponent("local-command-" + operation.uuidString.lowercased() + ".json")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let root = try XCTUnwrap(UUID(uuidString: XCTUnwrap(body["grant"] as? String)))
            let name = DeviceGrantCredentialNamespace(rootID: root).service
            guard SecItemCopyMatching(query(name) as CFDictionary, nil) == errSecItemNotFound else {
                throw NativeRecoveryFixtureFailure.unexpectedEffect // No ownership, so never clean a pre-existing service.
            }
            service = name
        }
        func close() {
            lock.lock(); defer { lock.unlock() }
            guard let service else { return }
            let status = SecItemDelete(query(service) as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(query(service) as CFDictionary, nil), errSecItemNotFound)
            self.service = nil
        }
    }

    /// Same synthetic app-Keychain recipe as the existing real-host test, with fresh tags per role/test.
    @MainActor private func makeSceneLANTLSIdentity(role: PairingRole) throws -> (identity: TLSIdentityMaterial, close: () -> Void) {
        let tag = "xyz.screenpunk.test.scene-lan.\(role.rawValue).\(UUID().uuidString)"
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
        let certQuery: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: tag]
        guard SecItemCopyMatching(keyQuery as CFDictionary, nil) == errSecItemNotFound,
              SecItemCopyMatching(certQuery as CFDictionary, nil) == errSecItemNotFound else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let cleanup = {
            let certificate = SecItemDelete(certQuery as CFDictionary), key = SecItemDelete(keyQuery as CFDictionary)
            XCTAssertTrue(certificate == errSecSuccess || certificate == errSecItemNotFound)
            XCTAssertTrue(key == errSecSuccess || key == errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(certQuery as CFDictionary, nil), errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(keyQuery as CFDictionary, nil), errSecItemNotFound)
        }
        var completed = false
        defer { if !completed { cleanup() } }
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256, kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: tag, kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let bytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let der = try SelfSignedCertificate.make(commonName: tag, publicPoint: Array(bytes), privateKey: key)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate,
            kSecAttrLabel as String: tag] as CFDictionary, nil), errSecSuccess)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: tag,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess)
        let identity = try XCTUnwrap(item)
        guard CFGetTypeID(identity) == SecIdentityGetTypeID() else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        completed = true
        return (TLSIdentityMaterial(identity: identity as! SecIdentity, pin: PeerPin.sha256(bytes), role: role), cleanup)
    }

    @MainActor func testExplicitLocalSelectionStartsCompletedEmptyDetachedHostAndPairing() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        // Only this borrowed Simulator test app's fresh, exact tag/label is used.
        // No default device/controller TLS tag or physical/Mac Keychain is accessed.
        let tag = "xyz.screenpunk.test.mini-local.\(UUID().uuidString)"
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
        let certificateQuery: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: tag]
        let initialKeyStatus = SecItemCopyMatching(keyQuery as CFDictionary, nil)
        let initialCertificateStatus = SecItemCopyMatching(certificateQuery as CFDictionary, nil)
        XCTAssertEqual(initialKeyStatus, errSecItemNotFound)
        XCTAssertEqual(initialCertificateStatus, errSecItemNotFound)
        guard initialKeyStatus == errSecItemNotFound, initialCertificateStatus == errSecItemNotFound else {
            throw NativeRecoveryFixtureFailure.unexpectedEffect // Never delete or reuse a pre-existing identity.
        }
        defer {
            let certificateStatus = SecItemDelete(certificateQuery as CFDictionary)
            XCTAssertTrue(certificateStatus == errSecSuccess || certificateStatus == errSecItemNotFound)
            let keyStatus = SecItemDelete(keyQuery as CFDictionary)
            XCTAssertTrue(keyStatus == errSecSuccess || keyStatus == errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(keyQuery as CFDictionary, nil), errSecItemNotFound)
            XCTAssertEqual(SecItemCopyMatching(certificateQuery as CFDictionary, nil), errSecItemNotFound)
        }
        let key = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrLabel as String: tag,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        ] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let publicBytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let der = try SelfSignedCertificate.make(commonName: tag, publicPoint: Array(publicBytes), privateKey: key)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(SecItemAdd([kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate, kSecAttrLabel as String: tag] as CFDictionary, nil), errSecSuccess)
        var identityItem: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: tag,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &identityItem), errSecSuccess)
        let identityValue = try XCTUnwrap(identityItem)
        guard CFGetTypeID(identityValue) == SecIdentityGetTypeID() else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let identity = TLSIdentityMaterial(identity: identityValue as! SecIdentity,
            pin: PeerPin.sha256(publicBytes), role: .device)
        XCTAssertNoThrow(try fixture.authority.validateRecordedNativeStartup(), "Existing current Cloud namespace remains strictly qualified")
        let cloudLocal = try fixture.authority.makeConcurrentLocalContext(context: fixture.context, session: fixture.common)
        let cloudAssociation = try fixture.common.validatedAssociation()
        try cloudLocal.withAuthority {
            XCTAssertEqual(try cloudLocal.qualifiedCloudInstallationIDUnderAuthority(), fixture.activation.installationId)
            try cloudLocal.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: cloudAssociation.commonRootID,
                installationID: cloudAssociation.installationID)
            XCTAssertThrowsError(try cloudLocal.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: UUID(),
                installationID: cloudAssociation.installationID))
            XCTAssertThrowsError(try cloudLocal.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: cloudAssociation.commonRootID,
                installationID: UUID()))
        }
        let cloudServer = try DeviceLANServer(management: cloudLocal, runtime: DeviceRuntimeRootView.unpairedRuntime(),
            identity: identity, store: .init(root: fixture.parent.appendingPathComponent("cloud-host-state")),
            homeAssistantVault: .init(store: MemoryCredentialStore()), genericConnectionVault: .init(store: MemoryCredentialStore()))
        defer { cloudServer.retireForReset() }
        try cloudServer.attachUnifiedLocalSession(fixture.common)
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let request = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await request.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        let detachedManagement = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        XCTAssertThrowsError(try cloudLocal.withAuthority {})
        XCTAssertThrowsError(try cloudServer.attachUnifiedLocalSession(detached), "A retired Cloud context cannot borrow the detached session")
        let association = try detached.detachedAssociation()
        let namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        XCTAssertTrue(try detached.validatedAssociation().entries.isEmpty)
        let before = try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json"))
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))

        var hostCreations = 0
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { XCTFail("No legacy fallback"); return .empty },
            hostFactory: { context in
                hostCreations += 1
                return try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                    store: .init(root: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("local-host-state")),
                    identityProvider: { identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                    genericConnectionVault: .init(store: MemoryCredentialStore()))
            })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        guard case .cloudReady = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let detachedAssociation = try detached.validatedAssociation()
        try detachedManagement.withAuthority {
            XCTAssertNil(try detachedManagement.qualifiedCloudInstallationIDUnderAuthority(), "Detached Local never claims a Cloud connection")
            try detachedManagement.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: detachedAssociation.commonRootID,
                installationID: detachedAssociation.installationID)
            XCTAssertThrowsError(try detachedManagement.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: UUID(),
                installationID: detachedAssociation.installationID))
            XCTAssertThrowsError(try detachedManagement.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: detachedAssociation.commonRootID,
                installationID: UUID()))
        }
        let rootBeforeFailedPreparation = bootstrap.rootGeneration
        var failedCandidate: DeviceLANHost?
        XCTAssertThrowsError(try bootstrap.installConcurrentHost(context: detachedManagement, prepare: { host in
            failedCandidate = host
            try XCTUnwrap(host.server).attachUnifiedLocalSession(detached)
            throw NativeRecoveryFixtureFailure.unexpectedEffect
        }))
        guard case .cloudReady = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertEqual(bootstrap.rootGeneration, rootBeforeFailedPreparation)
        XCTAssertTrue(try XCTUnwrap(failedCandidate).lifetime.isRetired)
        XCTAssertEqual(failedCandidate?.server?.port, 0)
        let creationsBeforeLocalSelection = hostCreations
        XCTAssertEqual(creationsBeforeLocalSelection, 1, "Only the deliberately failed preparation has created a candidate")
        let controller = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap) { _, _ in XCTFail("Completed cleanup cannot rerun"); throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let requests = fixture.http.requestCount
        var cloudCalls = 0
        let view = KioskLaunchView(bootstrap: bootstrap, automaticStartup: false,
            onCloudAccountRequested: { cloudCalls += 1 }, onLocalStartupRequested: {
                await controller.requestLocalConnection(bootstrap: bootstrap)
            })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting; window.makeKeyAndVisible()
        defer {
            controller.commonHost?.retireForReset()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        let local = try await waitForLocalStartupElement("Local Screenpunk", in: hosting.view, button: true)
        XCTAssertEqual(hostCreations, creationsBeforeLocalSelection, "Constructing and mounting Welcome cannot start the host")
        XCTAssertTrue(local.accessibilityActivate(), "Exercise the actual displayed Local action")
        _ = try await waitForLocalStartupElement("Waiting for your Mac", in: hosting.view)
        let host = try XCTUnwrap(controller.commonHost)
        guard case .localReady(let admitted) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(admitted === host)
        XCTAssertNotNil(host.server)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while host.port == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(host.port, 0, "The real admitted host listener becomes advertisable")
        XCTAssertNil(host.errorMessage)
        XCTAssertEqual(hostCreations, creationsBeforeLocalSelection + 1)
        let retryFailure = await controller.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNil(retryFailure); XCTAssertEqual(hostCreations, creationsBeforeLocalSelection + 1, "Reuse the same admitted detached host")
        XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before)
        XCTAssertTrue(try detached.detachedAssociation().metadata.cleanupCompleted)
        XCTAssertNil(try journal.load()); XCTAssertEqual(cloudCalls, 0)
        XCTAssertEqual(fixture.http.requestCount, requests, "Local selection cannot reactivate or fetch Cloud")
        try assertIncomingLANProfileBoundary(host: host, journal: journal,
            hardwareProfile: try XCTUnwrap(controller.suggestedDeviceProfile), validateOriginal: { try detachedManagement.validate() })
        XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before,
            "Preparing LAN input does not change common CAS or activate a screen")
        let currentCloud = try await NativePreparedConnectionFixture.make(cloudProtocolFixture: true, hostFactory: { context in
            try DeviceLANHost(runtime: DeviceRuntimeRootView.unpairedRuntime(), management: context,
                store: .init(root: fixture.parent.appendingPathComponent("current-cloud-host-state")),
                identityProvider: { identity }, homeAssistantVault: .init(store: MemoryCredentialStore()),
                genericConnectionVault: .init(store: MemoryCredentialStore()))
        })
        defer { currentCloud.controller.commonHost?.retireForReset(); currentCloud.close() }
        currentCloud.http.productionSequenceEnabled = true
        try await currentCloud.controller.runPreparedDeviceOnlyConnectionForTesting()
        let currentCloudHost = try XCTUnwrap(currentCloud.controller.commonHost)
        let cloudBefore = try currentCloud.unified.validatedAssociation()
        let cloudRoot = currentCloud.parent.appendingPathComponent("Application Support/xyz.screenpunk.unified-inventory")
        let cloudBytes = try Data(contentsOf: cloudRoot.appendingPathComponent("mixed-current.json"))
        let cloudJournal = NativeEnrollmentIntentJournal(directory: currentCloud.parent.appendingPathComponent("Application Support/xyz.screenpunk.enrollment-intent"))
        try assertIncomingLANProfileBoundary(host: currentCloudHost, journal: cloudJournal,
            hardwareProfile: try XCTUnwrap(currentCloud.controller.retainedDeviceProfile), validateOriginal: {
                _ = try currentCloud.unified.validatedAssociation()
            })
        XCTAssertEqual(try Data(contentsOf: cloudRoot.appendingPathComponent("mixed-current.json")), cloudBytes)
        let cloudAfter = try currentCloud.unified.validatedAssociation()
        XCTAssertEqual(cloudAfter.generationID, cloudBefore.generationID)
        XCTAssertEqual(cloudAfter.installationID, cloudBefore.installationID)
        XCTAssertEqual(currentCloud.controller.retainedDeviceProfile, "Fixture", "Cloud package qualification keeps its original hardware profile")
        let publishedRoot = bootstrap.rootGeneration
        var rejectedReplacement: DeviceLANHost?
        XCTAssertThrowsError(try bootstrap.installConcurrentHost(context: detachedManagement, prepare: { replacement in
            rejectedReplacement = replacement
            try XCTUnwrap(replacement.server).attachUnifiedLocalSession(detached)
            throw NativeRecoveryFixtureFailure.unexpectedEffect
        }))
        guard case .localReady(let unchangedHost) = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertTrue(unchangedHost === host); XCTAssertFalse(host.lifetime.isRetired)
        XCTAssertEqual(bootstrap.rootGeneration, publishedRoot)
        XCTAssertTrue(try XCTUnwrap(rejectedReplacement).lifetime.isRetired)
        try fixture.authority.retireDetachedLocalContext(candidate)
        XCTAssertThrowsError(try detachedManagement.withAuthority {})
        XCTAssertThrowsError(try XCTUnwrap(host.server).attachUnifiedLocalSession(detached), "Stale detached authority cannot attach again")
    }

    /// Exercise the actual Scene-installed adapter and real package/grant/structural preparation.
    /// Authenticated LAN envelope admission and final common CAS remain separate boundaries.
    @MainActor private func assertIncomingLANProfileBoundary(host: DeviceLANHost, journal: NativeEnrollmentIntentJournal,
        hardwareProfile: String, validateOriginal: @escaping () throws -> Void) throws {
        let prepare = try XCTUnwrap(host.server?.prepareIncomingLocalScreens)
        let profile = host.runtime.profile
        XCTAssertNotEqual(profile.deviceId, hardwareProfile)
        if !FileManager.default.fileExists(atPath: journal.directory.path) {
            try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        for (profileID, accepted) in [(hardwareProfile, false), ("device-foreign-" + UUID().uuidString.lowercased(), false), (profile.deviceId, true)] {
            let operation = UUID(), entry = UUID(), peer = PairingIdentityFactory.make(role: .controller)
            let html = Data("<html><body>LAN identity qualification</body></html>".utf8)
            var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "LAN target",
                revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
                target: .init(profileId: profileID, width: profile.width, height: profile.height, scale: 1,
                    orientation: profile.orientation.rawValue), connections: [],
                files: [.init(path: "index.html", bytes: html.count, sha256: AuthorityStaticDeliveryFixture.hash(html))])
            manifest.digest = AuthorityStaticDeliveryFixture.hash(try AuthorityStaticDeliveryFixture.encoded(manifest))
            let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name,
                digest: try XCTUnwrap(manifest.digest), orientation: profile.orientation, width: profile.width, height: profile.height)
            let screen = DeviceLegacyMigrationScreen(entryID: entry, packageOperationID: UUID(), displayName: manifest.name,
                revision: revision, manifest: try AuthorityStaticDeliveryFixture.encoded(manifest), files: ["index.html": html],
                homeAssistant: nil, generic: nil, publicReads: nil)
            var ownedService: String?
            func credentialQuery(_ service: String) -> [String: Any] {
                [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
            }
            defer {
                if let service = ownedService {
                    let status = SecItemDelete(credentialQuery(service) as CFDictionary)
                    XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
                    XCTAssertEqual(SecItemCopyMatching(credentialQuery(service) as CFDictionary, nil), errSecItemNotFound)
                }
            }
            let validate = {
                try validateOriginal()
                if ownedService == nil {
                    // The production adapter has allocated this fixture operation's immutable
                    // grant root, but calls this validator before qualification or secret writes.
                    let path = journal.directory.appendingPathComponent("local-command-" + operation.uuidString.lowercased() + ".json")
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                    let rootID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(object["grant"] as? String)))
                    let service = DeviceGrantCredentialNamespace(rootID: rootID).service
                    let status = SecItemCopyMatching(credentialQuery(service) as CFDictionary, nil)
                    XCTAssertEqual(status, errSecItemNotFound)
                    guard status == errSecItemNotFound else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
                    ownedService = service // Cleanup is permitted only after confirmed fresh absence.
                }
            }
            if accepted {
                let preparation = try prepare(operation, peer, [screen], entry, validate)
                XCTAssertEqual(preparation.resources.operationID, operation)
            } else {
                XCTAssertThrowsError(try prepare(operation, peer, [screen], entry, validate)) {
                    XCTAssertEqual($0 as? DevicePackageQualificationError, .targetMismatch)
                }
                let service = try XCTUnwrap(ownedService)
                XCTAssertEqual(SecItemCopyMatching(credentialQuery(service) as CFDictionary, nil), errSecItemNotFound,
                    "Rejected targets cannot create grant credentials")
            }
        }
    }

    @MainActor private func waitForLocalStartupElement(_ label: String, in view: UIView, button: Bool = false) async throws -> NSObject {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            view.layoutIfNeeded()
            var visited: Set<ObjectIdentifier> = []
            if let element = localStartupAccessibilityElements(view, visited: &visited).first(where: {
                ($0.accessibilityLabel?.contains(label) == true) && (!button || $0.accessibilityTraits.contains(.button))
            }) { return element }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Missing actual Local startup element: \(label)")
        throw NativeRecoveryFixtureFailure.unexpectedEffect
    }
    @MainActor private func localStartupAccessibilityElements(_ object: NSObject, visited: inout Set<ObjectIdentifier>) -> [NSObject] {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
        var children = (object as? UIView)?.subviews.map { $0 as NSObject } ?? []
        if #available(iOS 17, *) { children += object.automationElements?.compactMap { $0 as? NSObject } ?? [] }
        children += object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
        let count = object.accessibilityElementCount()
        if count > 0 && count < 1_000 { children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject } }
        return [object] + children.flatMap { localStartupAccessibilityElements($0, visited: &visited) }
    }
#endif

    @MainActor func testColdCompletedEmptyDetachmentRestoresUnderNewAuthorityBeforeExplicitLocalRetry() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let request = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await request.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let association = try detached.detachedAssociation()
        let namespace = try association.credentialRetirement().namespaceURL
        try association.validateCloudCleanupScope(namespace: namespace)
        for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
        try FileManager.default.removeItem(at: namespace)
        let coldReset = NativeColdDetachedResetEvidence()
        let coldAuthority = DeviceManagementAuthority(journal: AuthorityJournal(),
            credentials: .init(backend: AuthorityBackend(), random: { Data() }), reset: coldReset,
            managedNamespace: try .fixture(existingPhysicalAnchor: fixture.parent.appendingPathComponent("Application Support")),
            supportAnchorSetup: try .fixture(existingPhysicalParent: fixture.parent),
            commandIntents: .init(root: fixture.parent.appendingPathComponent("command-intents")), concurrentControlQualified: true)
        XCTAssertThrowsError(try coldAuthority.validateRecordedDetachedLocalStartup(commonRootID: candidate.commonRootID,
            retiredInstallationID: candidate.retiredInstallationID), "Absent Cloud namespace alone cannot qualify unfinished cleanup")
        let cleanup = try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
        try detached.finishCloudDetachCleanup(receipt: cleanup, operationID: UUID(), generationID: UUID())
        let saved = try detached.detachedAssociation().metadata
        XCTAssertTrue(saved.cleanupCompleted)
        let before = try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json"))
        let requests = fixture.http.requestCount
        XCTAssertThrowsError(try coldAuthority.validateRecordedNativeStartup(), "Completed detachment must not satisfy strict recorded Cloud readiness")
        XCTAssertNoThrow(try coldAuthority.validateRecordedDetachedLocalStartup(commonRootID: saved.commonRootID,
            retiredInstallationID: saved.retiredInstallationID))
        XCTAssertThrowsError(try coldAuthority.validateRecordedDetachedLocalStartup(commonRootID: UUID(),
            retiredInstallationID: saved.retiredInstallationID))
        XCTAssertThrowsError(try coldAuthority.validateRecordedDetachedLocalStartup(commonRootID: saved.commonRootID,
            retiredInstallationID: UUID()))
        coldReset.record = try DeviceLocalResetRecord(resetID: UUID(), scopeDigest: coldReset.scopeDigest)
        XCTAssertThrowsError(try coldAuthority.validateRecordedDetachedLocalStartup(commonRootID: saved.commonRootID,
            retiredInstallationID: saved.retiredInstallationID), "Pending reset cannot become detached startup permission")
        coldReset.record = nil
        do {
            let moved = candidate.commonRoot.appendingPathExtension("cold-startup-test-held")
            try FileManager.default.moveItem(at: candidate.commonRoot, to: moved)
            defer {
                try? FileManager.default.removeItem(at: candidate.commonRoot)
                try? FileManager.default.moveItem(at: moved, to: candidate.commonRoot)
            }
            try FileManager.default.createDirectory(at: candidate.commonRoot, withIntermediateDirectories: false)
            XCTAssertThrowsError(try coldAuthority.validateRecordedDetachedLocalStartup(commonRootID: saved.commonRootID,
                retiredInstallationID: saved.retiredInstallationID), "A replacement root without the exact saved CAS cannot qualify")
        }
        XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before)

        // New process-owned objects must discover and qualify the saved detachment.
        // The old live session/context is not injected into this controller or owner.
        var admissions = 0
        let bootstrap = DeviceManagementBootstrap(preparationFactory: {
            .init(authority: coldAuthority, constructLifecycle: {
                XCTFail("Detached startup must not fall through to legacy lifecycle admission")
                throw NativeRecoveryFixtureFailure.unexpectedEffect
            })
        }, retained: { XCTFail("No legacy fallback"); return .empty }, hostFactory: { context in
                try context.validate()
                try context.withAuthority {
                    XCTAssertNil(try context.qualifiedCloudInstallationIDUnderAuthority())
                    try context.validateUnifiedLocalAttachmentUnderAuthority(commonRootID: saved.commonRootID,
                        installationID: saved.retiredInstallationID)
                }
                admissions += 1
                // Deliberate endpoint: proves cold resource/authority admission independently
                // of the warm real-host test and the physical default TLS loading gate.
                throw NativeRecoveryFixtureFailure.unexpectedEffect
            })
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        let controller = NativeEnrollmentSceneController(intentJournal: journal)
        XCTAssertTrue(controller.requiresDeviceOwnedStartup)
        XCTAssertTrue(controller.isCloudLoggedOut)
        bootstrap.useRecordedNativeCloudStartup()
        XCTAssertFalse(bootstrap.readyToValidateRecordedDetachedRestore)
        bootstrap.start()
        XCTAssertTrue(bootstrap.currentAuthority === coldAuthority)
        XCTAssertFalse(bootstrap.readyToValidateRecordedDetachedRestore, "Prepared owner reset recovery must finish first")
        let preparationDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !bootstrap.readyToValidateRecordedDetachedRestore && ProcessInfo.processInfo.systemUptime < preparationDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .cloudReady = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        XCTAssertEqual(bootstrap.startupDiagnostic?.stage, .namespace)
        XCTAssertNil(bootstrap.cloudAuthorityGeneration)
        XCTAssertFalse(bootstrap.readyForRecordedNativeRestore, "Strict Cloud readiness remains unavailable after cleanup")
        XCTAssertTrue(bootstrap.readyToValidateRecordedDetachedRestore)
        XCTAssertNoThrow(try bootstrap.validateRecordedDetachedLocalStartup(commonRootID: saved.commonRootID,
            retiredInstallationID: saved.retiredInstallationID))
        controller.reconnectInstallation(bootstrap: bootstrap)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while controller.hasActiveEnrollmentWork && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.hasActiveEnrollmentWork)
        XCTAssertEqual(admissions, 1, "Cold restore must reach genuine detached authority before host creation")
        XCTAssertTrue(try controller.installedCloudScreens().entries.isEmpty)
        XCTAssertTrue(controller.isCloudLoggedOut); XCTAssertFalse(controller.cloudLogoutCleanupPending)
        XCTAssertFalse(controller.hasRecordedCloudInstallation)
        XCTAssertNil(controller.commonHost)
        guard case .cloudReady = bootstrap.state else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
        let failure = await controller.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNotNil(failure); XCTAssertEqual(admissions, 2, "Explicit Local retries the newly rehydrated session exactly once")
        XCTAssertEqual(try Data(contentsOf: candidate.commonRoot.appendingPathComponent("mixed-current.json")), before)
        XCTAssertNil(try journal.load()); XCTAssertEqual(fixture.http.requestCount, requests)
        controller.didEnterBackground()
    }

    @MainActor func testConfirmedLogoutCleanupFailureRemainsActionableAndExactRetryReturnsToWelcome() async throws {
        let fixture = try await GenuineUnifiedInventoryFixture.make()
        defer { fixture.close() }
        let retirement = try fixture.installation.captureCloudCredentialRetirement(native: fixture.execution)
        let candidate = try fixture.authority.prepareCloudDetachment(context: fixture.context, session: fixture.common)
        let pending = try fixture.common.beginCloudDetach(retirement: retirement, operationID: UUID(), generationID: UUID(),
            detachOperationID: UUID(), detachGenerationID: UUID())
        let request = try fixture.installation.makeSelfRevocationRequest(origin: fixture.http.origin, activation: fixture.activation)
        let revoked = try await request.performFixedTransport(origin: fixture.http.origin, configuration: fixture.http.configuration)
        let detached = try fixture.common.detachCloud(revocation: revoked, operationID: pending.detachOperationID,
            generationID: pending.detachGenerationID, validateDetached: { try fixture.authority.validateDetachedLocalResources(candidate) },
            validateMutation: { try fixture.authority.validateDetachedLocalResources(candidate) })
        _ = try fixture.authority.acceptDetachedLocalSession(detached, context: candidate)
        let journal = NativeEnrollmentIntentJournal(directory: candidate.commonRoot.deletingLastPathComponent().appendingPathComponent("intent"))
        var localHostAttempts = 0
        let bootstrap = DeviceManagementBootstrap(authority: fixture.authority, retained: { .empty },
            hostFactory: { context in
                try context.validate()
                localHostAttempts += 1
                throw NativeRecoveryFixtureFailure.unexpectedEffect
            })
        var attempts = 0
        let controller = try NativeEnrollmentSceneController(testDetachedJournal: journal, session: detached,
            context: candidate, bootstrap: bootstrap) { association, namespace in
                attempts += 1
                if attempts == 1 { throw NativeRecoveryFixtureFailure.unexpectedEffect }
                try association.validateCloudCleanupScope(namespace: namespace)
                for item in retirement.credentials { try fixture.removeCloudCredentialExact(item) }
                try FileManager.default.removeItem(at: namespace)
                return try retirement.confirmCleanup(namespace: namespace, probe: fixture.cloudAbsenceProbe)
            }
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        await controller.disconnectCloudDevice(lifecycle: lifecycle)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(controller.cloudLogoutCleanupPending)
        XCTAssertFalse(controller.isCloudLoggedOut, "The existing Settings action remains until cleanup commits")
        XCTAssertEqual(controller.cloudConnectionState, .needsAttention)
        XCTAssertFalse(controller.disconnectInProgress)
        XCTAssertNotNil(controller.disconnectMessage)
        let requests = fixture.http.requestCount
        let pendingLocalFailure = await controller.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNotNil(pendingLocalFailure)
        XCTAssertEqual(localHostAttempts, 0, "Explicit Local cannot skip unfinished Cloud cleanup")
        controller.retryCloudConnection(bootstrap: bootstrap)
        XCTAssertEqual(fixture.http.requestCount, requests, "Connection retry cannot use the already revoked native credential")
        await controller.disconnectCloudDevice(lifecycle: lifecycle)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.cloudLogoutCleanupPending)
        XCTAssertTrue(controller.isCloudLoggedOut)
        XCTAssertEqual(controller.cloudConnectionState, .notConnected)
        XCTAssertFalse(controller.hasRecordedCloudInstallation)
        XCTAssertNil(controller.content); XCTAssertNil(controller.emptyDisplayGeneration)
        XCTAssertNil(try journal.load())
        XCTAssertTrue(try detached.detachedAssociation().metadata.cleanupCompleted)
        XCTAssertEqual(fixture.http.requestCount, requests, "Cleanup retry needs neither OAuth nor another revoke")
        XCTAssertEqual(localHostAttempts, 1, "Completed cleanup already attempts the existing detached host handoff")
        let attemptsBeforeExplicitLocal = localHostAttempts
        let beforeLocal = try detached.detachedAssociation().metadata
        let firstLocalFailure = await controller.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNotNil(firstLocalFailure, "An actual host factory error is displayed")
        XCTAssertEqual(localHostAttempts, attemptsBeforeExplicitLocal + 1, "Completed empty detachment reaches genuine host admission exactly once")
        XCTAssertEqual(controller.disconnectMessage, firstLocalFailure)
        let retryLocalFailure = await controller.requestLocalConnection(bootstrap: bootstrap)
        XCTAssertNotNil(retryLocalFailure)
        XCTAssertEqual(localHostAttempts, attemptsBeforeExplicitLocal + 2, "Retry repeats the same local operation exactly once, not bootstrap Cloud routing")
        let afterLocal = try detached.detachedAssociation().metadata
        XCTAssertEqual(afterLocal.generationID, beforeLocal.generationID)
        XCTAssertEqual(afterLocal.retiredInstallationID, beforeLocal.retiredInstallationID)
        XCTAssertEqual(afterLocal.revokedAt, beforeLocal.revokedAt)
        XCTAssertTrue(afterLocal.cleanupCompleted)
        XCTAssertTrue(try detached.validatedAssociation().entries.isEmpty)
        XCTAssertEqual(fixture.http.requestCount, requests, "Local selection sends no Cloud requests")
        controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: UUID(), locationID: nil,
            name: "New display", viewport: CGSize(width: 768, height: 1024))
        XCTAssertNotNil(controller.explicitConnectionOperationID, "Ordinary fresh Connect admission is available; this fixture has no human session")
        XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .selection)
    }

    @MainActor func testFinalEmptyDeliveryPublicationPreservesMountedViewOnlyForSameGeneration() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = NativeEnrollmentSceneController(intentJournal: .init(directory: parent.appendingPathComponent("intent")))
        var publications: [UUID?] = []
        let observer = controller.$emptyDisplayGeneration.dropFirst().sink { publications.append($0) }
        defer { observer.cancel() }
        let mounted = UUID()
        controller.publishEmptyDisplayIfChanged(generation: mounted)
        let beforeDeliveryFinished = publications
        // Uses the final delivery publication helper. Its earlier mounted view
        // can already have confirmed while the command/observation HTTP awaited.
        controller.publishEmptyDisplayIfChanged(generation: mounted)
        XCTAssertEqual(publications, beforeDeliveryFinished, "Same display must not retire/recreate its mounted view")
        XCTAssertEqual(controller.emptyDisplayGeneration, mounted)
        let changed = UUID()
        controller.publishEmptyDisplayIfChanged(generation: changed)
        XCTAssertEqual(Array(publications.suffix(2)), [nil, changed], "Changed display still retires the previous presentation")
        controller.didEnterBackground()
        XCTAssertNil(controller.emptyDisplayGeneration)
        XCTAssertNil(controller.completedExplicitConnectionOperationID, "Presentation publication itself never manufactures connection completion")
    }
    @MainActor func testExplicitConnectCompletionDoesNotAcceptFailureHistoricalActionOrBackground() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = NativeEnrollmentSceneController(intentJournal: .init(directory: parent.appendingPathComponent("intent")))
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let bootstrap = DeviceManagementBootstrap()
        let account = UUID()
        controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: account, locationID: nil,
            name: "Fixture", viewport: CGSize(width: 768, height: 1024))
        let first = try XCTUnwrap(controller.explicitConnectionOperationID)
        XCTAssertNil(controller.completedExplicitConnectionOperationID)
        XCTAssertThrowsError(try controller.requireExplicitConnectionCompletion(operationID: first))
        controller.reconnectInstallation(bootstrap: bootstrap)
        XCTAssertEqual(controller.explicitConnectionOperationID, first, "Automatic restore must not create an explicit presentation action")
        controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: account, locationID: nil,
            name: "Fixture", viewport: CGSize(width: 768, height: 1024))
        let second = try XCTUnwrap(controller.explicitConnectionOperationID)
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try controller.requireExplicitConnectionCompletion(operationID: first))
        XCTAssertThrowsError(try controller.requireExplicitConnectionCompletion(operationID: second))
        controller.didEnterBackground()
        XCTAssertNil(controller.explicitConnectionOperationID); XCTAssertNil(controller.completedExplicitConnectionOperationID)
        XCTAssertThrowsError(try controller.requireExplicitConnectionCompletion(operationID: second))
        XCTAssertNil(bootstrap.currentAuthority)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("intent/original.json").path))
    }
    @MainActor func testCommonRootDiscoveryAcceptsAbsenceButRejectsMalformedAndSymlinkBindings() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        XCTAssertNil(try journal.discoverCommonRootID())
        XCTAssertEqual(NativeEnrollmentSceneController(intentJournal: journal).state, .idle)
        let common = parent.appendingPathComponent("xyz.screenpunk.unified-inventory")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: false)
        XCTAssertNil(try journal.discoverCommonRootID(), "A namespace without a committed binding does not imply detach")
        let binding = common.appendingPathComponent("mixed-root.json")
        try Data("{}".utf8).write(to: binding)
        XCTAssertThrowsError(try journal.discoverCommonRootID())
        XCTAssertEqual(NativeEnrollmentSceneController(intentJournal: journal).state, .needsAttention)
        try FileManager.default.removeItem(at: binding)
        let external = parent.appendingPathComponent("external-binding.json")
        try JSONSerialization.data(withJSONObject: ["rootID": UUID().uuidString]).write(to: external)
        try FileManager.default.createSymbolicLink(at: binding, withDestinationURL: external)
        XCTAssertThrowsError(try journal.discoverCommonRootID(), "No-follow discovery cannot use a substituted binding")
        try FileManager.default.removeItem(at: binding)
        try FileManager.default.removeItem(at: common)
        let externalDirectory = parent.appendingPathComponent("external-common")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: common, withDestinationURL: externalDirectory)
        XCTAssertThrowsError(try journal.discoverCommonRootID(), "Missing descendants cannot hide a symlink parent")
    }

    @MainActor func testMarkedControllerWaitsForPreparedBootstrapReadinessBeforeAutomaticRestore() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Fixture", profile: "ipad",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 768, height: 1024))
        try journal.saveOriginal(intent); try journal.markRecordedInstallation(intent)
        let bytes = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
        let owner = DeviceManagementAuthority(journal: NativeRecoveryManagementJournal(), credentials: .init(backend: NativeRecoveryLegacyCredentials(), random: { XCTFail("no credentials"); return Data() }),
            reset: NativeRecoveryResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: parent))
        let bootstrap = DeviceManagementBootstrap(authority: owner, retained: { XCTFail("no legacy content"); return .empty }, hostFactory: { _ in throw NativeRecoveryFixtureFailure.unexpectedEffect })
        let controller = NativeEnrollmentSceneController(intentJournal: journal)
        XCTAssertTrue(controller.hasRecordedCloudInstallation); XCTAssertNotNil(bootstrap.currentAuthority)
        XCTAssertFalse(bootstrap.readyForRecordedNativeRestore)
        controller.reconnectInstallation(bootstrap: bootstrap)
        XCTAssertEqual(controller.state, .idle); XCTAssertNil(controller.enrollmentDiagnostic)
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), bytes)
    }
    func testOriginalEnrollmentIntentSurvivesRestartWithUnassignedLocation() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let original = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Display", profile: "ios",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 390, height: 844))
        try journal.saveOriginal(original)
        let restarted = NativeEnrollmentIntentJournal(directory: journal.directory)
        XCTAssertEqual(try restarted.load(), original)
        XCTAssertNil(try restarted.load()?.proposal().claimInput.locationId)
        try restarted.saveOriginal(original)
        try restarted.markRecordedInstallation(original)
        XCTAssertEqual(try restarted.load()?.requestID, original.requestID)
        XCTAssertTrue(try XCTUnwrap(restarted.load()).restoreRecordedInstallation)
    }
    func testOriginalEnrollmentIntentRejectsReplacementAndCorruptRecord() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        func record() throws -> NativeEnrollmentIntentRecord {
            try .init(accountID: UUID(), locationID: nil, name: "Display", profile: "ios",
                origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 390, height: 844))
        }
        let original = try record(); try journal.saveOriginal(original)
        XCTAssertThrowsError(try journal.saveOriginal(record()))
        XCTAssertEqual(try journal.load(), original)
        try Data("invalid".utf8).write(to: journal.directory.appendingPathComponent("original.json"))
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.saveOriginal(original))
    }
    func testCompletedIntentMarkerIsIdempotentAfterLostPublicationAcknowledgment() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let original = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Café", profile: "iPad",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 1024, height: 1366))
        try journal.saveOriginal(original)
        try journal.markRecordedInstallation(original)
        var marked = original; marked.restoreRecordedInstallation = true
        XCTAssertEqual(try journal.load(), marked)
        // The caller still holds the pre-publication original when acknowledgement
        // is lost. A retry must synchronize that exact completed successor again.
        try journal.markRecordedInstallation(original)
        XCTAssertEqual(try journal.load(), marked)
        let unrelated = try NativeEnrollmentIntentRecord(accountID: original.accountID, locationID: nil, name: original.name,
            profile: original.profile, origin: URL(string: original.origin)!, viewport: CGSize(width: 1024, height: 1366))
        XCTAssertThrowsError(try journal.markRecordedInstallation(unrelated))
        XCTAssertEqual(try journal.load(), marked)
        var changedBits = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        changedBits["name"] = "Cafe\u{301}"
        let changedOriginal = try JSONDecoder().decode(NativeEnrollmentIntentRecord.self,
            from: JSONSerialization.data(withJSONObject: changedBits))
        XCTAssertEqual(changedOriginal.name, original.name, "Swift semantic equality alone does not establish original UTF-8 bytes")
        XCTAssertThrowsError(try journal.markRecordedInstallation(changedOriginal))
        XCTAssertEqual(try journal.load(), marked)
        try Data("corrupt-retained-request".utf8).write(to: journal.directory.appendingPathComponent("original.json"))
        XCTAssertThrowsError(try journal.markRecordedInstallation(original))
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), Data("corrupt-retained-request".utf8))
    }
    func testOriginalJournalAcceptsPhysicalApplicationSupportAndPreservesOriginalBytes() throws {
        let parent = try physicalApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        XCTAssertNil(try journal.load()) // Actual absence, before any publication.
        let original = try journalRecord()
        try journal.saveOriginal(original)
        let bytes = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
        XCTAssertEqual(try NativeEnrollmentIntentJournal(directory: journal.directory).load(), original)
        try journal.saveOriginal(original)
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), bytes)
        XCTAssertEqual(try journal.load()?.cloudRootID, original.cloudRootID)
    }
    func testOriginalJournalRejectsSymlinkParentLeafAndHardlinkWithoutReplacingRequest() throws {
        let parent = try physicalApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let original = try journalRecord(); try journal.saveOriginal(original)
        let file = journal.directory.appendingPathComponent("original.json")
        let bytes = try Data(contentsOf: file)
        let alias = parent.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: journal.directory)
        let linkedParent = NativeEnrollmentIntentJournal(directory: alias)
        XCTAssertThrowsError(try linkedParent.load()) { XCTAssertEqual(($0 as? NativeEnrollmentIntentFailure)?.reason, .unsafePath) }
        XCTAssertThrowsError(try linkedParent.saveOriginal(original)) { XCTAssertEqual(($0 as? NativeEnrollmentIntentFailure)?.reason, .unsafePath) }
        XCTAssertEqual(try journal.load(), original)
        let source = journal.directory.appendingPathComponent("preserved.json")
        try FileManager.default.moveItem(at: file, to: source)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        XCTAssertThrowsError(try journal.load()) { XCTAssertEqual(($0 as? NativeEnrollmentIntentFailure)?.reason, .unsafePath) }
        XCTAssertThrowsError(try journal.saveOriginal(original)) { XCTAssertEqual(($0 as? NativeEnrollmentIntentFailure)?.reason, .unsafePath) }
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(link(source.path, file.path), 0)
        XCTAssertThrowsError(try journal.load()) { XCTAssertEqual(($0 as? NativeEnrollmentIntentFailure)?.reason, .linkedFile) }
        XCTAssertThrowsError(try journal.saveOriginal(original)) { XCTAssertEqual(($0 as? NativeEnrollmentIntentFailure)?.reason, .linkedFile) }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testPendingOriginalAdmissionRequiresEveryImmutableIDAndOnlyCompletedSuccessor() throws {
        let pending = try journalRecord()
        try NativeEnrollmentActionInput.requireSameOriginal(pending, pending: pending)
        var completed = pending; completed.restoreRecordedInstallation = true
        try NativeEnrollmentActionInput.requireSameOriginal(completed, pending: pending)
        let replacement = try NativeEnrollmentIntentRecord(accountID: pending.accountID, locationID: pending.locationID,
            name: pending.name, profile: pending.profile, origin: URL(string: pending.origin)!,
            viewport: CGSize(width: pending.width, height: pending.height))
        XCTAssertThrowsError(try NativeEnrollmentActionInput.requireSameOriginal(replacement, pending: pending)) {
            XCTAssertEqual($0 as? NativeEnrollmentIntentFailure, .init(.changedOriginal, retention: .retained))
        }
        for key in ["requestID", "cloudRootID", "packageRootID", "firstDeliveryNativeOperationID", "legacyOperationID"] {
            var bits = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
            bits[key] = UUID().uuidString
            let changed = try JSONDecoder().decode(NativeEnrollmentIntentRecord.self, from: JSONSerialization.data(withJSONObject: bits))
            XCTAssertThrowsError(try NativeEnrollmentActionInput.requireSameOriginal(changed, pending: pending), key)
        }
        XCTAssertThrowsError(try NativeEnrollmentActionInput.requireSameOriginal(pending, pending: completed))
    }
    @MainActor func testOriginalJournalFailureCategoriesAndRetentionAreHonestAndSanitized() throws {
        let parent = try physicalApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let original = try journalRecord()
        // A retired write generation with proven absent original cannot publish.
        try journal.freezeWritesForReset {}
        XCTAssertThrowsError(try journal.saveOriginal(original)) {
            XCTAssertEqual($0 as? NativeEnrollmentIntentFailure, .init(.retired, retention: .notSaved))
        }
        XCTAssertNil(try journal.load())
        let active = NativeEnrollmentIntentJournal(directory: journal.directory)
        try active.saveOriginal(original)
        try Data("private-corrupt-record".utf8).write(to: active.directory.appendingPathComponent("original.json"))
        XCTAssertThrowsError(try active.load()) {
            XCTAssertEqual($0 as? NativeEnrollmentIntentFailure, .init(.invalidRecord))
        }
        let controller = NativeEnrollmentSceneController(intentJournal: active)
        XCTAssertEqual(controller.state, .needsAttention)
        XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .originalRequest)
        XCTAssertEqual(controller.enrollmentDiagnostic?.category, .journalRecord)
        XCTAssertTrue(controller.deliveryMessage?.contains(NativeEnrollmentRequestRetention.uncertain.guidance) == true)
        XCTAssertFalse(controller.deliveryMessage?.contains("private-corrupt-record") == true)
        for (reason, category) in [(NativeEnrollmentIntentFailure.Reason.unsafePath, NativeEnrollmentFailureDiagnostic.Category.journalPath),
                                  (.linkedFile, .journalPath), (.readUnavailable, .journalRead), (.publication, .journalWrite)] {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .originalRequest, error: NativeEnrollmentIntentFailure(reason, retention: .notSaved))
            XCTAssertEqual(diagnostic.category, category)
            let message = diagnostic.message(installationEnrolled: false, originalRetention: .notSaved)
            XCTAssertTrue(message.contains(NativeEnrollmentRequestRetention.notSaved.guidance))
            XCTAssertFalse(message.contains(NativeEnrollmentRequestRetention.retained.guidance))
        }
        let cancelled = NativeEnrollmentFailureDiagnostic(stage: .originalRequest, error: CancellationError())
        XCTAssertEqual(cancelled.category, .cancelled)
    }
    private func journalRecord() throws -> NativeEnrollmentIntentRecord {
        try .init(accountID: UUID(), locationID: nil, name: "Office iPad", profile: "iPad",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 1024, height: 1366))
    }
    private func physicalApplicationSupportFixture() throws -> URL {
        // The real OS Application Support anchor, physically spelled by POSIX,
        // exercises production traversal without inventing a container alias.
        let requested = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(requested.path, nil))
        defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("enrollment-journal-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent
    }
    @MainActor func testUnfinishedEnrollmentStateNeverCompetesWithResetOrCompletedRecovery() throws {
        let parent = try physicalApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let dormant = NativeEnrollmentSceneController(intentJournal: journal)
        XCTAssertFalse(dormant.hasUnfinishedCloudEnrollment)
        let original = try journalRecord(); try journal.saveOriginal(original)
        let saved = NativeEnrollmentSceneController(intentJournal: journal)
        XCTAssertTrue(saved.hasUnfinishedCloudEnrollment)
        let resetting = NativeEnrollmentSceneController(testIntentJournal: journal, factoryResetInProgress: true)
        XCTAssertFalse(resetting.hasUnfinishedCloudEnrollment)
        let retiring = NativeEnrollmentSceneController(testIntentJournal: journal, intentRetirementPending: true)
        XCTAssertFalse(retiring.hasUnfinishedCloudEnrollment)
        XCTAssertNotNil(retiring.factoryResetRecoveryMessage)
        XCTAssertEqual(try journal.load(), original)
        try journal.markRecordedInstallation(original)
        let completed = NativeEnrollmentSceneController(intentJournal: journal)
        XCTAssertFalse(completed.hasUnfinishedCloudEnrollment)
        XCTAssertEqual(try journal.load()?.requestID, original.requestID)
    }
    @MainActor func testDormantControllerDoesNotConstructAnEnrollment() {
        let controller = NativeEnrollmentSceneController()
        XCTAssertEqual(controller.state, .idle)
        controller.didEnterBackground()
        XCTAssertEqual(controller.state, .idle)
    }
    @MainActor func testMissingHumanSelectionFailsBeforeProductionConfigurationOrOwnerEffects() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let bootstrap = DeviceManagementBootstrap() // No start/task; deferred production owner is not constructed.
        let controller = NativeEnrollmentSceneController()
        controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: UUID(), locationID: UUID(), name: "Fixture", viewport: CGSize(width: 390, height: 844))
        XCTAssertEqual(controller.state, .needsAttention)
        XCTAssertNil(bootstrap.currentAuthority)
    }
    func testProductionProtectionKeepsLocalTreeAndPassesRealProvisioningGuard() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let namespace = parent.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
        let state = parent.appendingPathComponent("xyz.screenpunk.device-state")
        let protected = NativeEnrollmentActionInput.protectedRoots(stateRoot: state,
            reset: parent.appendingPathComponent("xyz.screenpunk.local-reset"),
            journal: namespace.appendingPathComponent("enrollment"),
            management: parent.appendingPathComponent("xyz.screenpunk.management"),
            preferences: parent.appendingPathComponent("xyz.screenpunk.preferences"))
        // Exercise the real path validation and durable initialization, rather than a mock store.
        let scope = DevicePackageProtectedScope(legacyStateRoot: protected.legacyState, legacyArchiveRoot: protected.legacyArchive,
            resetRoot: protected.reset, cloudRoot: protected.cloudEnrollment, managementRoot: protected.management,
            preferencesRoot: protected.preferences, otherProtectedRoots: [])
        let invalid = DeviceLocalProvisioningIntentStore(root: namespace.appendingPathComponent("invalid-provisioning"), rootID: UUID(),
            protectedRoots: [state, state, protected.reset, protected.cloudEnrollment, protected.management, protected.preferences])
        XCTAssertThrowsError(try invalid.initializeExplicit()) { error in
            guard case DeviceLocalProvisioningIntentStore.Failure.unsafeRoot = error else { return XCTFail("Expected duplicate protected-root rejection") }
        } // The previous production wiring failed here.
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("invalid-provisioning").path))
        XCTAssertEqual(protected.legacyState, state)
        XCTAssertEqual(protected.legacyArchive, state)
        let root = namespace.appendingPathComponent("provisioning")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = DeviceLocalProvisioningIntentStore(root: root, rootID: UUID(), protectedRoots: NativeFirstManagedStores.provisioningProtection(scope))
        try store.initializeExplicit()
        try store.initializeExplicit() // Same durable scope is retryable without replacing identity.
    }
    func testRetainedOriginalMatchingUsesExactNameAndUnassignedLocation() throws {
        let origin = URL(string: "https://fixture.screenpunk.test")!
        let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Café", profile: "iPad",
            origin: origin, viewport: CGSize(width: 1024, height: 1366))
        try NativeEnrollmentActionInput.requireOriginal(intent, accountID: intent.accountID, locationID: nil, name: intent.name, origin: origin)
        XCTAssertThrowsError(try NativeEnrollmentActionInput.requireOriginal(intent, accountID: UUID(), locationID: nil, name: intent.name, origin: origin))
        XCTAssertThrowsError(try NativeEnrollmentActionInput.requireOriginal(intent, accountID: intent.accountID, locationID: UUID(), name: intent.name, origin: origin))
        XCTAssertThrowsError(try NativeEnrollmentActionInput.requireOriginal(intent, accountID: intent.accountID, locationID: nil, name: "Cafe\u{301}", origin: origin))
        XCTAssertThrowsError(try NativeEnrollmentActionInput.requireOriginal(intent, accountID: intent.accountID, locationID: nil, name: intent.name, origin: URL(string: "https://other.invalid")!))
    }
    func testViewportRejectsNonFiniteAndDimensionsThatRoundToZeroBeforeIntegerConversion() throws {
        for viewport in [CGSize(width: CGFloat.nan, height: 844), CGSize(width: CGFloat.infinity, height: 844),
                         CGSize(width: 0.1, height: 844), CGSize(width: 390, height: 0), CGSize(width: 16385, height: 844)] {
            XCTAssertThrowsError(try NativeEnrollmentActionInput.validateViewport(viewport))
        }
        try NativeEnrollmentActionInput.validateViewport(CGSize(width: 1024, height: 1366))
    }
    @MainActor func testRepeatedEarlyFailureRetainsOriginalAndReportsSanitizedAuthorizationStage() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Office iPad", profile: "iPad",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 1024, height: 1366))
        try journal.saveOriginal(intent)
        let controller = NativeEnrollmentSceneController(intentJournal: journal)
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()), bootstrap = DeviceManagementBootstrap()
        for _ in 0..<2 {
            controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: intent.accountID, locationID: nil,
                name: intent.name, viewport: CGSize(width: 1024, height: 1366))
            XCTAssertEqual(controller.state, .needsAttention)
            XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .selection)
            XCTAssertEqual(controller.enrollmentDiagnostic?.category, .authorization)
            XCTAssertNil(controller.enrollmentProgressMessage)
            XCTAssertTrue(controller.deliveryMessage?.contains("Check sign-in") == true)
            XCTAssertFalse(controller.deliveryMessage?.contains("selection/authorization") == true)
            XCTAssertEqual(try journal.load(), intent)
            XCTAssertEqual(controller.retainedAccountID, intent.accountID)
            XCTAssertNil(controller.retainedLocationID)
        }
    }
    func testDiagnosticNeverExposesUnderlyingPrivateMessageAndDistinguishesEnrolledDelivery() {
        let secret = "private-token-and-filesystem-root"
        let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .screenDelivery,
            error: NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]))
        XCTAssertFalse(diagnostic.message(installationEnrolled: true).contains(secret))
        XCTAssertTrue(diagnostic.message(installationEnrolled: true).contains("This device is enrolled"))
        XCTAssertFalse(diagnostic.message(installationEnrolled: false).contains("This device is enrolled"))
        for stage in NativeEnrollmentFailureDiagnostic.Stage.allCases { XCTAssertFalse(stage.progressMessage.isEmpty) }
    }
    func testCredentialSessionDiagnosticDistinguishesNativeNamespaceAndAuthorityFailures() {
        let failures: [(Error, NativeEnrollmentFailureDiagnostic.Category)] = [
            (DeviceNativeManagedRootFailure.invalidLocator, .namespacePath),
            (DeviceNativeManagedRootFailure.unavailable(EPERM), .namespaceAccess),
            (DeviceNativeManagedRootFailure.unavailable(EACCES), .namespaceAccess),
            (DeviceNativeManagedRootFailure.unavailable(EIO), .namespaceRead),
            (DeviceNativeManagedRootFailure.changedAnchor, .namespaceChanged),
            (DeviceNativeManagedRootFailure.changedNamespace, .namespaceChanged),
            (DeviceManagementAuthority.Failure.staleLease, .authorityExpired),
            (DeviceManagementAuthority.Failure.reentrantOperation, .busy),
            (DeviceManagementAuthority.Failure.resetConflict, .resetConflict)
        ]
        for (error, expected) in failures {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .credentialSession, error: error)
            XCTAssertEqual(diagnostic.stage, .credentialSession)
            XCTAssertEqual(diagnostic.category, expected)
            let message = diagnostic.message(installationEnrolled: false, originalRetention: .retained)
            XCTAssertFalse(message.contains("unlock"))
            XCTAssertFalse(message.contains("OSStatus"))
            XCTAssertFalse(message.contains("/private/"))
            if expected == .namespacePath || expected == .namespaceAccess || expected == .namespaceRead || expected == .namespaceChanged {
                XCTAssertTrue(message.contains(NativeEnrollmentRequestRetention.retained.guidance))
                XCTAssertFalse(message.contains("credentialSession/" + expected.rawValue))
            }
        }
        let cancelled = NativeEnrollmentFailureDiagnostic(stage: .credentialSession, error: CancellationError())
        XCTAssertEqual(cancelled.category, .cancelled)
    }
    func testEnrollmentFailureIdentifiesExactNativeLocalTypeWithoutPrivateAssociatedValues() {
        let failures: [(Error, String)] = [
            (DevicePackagePreparationError.unsafeBinding, "packageStore/unsafeBinding"),
            (DeviceNativeGrantPreparationError.scopeOverlap, "grantStore/scopeOverlap"),
            (DeviceStructuralStoreError.io(1234567), "structuralStore/io"),
            (DeviceLocalProvisioningIntentStore.Failure.uncertain, "provisioningStore/outcomeUncertain"),
            (NativeEnrollmentJournalError.unsafeRoot, "nativeJournal/unsafeRoot"),
            (NativeEnrollmentPromotionError.blocked, "nativePromotion/blocked")
        ]
        for (error, detail) in failures {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .enrollment, error: error)
            XCTAssertEqual(diagnostic.category, .nativeStore)
            XCTAssertEqual(diagnostic.detail, detail)
            let message = diagnostic.message(installationEnrolled: false, originalRetention: .retained)
            XCTAssertNotNil(diagnostic.localDiagnostic)
            XCTAssertNil(diagnostic.credentialDiagnostic)
            XCTAssertFalse(message.contains("enrollment/nativeStore/" + detail))
            XCTAssertFalse(message.contains(detail))
            XCTAssertTrue(message.contains(NativeEnrollmentRequestRetention.retained.guidance))
            XCTAssertFalse(message.contains("1234567"))
            XCTAssertFalse(message.contains("/private/"))
        }
        let native = NativeEnrollmentFailureDiagnostic(stage: .enrollment,
            error: NativeEnrollmentKeychainBackend.Failure.inaccessible(errSecMissingEntitlement))
        XCTAssertEqual(native.category, .nativeCredential)
        XCTAssertEqual(native.detail, "nativeEnrollmentCredential/entitlement")
        XCTAssertEqual(native.credentialDiagnostic?.reason, .entitlement)
        XCTAssertNil(native.localDiagnostic)
        XCTAssertFalse(native.message(installationEnrolled: false).contains("nativeEnrollmentCredential"))
        let grant = NativeEnrollmentFailureDiagnostic(stage: .enrollment,
            error: DeviceGrantCredentialTransportFailure.inaccessible(errSecParam))
        XCTAssertEqual(grant.category, .grantCredential)
        XCTAssertEqual(grant.detail, "grantCredential/invalidParameter")
        XCTAssertFalse(grant.message(installationEnrolled: false).contains(String(errSecParam)))
        let unknown = NativeEnrollmentFailureDiagnostic(stage: .enrollment,
            error: NSError(domain: "private-credential-or-path", code: 1234567))
        XCTAssertNil(unknown.detail)
        XCTAssertFalse(unknown.message(installationEnrolled: false).contains("private-credential-or-path"))
    }
    func testCloudPackageRejectionDoesNotRecommendReconnectingOrResetting() {
        let unsupported = NativeEnrollmentFailureDiagnostic(stage: .screenDelivery,
            error: NativeDeliveryExecutionError.unsupportedCapabilities)
        let message = unsupported.message(installationEnrolled: true, originalRetention: .retained)
        XCTAssertTrue(message.contains("Cloud delivery"))
        XCTAssertTrue(message.contains("new deployment"))
        XCTAssertFalse(message.contains("Tap Retry connection"))
        XCTAssertFalse(message.contains("storage needs attention"))
        let mismatch = NativeEnrollmentFailureDiagnostic(stage: .screenDelivery,
            error: DevicePackageQualificationError.targetMismatch)
        XCTAssertEqual(mismatch.detail, "packageCompatibility/targetMismatch")
        XCTAssertTrue(mismatch.message(installationEnrolled: true).contains("device profile"))
    }
    func testCustomerFailureCopyUsesExistingRetryActionAndTruthfulSaveStatus() {
        let failures: [Error] = [
            NSError(domain: "unknown-private-error", code: 1),
            NativeEnrollmentIntentFailure(.unsafePath),
            DeviceNativeManagedRootFailure.unavailable(EPERM),
            NativeEnrollmentJournalError.unsafeRoot,
            NativeEnrollmentKeychainBackend.Failure.inaccessible(errSecMissingEntitlement),
            DeviceGrantCredentialTransportFailure.inaccessible(errSecParam)
        ]
        for error in failures {
            let diagnostic = NativeEnrollmentFailureDiagnostic(stage: .enrollment, error: error)
            let saved = diagnostic.message(installationEnrolled: false, originalRetention: .retained)
            XCTAssertTrue(saved.contains("Your setup is saved."))
            XCTAssertTrue(saved.contains("Tap Retry connection"))
            XCTAssertFalse(saved.contains("device checks"))
            XCTAssertFalse(saved.contains("enrollment/"))
            let absent = diagnostic.message(installationEnrolled: false, originalRetention: .notSaved)
            XCTAssertTrue(absent.contains("has not been saved yet"))
            XCTAssertFalse(absent.contains("Your setup is saved."))
            let uncertain = diagnostic.message(installationEnrolled: false, originalRetention: .uncertain)
            XCTAssertTrue(uncertain.contains("whether your setup was saved"))
            XCTAssertFalse(uncertain.contains("Your setup is saved."))
            XCTAssertFalse(uncertain.contains("has not been saved yet"))
        }
        let reset = NativeEnrollmentFailureDiagnostic(stage: .enrollment, error: DeviceManagementAuthority.Failure.resetConflict)
            .message(installationEnrolled: false)
        XCTAssertTrue(reset.contains("Reopen Cloud account"))
        XCTAssertTrue(reset.contains("Retry connection"))
        XCTAssertFalse(reset.contains("device checks"))
    }
    @MainActor func testBusyEnrollmentGuardPublishesProgressAndKeepsSuspendedOriginalWork() async throws {
        for kind in NativeEnrollmentSceneController.WorkKind.allCases {
            let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
            let intent = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Office iPad", profile: "iPad",
                origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 1024, height: 1366))
            try journal.saveOriginal(intent)
            let bytes = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
            let gate = EnrollmentGuardTaskGate()
            let pending = Task<Void, Never> { await gate.wait() }
            let controller = NativeEnrollmentSceneController(testIntentJournal: journal, pendingTask: pending, workKind: kind)
            let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()), bootstrap = DeviceManagementBootstrap()
            for _ in 0..<2 {
                controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: intent.accountID, locationID: nil,
                    name: intent.name, viewport: CGSize(width: 1024, height: 1366))
                XCTAssertEqual(controller.state, .enrolling)
                XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .action)
                XCTAssertEqual(controller.enrollmentDiagnostic?.category, .busy)
                XCTAssertEqual(controller.enrollmentProgressMessage, kind.waitingMessage)
                XCTAssertFalse(pending.isCancelled)
                XCTAssertNil(bootstrap.currentAuthority)
                XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), bytes)
                XCTAssertEqual(try journal.load(), intent)
            }
            await gate.release(); await pending.value
        }
    }
    @MainActor func testResetAndRetirementEnrollmentGuardsPublishRecoveryWithoutOwnerOrJournalEffects() throws {
        for retirementPending in [false, true] {
            let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
            let controller = NativeEnrollmentSceneController(testIntentJournal: journal,
                factoryResetInProgress: !retirementPending, intentRetirementPending: retirementPending)
            let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()), bootstrap = DeviceManagementBootstrap()
            controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: UUID(), locationID: nil,
                name: "Office iPad", viewport: CGSize(width: 1024, height: 1366))
            XCTAssertEqual(controller.state, .needsAttention)
            XCTAssertEqual(controller.enrollmentDiagnostic?.stage, .action)
            XCTAssertEqual(controller.enrollmentDiagnostic?.category, retirementPending ? .retirementPending : .resetInProgress)
            XCTAssertNil(controller.enrollmentProgressMessage)
            XCTAssertTrue(controller.deliveryMessage?.contains(retirementPending ? "Recover reset" : "still running") == true)
            XCTAssertNil(bootstrap.currentAuthority)
            XCTAssertNil(try journal.load())
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory.path))
        }
    }
    @MainActor func testIncompleteStartupPreservesRootsForExplicitAuthorizedRetainedRecovery() async throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { return XCTFail("Physical fixture anchor unavailable") }
        let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent(UUID().uuidString)
        free(physical)
        let anchor = parent.appendingPathComponent("Application Support")
        let namespace = anchor.appendingPathComponent(DeviceNativeManagedRootLocator.namespaceName)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for name in DeviceNativeManagedRootLocator.futureChildNames + ["enrollment"] {
            try FileManager.default.createDirectory(at: namespace.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let journal = NativeEnrollmentIntentJournal(directory: anchor.appendingPathComponent("intent"))
        let origin = URL(string: "https://fixture.screenpunk.test")!
        let intent = try NativeEnrollmentIntentRecord(accountID: NativeRecoveryHumanTransport.accountID, locationID: nil,
            name: "Office iPad", profile: "iPad", origin: origin, viewport: CGSize(width: 1024, height: 1366))
        try journal.saveOriginal(intent)
        let originalBytes = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
        let authority = DeviceManagementAuthority(journal: NativeRecoveryManagementJournal(),
            credentials: .init(backend: NativeRecoveryLegacyCredentials(), random: { throw NativeRecoveryFixtureFailure.unexpectedEffect }),
            reset: NativeRecoveryResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent))
        try authority.prepareProductionSupportAnchor()
        let bootstrap = DeviceManagementBootstrap(authority: authority, retained: { .empty },
            hostFactory: { _ in throw NativeRecoveryFixtureFailure.unexpectedEffect })
        let controller = NativeEnrollmentSceneController(intentJournal: journal)
        controller.reconnectInstallation(bootstrap: bootstrap) // Actual startup entry point, called twice by scene callbacks.
        controller.reconnectInstallation(bootstrap: bootstrap)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.enrollmentDiagnostic)
        XCTAssertFalse(try XCTUnwrap(journal.load()).restoreRecordedInstallation)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: namespace.appendingPathComponent("enrollment").path).isEmpty)

        // Obtain genuine selected account/Unassigned authorization via the lifecycle,
        // not a fabricated selection. Network responses and credentials are isolated.
        let coordinator = CloudConnectionCoordinator(authenticate: { _ in NativeRecoveryHumanTokens() }, cancelIdentityFlow: {}, signOutIdentity: {},
            makeClient: { try CloudNativeClient(baseURL: origin, tokenProvider: $0, transport: NativeRecoveryHumanTransport()) },
            journal: NativeRecoveryWorkspaceJournal())
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        try lifecycle.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in false },
            testEnrollmentTokens: { NativeRecoveryHumanTokens() }))
        await coordinator.signIn(provider: .google)?.value
        await coordinator.discoverLocations(accountID: intent.accountID)?.value
        let selection = try lifecycle.enrollmentSelection(accountID: intent.accountID, locationID: nil)
        try selection.validate()
        try NativeEnrollmentActionInput.requireOriginal(intent, accountID: selection.accountID, locationID: selection.locationID,
            name: intent.name, origin: origin)
        let proposal = try intent.proposal()
        try authority.enterCloudForeground()
        // This exact call failed before the marker guard: startup had already
        // consumed the same-generation roots reservation with restoreCompleted.
        let roots = try authority.restoreRecordedCloudEnrollmentRoots(claim: proposal.claimInput,
            cloudRootID: intent.cloudRootID, localIDs: intent.localIDs())
        try authority.validateFreshCloudEnrollmentRoots(roots)
        let protected = NativeEnrollmentActionInput.protectedRoots(stateRoot: parent.appendingPathComponent("local"),
            reset: parent.appendingPathComponent("reset"), journal: roots.journalRoot,
            management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
            grantTransport: NativeRecoveryGrantTransport(rootID: roots.localIDs.grant))
        let storage = NativeRecoveryStopStorage()
        let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal,
            excludedLocalResetRoot: protected.reset, storage: storage)
        do {
            _ = try await session.resumeRetainedOriginal(origin: origin, tokenProvider: selection.tokens,
                activationRequestID: intent.activationRequestID, associationAttemptID: intent.associationAttemptID, stores: stores)
            XCTFail("Synthetic recovery must stop before secret generation, Add or cloud IO")
        } catch { XCTAssertEqual(error as? NativeRecoveryFixtureFailure, .recoveryReached) }
        XCTAssertEqual(storage.generations, 1, "Real retained recovery reached original secret preparation under the same owner")
        XCTAssertEqual(storage.adds, 0)
        let enrollmentJournal = NativeEnrollmentJournalStore(root: roots.journalRoot, cloudRootID: intent.cloudRootID,
            excludedLocalResetRoot: protected.reset)
        var retainedClaims: [NativeClaimInput] = []
        try enrollmentJournal.diagnose { retainedClaims.append($0.step.proposal.claimInput) }
        XCTAssertEqual(retainedClaims, [proposal.claimInput])
        XCTAssertEqual(try journal.load(), intent)
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), originalBytes)
    }
    @MainActor func testBackgroundRecoveryDrainsOriginalTaskAndReauthorizesSameRequestBeforeRootQualification() async throws {
        for namespacePresent in [false, true] {
            guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { return XCTFail("Physical fixture unavailable") }
            let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent(UUID().uuidString)
            free(physical)
            let anchor = parent.appendingPathComponent("Application Support")
            try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let origin = URL(string: "https://fixture.screenpunk.test")!
            let recorded = try NativeEnrollmentIntentRecord(accountID: NativeRecoveryHumanTransport.accountID, locationID: nil,
                name: "Office iPad", profile: "iPad", origin: origin, viewport: CGSize(width: 1024, height: 1366))
            // Earlier schema may have no persisted first-delivery identifiers.
            // Their retained in-process fallbacks must survive foreground renewal.
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recorded)) as? [String: Any])
            for key in ["firstDeliveryNativeOperationID", "firstDeliveryGrantOperationID", "firstDeliveryGrantRevisionID", "firstDeliveryActivationRequestID"] { object.removeValue(forKey: key) }
            let intent = try JSONDecoder().decode(NativeEnrollmentIntentRecord.self, from: JSONSerialization.data(withJSONObject: object))
            let journal = NativeEnrollmentIntentJournal(directory: anchor.appendingPathComponent("intent"))
            try journal.saveOriginal(intent)
            let bytes = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
            let authority = DeviceManagementAuthority(journal: NativeRecoveryManagementJournal(),
                credentials: .init(backend: NativeRecoveryLegacyCredentials(), random: { throw NativeRecoveryFixtureFailure.unexpectedEffect }),
                reset: NativeRecoveryResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
                supportAnchorSetup: try .fixture(existingPhysicalParent: parent))
            try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
            let proposal = try intent.proposal()
            let priorRoots: DeviceManagementAuthority.FreshCloudEnrollmentRoots?
            if namespacePresent {
                priorRoots = try authority.prepareFreshCloudEnrollmentRoots(claim: proposal.claimInput,
                    recordedCloudRootID: intent.cloudRootID, recordedLocalIDs: intent.localIDs())
            } else { priorRoots = nil }
            let bootstrap = DeviceManagementBootstrap(authority: authority, retained: { .empty },
                hostFactory: { _ in throw NativeRecoveryFixtureFailure.unexpectedEffect })
            let transport = NativeRecoveryHumanTransport()
            let coordinator = CloudConnectionCoordinator(authenticate: { _ in NativeRecoveryHumanTokens() }, cancelIdentityFlow: {}, signOutIdentity: {},
                makeClient: { try CloudNativeClient(baseURL: origin, tokenProvider: $0, transport: transport) }, journal: NativeRecoveryWorkspaceJournal())
            let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
            var selections = 0
            try lifecycle.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in false }, testEnrollmentTokens: {
                selections += 1; return NativeRecoveryHumanTokens()
            }))
            await coordinator.signIn(provider: .google)?.value
            await coordinator.discoverLocations(accountID: intent.accountID)?.value
            let staleSelection = try lifecycle.enrollmentSelection(accountID: intent.accountID, locationID: nil)
            let gate = EnrollmentGuardTaskGate(), draining = Task<Void, Never> { await gate.wait() }
            do {
            let controller = try NativeEnrollmentSceneController(testRetainedIntentJournal: journal, lifecycle: lifecycle,
                authority: authority, roots: priorRoots, drainingTask: draining)
            let deliveryIDs = try XCTUnwrap(controller.retainedDeliveryIdentifiersForTesting)
            let priorSelections = selections
            lifecycle.didEnterBackground() // Real revocation observer marks controller and cancels its original driver.
            XCTAssertTrue(controller.retainedForegroundRecoveryPending)
            if let priorRoots { XCTAssertThrowsError(try authority.validateFreshCloudEnrollmentRoots(priorRoots)) }
            await coordinator.signIn(provider: .google)?.value
            await coordinator.discoverLocations(accountID: intent.accountID)?.value
            XCTAssertThrowsError(try staleSelection.validate())
            controller.enroll(lifecycle: lifecycle, bootstrap: bootstrap, accountID: intent.accountID, locationID: nil,
                name: intent.name, viewport: CGSize(width: 1024, height: 1366))
            XCTAssertEqual(controller.enrollmentDiagnostic?.category, .busy)
            XCTAssertTrue(controller.retainedForegroundRecoveryPending)
            XCTAssertEqual(selections, priorSelections, "No new scope is admitted before the cancelled driver drains")
            await gate.release(); await draining.value
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while controller.hasActiveEnrollmentWork && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
            XCTAssertFalse(controller.hasActiveEnrollmentWork)
            XCTAssertThrowsError(try controller.reauthorizeRetainedForegroundEnrollment(lifecycle: lifecycle, bootstrap: bootstrap,
                accountID: UUID(), locationID: nil, name: intent.name))
            XCTAssertTrue(controller.retainedForegroundRecoveryPending)
            XCTAssertEqual(selections, priorSelections)
            XCTAssertTrue(try controller.reauthorizeRetainedForegroundEnrollment(lifecycle: lifecycle, bootstrap: bootstrap,
                accountID: intent.accountID, locationID: nil, name: intent.name))
            XCTAssertFalse(controller.retainedForegroundRecoveryPending)
            XCTAssertEqual(selections, priorSelections + 1)
            XCTAssertEqual(controller.retainedDeliveryIdentifiersForTesting, deliveryIDs)
            XCTAssertEqual(try journal.load(), intent)
            XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), bytes)
            // Exactly absent namespaces use the existing fresh fences; recorded
            // namespaces requalify old nodes. Both retain the original durable IDs.
            try authority.enterCloudForeground()
            let restore = NativeEnrollmentActionInput.requiresRecordedRoots(installationRecorded: intent.restoreRecordedInstallation,
                namespacePresent: namespacePresent)
            XCTAssertEqual(restore, namespacePresent)
            let roots = try restore
                ? authority.restoreRecordedCloudEnrollmentRoots(claim: proposal.claimInput, cloudRootID: intent.cloudRootID, localIDs: intent.localIDs())
                : authority.prepareFreshCloudEnrollmentRoots(claim: proposal.claimInput, recordedCloudRootID: intent.cloudRootID, recordedLocalIDs: intent.localIDs())
            try authority.validateFreshCloudEnrollmentRoots(roots)
            XCTAssertEqual(roots.cloudRootID, intent.cloudRootID)
            XCTAssertEqual(roots.localIDs.package, intent.packageRootID)
            XCTAssertEqual(roots.localIDs.grant, intent.grantRootID)
            XCTAssertEqual(roots.localIDs.structural, intent.structuralRootID)
            XCTAssertEqual(roots.localIDs.provisioning, intent.provisioningRootID)
            XCTAssertEqual(roots.localIDs.contentGenesis, intent.contentGenesisID)
            } catch {
                // Cleanup also covers a throwing controller constructor, unwrap
                // or qualification before the normal release above.
                await gate.release(); await draining.value
                throw error
            }
        }
        XCTAssertTrue(NativeEnrollmentActionInput.requiresRecordedRoots(installationRecorded: true, namespacePresent: false),
            "A completed marker never turns a missing recorded namespace into new enrollment")
    }
    @MainActor func testRetiredHumanSceneCannotCreateEnrollment() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        lifecycle.retirePresentationContext()
        XCTAssertThrowsError(try lifecycle.enrollmentSelection(accountID: UUID(), locationID: UUID()))
    }
}

private actor EnrollmentGuardTaskGate {
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

/// Genuine fixed Core collectors with the existing module-internal synthetic
/// URLSession configuration. Authority fences match the production transport.
private struct NativeSequenceDeliveryTransport: NativeSceneDeliveryTransport {
    let origin: URL
    let configuration: URLSessionConfiguration
    func send(_ request: NativeOperationalStatusRequest, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeOperationalStatusObservation {
        try Task.checkCancellation(); try request.requireOrigin(origin)
        try authority.beginCloudStatusRequest(context, requestID: request.requestID)
        let value = try await request.performFixedTransport(origin: origin, configuration: configuration)
        try Task.checkCancellation(); try authority.acceptCloudStatus(value, context: context); return value
    }
    func reportState(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryStateHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let value = try await NativeDeliveryStateHTTPObservation.collect(body: body, installation: installation, current: current, origin: origin, configuration: configuration)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return value
    }
    func command(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryCommandHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let value = try await NativeDeliveryCommandHTTPObservation.collect(installation: installation, current: current, origin: origin, configuration: configuration)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return value
    }
    func preparing(_ command: NativeDeliveryCommandHTTPObservation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws {
        try authority.validateCloudRequestStart(context)
        try await command.reportPreparing(current: current, origin: origin, configuration: configuration)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context)
    }
    func plan(_ command: NativeDeliveryCommandHTTPObservation, nativeOperationID: UUID, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryPlanHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let value = try await command.fetchPlan(current: current, origin: origin, nativeOperationID: nativeOperationID, configuration: configuration)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return value
    }
    func archives(_ plan: NativeDeliveryPlanHTTPObservation, current: NativeCurrentInstallationDispatch, target: DeviceProfile, profileID: String, revisionName: String, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryArchiveHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let value = try await plan.fetchArchives(current: current, origin: origin, target: target, profileID: profileID, revisionName: revisionName, configuration: configuration)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return value
    }
    func activate(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryActivationHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let value = try await NativeDeliveryActivationHTTPObservation.collect(body: body, installation: installation, current: current, origin: origin, configuration: configuration)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return value
    }
    func receipt(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation) async throws -> NativeDeliveryReceiptHTTPObservation {
        try await NativeDeliveryReceiptHTTPObservation.collect(body: body, installation: installation, origin: origin, configuration: configuration)
    }
    func superseded(_ progress: NativeUnifiedCommandProgress, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func failed(_ failure: NativeUnifiedCommandMountFailure, code: NativeUnifiedMountFailureCode, installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}

private enum NativeRecoveryFixtureFailure: Error, Equatable { case unexpectedEffect, recoveryReached }
private final class NativeRecoveryManagementJournal: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ history: DeviceManagementTransitionHistory) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}
private struct NativeRecoveryLegacyCredentials: CloudInstallationCredentialBackend {
    func read(reference: String) throws -> Data? { nil }
    func references() throws -> Set<String> { [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}
private final class NativeColdDetachedResetEvidence: DeviceLocalResetEvidence {
    let scopeDigest = String(repeating: "a", count: 64)
    var record: DeviceLocalResetRecord?
    func load() throws -> DeviceLocalResetRecord? { record }
    func save(_ record: DeviceLocalResetRecord) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}
private struct NativeRecoveryResetEvidence: DeviceLocalResetEvidence {
    let scopeDigest = String(repeating: "a", count: 64)
    func load() throws -> DeviceLocalResetRecord? { nil }
    func save(_ record: DeviceLocalResetRecord) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}
private struct NativeRecoveryGrantTransport: DeviceGrantCredentialTransport {
    let rootID: UUID
    func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {}
    func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? { nil }
    func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}
private final class NativeRecoveryStopStorage: NativeEnrollmentCredentialStorage {
    private(set) var generations = 0, adds = 0
    func enumerateBounded(maximum: Int) throws -> [NativeEnrollmentStoredCredential] { [] }
    func generateOriginal48() throws -> Data { generations += 1; throw NativeRecoveryFixtureFailure.recoveryReached }
    func readExactPersistentReference(_ reference: Data) throws -> NativeEnrollmentStoredCredential? { throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func insertStageOnly(account: Data, envelope: Data) throws -> NativeEnrollmentCredentialInsert { adds += 1; throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func insertFinalOnly(account: Data, original48: Data) throws -> NativeEnrollmentCredentialInsert { adds += 1; throw NativeRecoveryFixtureFailure.unexpectedEffect }
}
private struct NativeRecoveryHumanTokens: CloudNativeTokenProvider {
    func idToken() async throws -> String { "synthetic-human-token" }
}
private actor NativeRecoveryHumanTransport: HTTPTransport {
    static let accountID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var signIns = 0
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        switch request.url.path {
        case "/v1/native/sign-in":
            signIns += 1
            let body = #"{"user":{"id":"22222222-2222-4222-8222-222222222222","displayName":"Fixture person","email":null},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#
                .replacingOccurrences(of: "16:00:00Z", with: signIns == 1 ? "16:00:00Z" : "16:00:01Z")
            return .init(status: 200, body: Data(body.utf8))
        case "/v1/native/accounts":
            return .init(status: 200, body: Data(#"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Fixture workspace","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"owner":true,"administrator":true,"canEnroll":true}}],"nextCursor":null}"#.utf8))
        case "/v1/native/accounts/11111111-1111-4111-8111-111111111111/locations":
            return .init(status: 200, body: Data(#"{"items":[],"nextCursor":null}"#.utf8))
        default: throw NativeRecoveryFixtureFailure.unexpectedEffect
        }
    }
}
@MainActor private final class NativeRecoveryWorkspaceJournal: CloudWorkspaceSetupJournal {
    func load() throws -> CloudWorkspaceSetupJournalRecord? { nil }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws { throw NativeRecoveryFixtureFailure.unexpectedEffect }
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord { throw NativeRecoveryFixtureFailure.unexpectedEffect }
}

@MainActor private final class EnrollmentPresenceClock {
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func tick() { let pending = continuation; continuation = nil; pending?.resume() }
    func cancel() { let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError()) }
    func untilWaiting() async {
        for _ in 0..<1000 { if continuation != nil { return }; await Task.yield() }
        XCTFail("Presence clock did not reach its next bounded wait")
    }
}

/// The original UI sheet is still fresh while the real native protocol has
/// prepared its first common inventory. Its Connect callback runs the production
/// completion tail, and the later Root callback runs real mount reporting.
@MainActor private final class NativeProductionMountCallbacks {
    private var coordinator: DashboardWebCoordinator!
    private(set) var mounts = 0, failures = 0
    private(set) var failureCodes: [String] = []
    init(controller: NativeEnrollmentSceneController, content: DeviceManagedStaticContent, lifetime: DeviceRuntimeLifetime) {
        coordinator = DashboardWebCoordinator(managedStatic: content, lifetime: lifetime, serviceMounted: { [weak self] in
            try await controller.reportMountedContent(expectedContent: content, expectedLifetime: lifetime)
            self?.mounts += 1
        }, serviceMountFailed: { [weak self] code in
            await controller.reportMountFailed(expectedContent: content, expectedLifetime: lifetime, code: code)
            self?.failureCodes.append(code); self?.failures += 1
        })
    }
    // Exercise the actual coordinator callbacks with genuine package content.
    // WK navigation is the unit boundary; physical rendering remains separately qualified.
    func finish() { coordinator.webView(WKWebView(), didFinish: nil) }
    func failNavigation() {
        coordinator.webView(WKWebView(), didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
    }
    func close() { coordinator.retireForReset() }
}

@MainActor struct NativePreparedConnectionFixture {
    let controller: NativeEnrollmentSceneController
    let bootstrap: DeviceManagementBootstrap
    let unified: DeviceUnifiedInventorySession
    private let execution: NativeDeliveryExecutionSession
    private let roots: DeviceManagementAuthority.FreshCloudEnrollmentRoots
    let http: FreshOwnerHTTP
    let parent: URL
    let accountID: UUID
    let name: String
    private let authority: DeviceManagementAuthority
    private let result: NativeOperationalEnrollmentResult
    private let context: DeviceManagementAuthority.CloudInstallationContext
    private let storage: FreshCredentialStorage
    private let intent: NativeEnrollmentIntentRecord
    private let protection: NativeManagedProtectedRoots
    private let local: DeviceLegacyMigrationSession?
    var realtimeActivation: NativeActivationReceipt { result.activation }
    var installation: NativeOperationalInstallation { result.installation }
    func offerCloudCommand() throws {
        let association = try unified.validatedAssociation()
        http.delivery = try AuthorityStaticDeliveryFixture.make(state: ["installationId": result.activation.installationId.uuidString.lowercased(),
            "transitionId": result.activation.transitionId.uuidString.lowercased(), "generationId": association.generationID.uuidString.lowercased()], activation: result.activation)
    }
    fileprivate func makeContendedSession(checkpoint: @escaping () throws -> Void) throws -> DeviceUnifiedInventorySession {
        let localContext = try authority.makeConcurrentLocalContext(context: context, session: unified)
        let session = DeviceUnifiedInventorySession(local: local, native: execution,
            commonRoot: parent.appendingPathComponent("Application Support/xyz.screenpunk.unified-inventory"),
            commonRootID: try XCTUnwrap(intent.commonInventoryRootID), validateOriginal: {
                try localContext.validate()
                try checkpoint()
            }, validateMutation: { try localContext.validate() })
        guard try session.restoreCompleted() else { throw CancellationError() }
        return session
    }
    func makeAutomaticDriverController(session: DeviceUnifiedInventorySession) throws -> NativeEnrollmentSceneController {
        let current = try authority.prepareCurrentInstallationDispatch(context)
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("Application Support/xyz.screenpunk.enrollment-intent"))
        return try NativeEnrollmentSceneController(testPreparedConnectionJournal: journal, bootstrap: bootstrap, authority: authority,
            roots: roots, result: result, context: context,
            native: execution, unified: session, current: current,
            sendUnified: { try await $0.performFixedTransport(configuration: http.configuration) },
            sendEmpty: { try await $0.performFixedTransport(configuration: http.configuration) },
            transportFactory: { NativeSequenceDeliveryTransport(origin: $0, configuration: http.configuration) },
            sendMounted: { try await $0.performFixedTransport(configuration: http.configuration) },
            sendCapabilities: { try await $0.performFixedTransport(configuration: http.configuration) },
            installConcurrentHost: false)
    }
    func mountFailureBytes() throws -> Data? {
        let url = parent.appendingPathComponent("Application Support/xyz.screenpunk.unified-inventory/mixed-mount-failure.json")
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func retainedCloudOutcomeBytes() throws -> Data {
        let root = parent.appendingPathComponent("Application Support/xyz.screenpunk.unified-inventory")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".mixed-http-outcome.json") })
        return try Data(contentsOf: root.appendingPathComponent(name))
    }
    func makeColdProductionController(automaticDiscovery: Bool = false) async throws -> (controller: NativeEnrollmentSceneController, bootstrap: DeviceManagementBootstrap) {
        let anchor = parent.appendingPathComponent("Application Support")
        let owner = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent),
            commandIntents: .init(root: anchor.appendingPathComponent("xyz.screenpunk.device/command-intents")), concurrentControlQualified: true)
        try owner.prepareProductionSupportAnchor(); try owner.enterCloudForeground()
        let proposal = try intent.proposal()
        let roots = try owner.restoreRecordedCloudEnrollmentRoots(claim: proposal.claimInput,
            cloudRootID: intent.cloudRootID, localIDs: intent.localIDs())
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection,
            grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let session = try owner.makeFirstEnrollmentSession(roots: roots, proposal: proposal,
            excludedLocalResetRoot: protection.reset, storage: storage)
        let restored = try session.restoreCompleted(stores: stores)
        let context = try owner.bindOperationalInstallation(installation: restored.installation, activation: restored.activation, origin: http.origin)
        let status = try owner.prepareCloudStatusRequest(context)
        try owner.beginCloudStatusRequest(context, requestID: status.requestID)
        try owner.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
        let current = try owner.prepareCurrentInstallationDispatch(context)
        let native = try restored.installation.makeDeliveryExecutionSession(current: current)
        let common = try owner.restoreUnifiedInventorySession(context: context,
            commonRootID: XCTUnwrap(intent.commonInventoryRootID), native: native)
        let bootstrap = DeviceManagementBootstrap(authority: owner, retained: { .empty },
            hostFactory: { _ in throw NativeRecoveryFixtureFailure.unexpectedEffect })
        bootstrap.useRecordedNativeCloudStartup(); bootstrap.start()
        let journal = NativeEnrollmentIntentJournal(directory: anchor.appendingPathComponent("xyz.screenpunk.enrollment-intent"))
        try journal.markRecordedInstallation(intent)
        let controller = try NativeEnrollmentSceneController(testPreparedConnectionJournal: journal, bootstrap: bootstrap, authority: owner,
            roots: roots, result: restored, context: context, native: native, unified: common, current: current,
            sendUnified: { try await $0.performFixedTransport(configuration: http.configuration) },
            sendEmpty: { try await $0.performFixedTransport(configuration: http.configuration) },
            transportFactory: { NativeSequenceDeliveryTransport(origin: $0, configuration: http.configuration) },
            sendMounted: { try await $0.performFixedTransport(configuration: http.configuration) },
            sendCapabilities: { try await $0.performFixedTransport(configuration: http.configuration) },
            installConcurrentHost: false, automaticDiscovery: automaticDiscovery)
        return (controller, bootstrap)
    }
    func commitCloudSelection(retainingLocalEntries: Bool = false) async throws -> (NativeDeliveryDurableBody, NativeCurrentInstallationDispatch) {
        let current = try authority.prepareCurrentInstallationDispatch(context)
        let association = try unified.validatedAssociation()
        let state: [String: Any] = ["installationId": result.activation.installationId.uuidString.lowercased(),
            "transitionId": result.activation.transitionId.uuidString.lowercased(),
            "generationId": association.generationID.uuidString.lowercased()]
        var delivery = try AuthorityStaticDeliveryFixture.make(state: state, activation: result.activation)
        if retainingLocalEntries {
            guard association.entries.allSatisfy({ $0.provenance == "retainedLocal" }) else { throw NativeRecoveryFixtureFailure.unexpectedEffect }
            var command = try XCTUnwrap(JSONSerialization.jsonObject(with: delivery.command) as? [String: Any])
            var resulting = try XCTUnwrap(command["resultingSet"] as? [String: Any])
            let incoming = try XCTUnwrap(resulting["entries"] as? [[String: Any]])
            let retained: [[String: Any]] = association.entries.map { entry in
                ["entryId": entry.entryID.uuidString.lowercased(), "provenance": ["kind": "retainedLocal",
                    "retainedEntryId": entry.entryID.uuidString.lowercased(), "manifestDigest": entry.manifestDigest]]
            }
            resulting["entries"] = retained + incoming
            command["resultingSet"] = resulting
            command["removeEntryIds"] = [] as [String]
            command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(
                DeviceDeliveryCandidateJSONDecoder.decodeResultingSet(JSONSerialization.data(withJSONObject: resulting)))
            delivery = .init(command: try JSONSerialization.data(withJSONObject: command), header: delivery.header,
                plan: delivery.plan, archive: delivery.archive)
        }
        http.delivery = delivery
        if retainingLocalEntries {
            // The HTTP plan collector deliberately binds Cloud-only sets. This
            // regression needs a genuine mixed-store CAS, so enter the existing
            // exact mixed pipeline with the fixture's reviewed bytes/archive.
            // Real authority acceptance, package/resource qualification, fixed
            // activation authorization and durable dispatch still run below.
            let nativeOperationID = UUID()
            _ = try unified.acceptCloudCommandExact(current: current, command: delivery.command,
                associationHeader: delivery.header, rawPlan: delivery.plan, nativeOperationID: nativeOperationID)
            try unified.prepareCloud(current: current, command: delivery.command, associationHeader: delivery.header,
                rawPlan: delivery.plan, nativeOperationID: nativeOperationID, packageRootID: UUID(),
                grantOperationID: UUID(), grantRevisionID: UUID(), archives: [delivery.archive])
        } else {
            let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: result.installation,
                current: current, origin: http.origin, configuration: http.configuration)
            let plan = try await command.fetchPlan(current: current, origin: http.origin,
                nativeOperationID: UUID(), configuration: http.configuration)
            _ = try plan.acceptUnified(session: unified, current: current)
            let archives = try await plan.fetchArchives(current: current, origin: http.origin,
                target: delivery.archive.target, profileID: "Fixture", revisionName: "Fixture", configuration: http.configuration)
            try archives.prepareUnified(session: unified, current: current, packageRootID: UUID(),
                grantOperationID: UUID(), grantRevisionID: UUID())
        }
        let request = try unified.retainCloudActivationRequest(requestID: UUID(), current: current)
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body: request,
            installation: result.installation, current: current, origin: http.origin, configuration: http.configuration)
        try unified.retainCloudAuthorization(requestBody: request, observation: authorization)
        return (try unified.dispatchCloudAndRetainActivatedOutcome(current: current), current)
    }
    func restoreCommittedCloudSelection(current: NativeCurrentInstallationDispatch) throws -> DeviceUnifiedInventorySession {
        let native = try result.installation.makeDeliveryExecutionSession(current: current)
        // This fixture reuses the installation's stores. Refresh their exact
        // genesis checkpoint before constructing another resource session.
        _ = try native.freshGenesisObservation(current: current)
        return try authority.restoreUnifiedInventorySession(context: context,
            commonRootID: XCTUnwrap(intent.commonInventoryRootID), native: native)
    }
    func fetchRealtimeSession() async throws -> NativeInstallationRealtimeSession {
        let status = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: status.requestID)
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
        let current = try authority.prepareCurrentInstallationDispatch(context)
        return try await result.installation.makeRealtimeSessionRequest(origin: http.origin, current: current).performFixedTransport(configuration: http.configuration)
    }
    func restoreAfterContainerRelocation(changedRoot: Int? = nil) async throws -> NativeInstallationRealtimeSession {
        let anchor = parent.appendingPathComponent("Application Support")
        let owner = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent),
            commandIntents: .init(root: anchor.appendingPathComponent("xyz.screenpunk.device/command-intents")), concurrentControlQualified: true)
        try owner.prepareProductionSupportAnchor(); try owner.enterCloudForeground()
        let proposal = try intent.proposal()
        let originalIDs = try intent.localIDs()
        let ids = try NativeManagedLocalRootIDs(package: changedRoot == 1 ? UUID() : originalIDs.package,
            grant: changedRoot == 2 ? UUID() : originalIDs.grant, structural: changedRoot == 3 ? UUID() : originalIDs.structural,
            provisioning: changedRoot == 4 ? UUID() : originalIDs.provisioning, contentGenesis: originalIDs.contentGenesis)
        let roots = try owner.restoreRecordedCloudEnrollmentRoots(claim: proposal.claimInput,
            cloudRootID: changedRoot == 0 ? UUID() : intent.cloudRootID, localIDs: ids)
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection,
            grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let session = try owner.makeFirstEnrollmentSession(roots: roots, proposal: proposal,
            excludedLocalResetRoot: protection.reset, storage: storage)
        let restored = try session.restoreCompleted(stores: stores)
        XCTAssertEqual(try nativeEnrollmentBytes(restored.activation), try nativeEnrollmentBytes(result.activation))
        let context = try owner.bindOperationalInstallation(installation: restored.installation, activation: restored.activation, origin: http.origin)
        let status = try owner.prepareCloudStatusRequest(context)
        try owner.beginCloudStatusRequest(context, requestID: status.requestID)
        try owner.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
        let current = try owner.prepareCurrentInstallationDispatch(context)
        let native = try restored.installation.makeDeliveryExecutionSession(current: current)
        let common = try owner.restoreUnifiedInventorySession(context: context,
            commonRootID: changedRoot == 5 ? UUID() : XCTUnwrap(intent.commonInventoryRootID), local: nil, native: native,
            restoreIncomingLocal: { values in XCTAssertTrue(values.isEmpty); return [] })
        XCTAssertEqual(try common.validatedAssociation().commonRootID, intent.commonInventoryRootID)
        let response = try await restored.installation.makeRealtimeSessionRequest(origin: http.origin, current: current)
            .performFixedTransport(configuration: http.configuration)
        XCTAssertEqual(storage.adds, 2)
        try owner.leaveCloudForeground()
        return response
    }
    func connect() throws -> Task<Void, Error> {
        let operationID = try controller.beginPreparedExplicitConnectionForTesting()
        return Task { @MainActor in
            let status = try authority.prepareCloudStatusRequest(context)
            try authority.beginCloudStatusRequest(context, requestID: status.requestID)
            try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
            let current = try authority.prepareCurrentInstallationDispatch(context)
            let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: result.installation,
                current: current, origin: http.origin, configuration: http.configuration)
            guard !command.hasCommand else { throw CancellationError() }
            try controller.completePreparedExplicitConnectionForTesting(operationID: operationID, current: current)
        }
    }
    func close() {
        controller.didEnterBackground(); http.close()
        try? FileManager.default.removeItem(at: parent)
    }
    fileprivate static func prepareRetainedLocalScreen(authority: DeviceManagementAuthority, parent: URL) throws -> DeviceLegacyMigrationSession {
        let lease = try XCTUnwrap(authority.refresh())
        let ids = try NativeManagedLocalRootIDs(package: UUID(), grant: UUID(), structural: UUID(), provisioning: UUID(), contentGenesis: UUID())
        let roots = try authority.prepareLocalInventoryRoots(lease: lease, ids: ids)
        let local = try DeviceLegacyMigrationSession(packageRoot: roots.packageRoot, packageRootID: ids.package,
            grantRoot: roots.grantRoot, grantRootID: ids.grant, structuralRoot: roots.structuralRoot, structuralRootID: ids.structural,
            provisioningRoot: roots.provisioningRoot, provisioningRootID: ids.provisioning,
            legacyStateRoot: parent.appendingPathComponent("legacy-state"), legacyArchiveRoot: parent.appendingPathComponent("legacy-archive"),
            resetRoot: parent.appendingPathComponent("reset"), cloudRoot: parent.appendingPathComponent("Application Support/xyz.screenpunk.native-managed"),
            managementRoot: parent.appendingPathComponent("management"), preferencesRoot: parent.appendingPathComponent("preferences"),
            otherProtectedRoots: [], credentialTransport: FreshGrantTransport(rootID: ids.grant),
            validateRoots: { try authority.validateLocalInventoryRoots(roots) })
        let html = Data("<html><body>Retained Local presentation</body></html>".utf8)
        var manifest = DashboardManifest(schemaVersion: 1, dashboardId: UUID().uuidString.lowercased(), name: "Retained Local",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: .init(profileId: "Fixture", width: 390, height: 844, scale: 3, orientation: "portrait"), connections: [],
            files: [.init(path: "index.html", bytes: html.count, sha256: AuthorityStaticDeliveryFixture.hash(html))])
        manifest.digest = AuthorityStaticDeliveryFixture.hash(try AuthorityStaticDeliveryFixture.encoded(manifest))
        let revision = StoredRevision(revision: manifest.revision, dashboardId: manifest.dashboardId, name: manifest.name,
            digest: try XCTUnwrap(manifest.digest), orientation: .portrait, width: 390, height: 844)
        let entry = UUID()
        let screen = DeviceLegacyMigrationScreen(entryID: entry, packageOperationID: UUID(), displayName: "Retained Local",
            revision: revision, manifest: try AuthorityStaticDeliveryFixture.encoded(manifest), files: ["index.html": html],
            homeAssistant: nil, generic: nil, publicReads: nil)
        try local.prepareAndCommit(screens: [screen], selected: entry, owner: PairingIdentityFactory.make(role: .controller),
            profile: .init(deviceId: "fixture", name: "Fixture"), profileID: "Fixture", operationID: UUID(),
            grantOperationID: UUID(), generationID: UUID(), grantRevisionID: UUID(), legacyGrantSet: nil,
            validateOriginal: { try authority.validateLocalInventoryRoots(roots) })
        return local
    }
    static func make(legacyContainerLocators: Bool = false, retainedLocalScreen: Bool = false, cloudProtocolFixture: Bool = false,
        hostFactory: ((DeviceManagementContext) throws -> DeviceLANHost)? = nil) async throws -> Self {
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: parent) } }
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent),
            commandIntents: .init(root: anchor.appendingPathComponent("xyz.screenpunk.device/command-intents")), concurrentControlQualified: true)
        try authority.prepareProductionSupportAnchor()
        let local = retainedLocalScreen ? try prepareRetainedLocalScreen(authority: authority, parent: parent) : nil
        try authority.enterCloudForeground()
        let initial = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Prepared native iPad", profile: cloudProtocolFixture ? "Fixture" : "ipad",
            origin: URL(string: "https://initial.fixture.test")!, viewport: cloudProtocolFixture ? CGSize(width: 390, height: 844) : CGSize(width: 768, height: 1024))
        let http = FreshOwnerHTTP(claim: try initial.proposal().claimInput)
        var httpRetained = false
        defer { if !httpRetained { http.close() } }
        // Only origin changes before original publication. Every protocol UUID
        // comes from this same immutable app intent and is passed to Core below.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        object["origin"] = http.origin.absoluteString
        object["activationRequestID"] = http.activationRequestID.uuidString
        let intent = try JSONDecoder().decode(NativeEnrollmentIntentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        let journal = NativeEnrollmentIntentJournal(directory: anchor.appendingPathComponent("xyz.screenpunk.enrollment-intent"))
        try journal.saveOriginal(intent)
        let proposal = try intent.proposal()
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: proposal.claimInput,
            recordedCloudRootID: intent.cloudRootID, recordedLocalIDs: intent.localIDs())
        let protection = NativeManagedProtectedRoots(legacyState: anchor.appendingPathComponent("xyz.screenpunk.device"),
            legacyArchive: anchor.appendingPathComponent("xyz.screenpunk.device"), reset: parent.appendingPathComponent("reset"),
            cloudEnrollment: roots.journalRoot, management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protection,
            grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let storage = FreshCredentialStorage()
        if legacyContainerLocators {
            try stores.initializeRootsExact()
            _ = try NativeEnrollmentJournalStore(root: roots.journalRoot, cloudRootID: roots.cloudRootID,
                excludedLocalResetRoot: protection.reset).initializeExplicit()
            for root in [roots.journalRoot] + ["packages", "grants", "structural", "provisioning"].map({ roots.namespace.appendingPathComponent($0) }) {
                try NativeLegacyContainerLocatorFixture.seedInitialBinding(root)
            }
        }
        let seededMetadata = legacyContainerLocators ? try NativeLegacyContainerLocatorFixture.retainedMetadata(parent) : [:]
        let session = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal,
            excludedLocalResetRoot: protection.reset, storage: storage)
        let result = try await session.enroll(origin: http.origin, tokenProvider: FreshOwnerTokens(),
            activationRequestID: http.activationRequestID, associationAttemptID: intent.associationAttemptID, stores: stores, configuration: http.configuration)
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: http.origin)
        let status = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: status.requestID)
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: http.origin, configuration: http.configuration), context: context)
        let current = try authority.prepareCurrentInstallationDispatch(context)
        try await result.installation.makeConcurrentControlCapabilityRequest(origin: http.origin, current: current,
            qualified: authority.qualifiedConcurrentControl(context: context)).performFixedTransport(configuration: http.configuration)
        let execution = try result.installation.makeDeliveryExecutionSession(current: current)
        let state = try execution.freshGenesisObservation(current: current)
        let stateAck = try await NativeDeliveryStateHTTPObservation.collect(body: state, installation: result.installation,
            current: current, origin: http.origin, configuration: http.configuration)
        let common = try authority.makeUnifiedInventorySession(context: context, current: current,
            commonRootID: XCTUnwrap(intent.commonInventoryRootID), local: local, native: execution)
        try common.migrate(current: current, operationID: XCTUnwrap(intent.unifiedMigrationOperationID),
            generationID: XCTUnwrap(intent.unifiedMigrationGenerationID), admissionEnabled: true)
        if legacyContainerLocators {
            try NativeLegacyContainerLocatorFixture.seedInitialBinding(anchor.appendingPathComponent("xyz.screenpunk.unified-inventory"), name: "mixed-root.json")
        }
        try common.retainCloudCheckpoint(authenticatedGenerationID: stateAck.acceptedGenerationID(body: state, installation: result.installation))
        while let observation = try common.pendingCloudObservation() {
            try await result.installation.makeUnifiedCloudObservationRequest(origin: http.origin, current: current,
                observation: observation).performFixedTransport(configuration: http.configuration)
        }
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: result.installation,
            current: current, origin: http.origin, configuration: http.configuration)
        guard !command.hasCommand else { throw CancellationError() }
        let bootstrap = DeviceManagementBootstrap(authority: authority, retained: { .empty },
            hostFactory: hostFactory ?? { _ in throw NativeRecoveryFixtureFailure.unexpectedEffect })
        bootstrap.useRecordedNativeCloudStartup() // Existing native files must not enter legacy absence admission.
        bootstrap.start()
        let controller = try NativeEnrollmentSceneController(testPreparedConnectionJournal: journal,
            bootstrap: bootstrap, authority: authority, roots: roots, result: result, context: context,
            native: execution, unified: common, current: current,
            sendUnified: { try await $0.performFixedTransport(configuration: http.configuration) },
            sendEmpty: { try await $0.performFixedTransport(configuration: http.configuration) },
            transportFactory: { NativeSequenceDeliveryTransport(origin: $0, configuration: http.configuration) },
            sendMounted: { try await $0.performFixedTransport(configuration: http.configuration) },
            sendCapabilities: { try await $0.performFixedTransport(configuration: http.configuration) },
            installConcurrentHost: hostFactory != nil || !cloudProtocolFixture)
        if legacyContainerLocators {
            let after = try NativeLegacyContainerLocatorFixture.retainedMetadata(parent)
            for (path, bytes) in seededMetadata { XCTAssertEqual(after[path], bytes, "Pre-claim locator/genesis/original bytes remain immutable") }
        }
        completed = true; httpRetained = true
        return .init(controller: controller, bootstrap: bootstrap, unified: common, execution: execution, roots: roots,
            http: http, parent: parent, accountID: intent.accountID, name: intent.name,
            authority: authority, result: result, context: context, storage: storage, intent: intent, protection: protection, local: local)
    }
}

@MainActor private final class NativeRealtimeFixtureDriver: NativeCloudRealtimeDriver {
    var event: (@MainActor (NativeCloudRealtimeEvent) -> Void)?
    func start(_ session: NativeInstallationRealtimeSession, event: @escaping @MainActor (NativeCloudRealtimeEvent) -> Void) async throws { self.event = event }
    func stop() { event = nil }
}

/// Models historical locators before any claim/protocol frame, retaining actual
/// current nodes. Old paths are strings only; never created, accessed or traversed.
private enum NativeLegacyContainerLocatorFixture {
    static func oldPath(_ path: String) throws -> String {
        let supplied = NSHomeDirectory()
        let raw = try XCTUnwrap(realpath(supplied, nil)); defer { free(raw) }
        let home = String(cString: raw)
        let current = try DeviceFilesystemTraversal.currentPath(forRecordedPath: path)
        guard current.hasPrefix(home + "/") else { throw CancellationError() }
        let oldHome = (home as NSString).deletingLastPathComponent + "/11111111-1111-4111-8111-111111111111"
        return oldHome + String(current.dropFirst(home.count))
    }
    static func writeExisting(_ bytes: Data, at url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CancellationError() }; defer { close(fd) }
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(fd) == 0 else { throw CancellationError() }
    }
    static func seedInitialBinding(_ root: URL, name: String = "root-binding.json") throws {
        let url = root.appendingPathComponent(name)
        let original = try Data(contentsOf: url)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for key in ["rootPath", "canonicalPath", "path"] {
            if let path = value[key] as? String { value[key] = try oldPath(path) }
        }
        if let paths = value["protectedPaths"] as? [String] { value["protectedPaths"] = try paths.map(oldPath) }
        let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try writeExisting(changed, at: url)
        let genesis = root.appendingPathComponent("genesis.json")
        if name == "root-binding.json", FileManager.default.fileExists(atPath: genesis.path) {
            var proof = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: genesis)) as? [String: Any])
            if var binding = proof["binding"] as? [String: Any] {
                binding["bytes"] = changed.base64EncodedString(); proof["binding"] = binding
                try writeExisting(JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .withoutEscapingSlashes]), at: genesis)
            }
        }
    }
    static func retainedMetadata(_ parent: URL) throws -> [String: Data] {
        let keys = Set(["root-binding.json", "mixed-root.json", "genesis.json", "original.json"])
        let files = try XCTUnwrap(FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil))
        var result: [String: Data] = [:]
        for case let file as URL in files where keys.contains(file.lastPathComponent) {
            result[String(file.path.dropFirst(parent.path.count))] = try Data(contentsOf: file)
        }
        return result
    }
}

private final class NativeRelocationEmptyGrantBackend: DeviceGrantCredentialBackend, @unchecked Sendable {
    var mutations = 0
    func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {}
    func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? { nil }
    func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
        mutations += 1; throw CancellationError()
    }
}

private final class NativeAutomaticDriverOverlap: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var reached = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func release() { semaphore.signal() }
    func checkpoint() throws {
        lock.lock(); let first = armed; armed = false
        if first { reached = true }; lock.unlock()
        // A driver isolated to MainActor cannot overlap another synchronous
        // MainActor admission. The old independent actor holds the real session
        // here while ordinary Scene delivery executes, producing functional RED.
        if first && !Thread.isMainThread {
            guard semaphore.wait(timeout: .now() + 20) == .success else { throw CancellationError() }
        }
    }
}

/// Independent worker escape: a regression blocking MainActor cannot prevent
/// release. Normal qualification must cancel it before it fires.
private final class NativeSessionAdmissionEscape: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var didFire = false
    private var work: DispatchWorkItem?
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return didFire }
    init(admission: NativeSessionAdmissionProbe, after seconds: Double) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.cancelled else { self.lock.unlock(); return }
            self.didFire = true; self.lock.unlock()
            admission.release()
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); work?.cancel() }
    deinit { cancel() }
}

private final class NativeSessionAdmissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var reached = false
    private var count = 0
    private var firstThreadAfterArm: Bool?
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    var entries: Int { lock.lock(); defer { lock.unlock() }; return count }
    var firstThreadAfterArmWasMain: Bool? { lock.lock(); defer { lock.unlock() }; return firstThreadAfterArm }
    func arm() { lock.lock(); armed = true; reached = false; firstThreadAfterArm = nil; lock.unlock() }
    func release() { semaphore.signal() }
    func checkpoint() throws {
        try DeviceLocalResourceRegistry.requireIdle()
        lock.lock(); count += 1
        if armed, firstThreadAfterArm == nil { firstThreadAfterArm = Thread.isMainThread }
        let shouldHold = armed && !Thread.isMainThread
        if shouldHold { armed = false; reached = true }; lock.unlock()
        if shouldHold {
            guard semaphore.wait(timeout: .now() + 20) == .success else { throw CancellationError() }
        }
    }
}

/// Observes the hosted environment without supplying a phase or starting work.
@MainActor private struct SceneLANPhaseObserver<Content: View>: View {
    let content: Content
    let observe: (ScenePhase) -> Void
    @Environment(\.scenePhase) private var phase
    var body: some View {
        content.onAppear { observe(phase) }
            .onChange(of: phase) { observe($0) }
    }
}

/// Counts the real server listener boundaries without reading its mutable listener reference.
private final class SceneLANListenerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, ready = 0
    func observe(_ boundary: DeviceLANServer.ManagementBoundary) {
        lock.lock(); defer { lock.unlock() }
        switch boundary {
        case .listenerWillStart: starts += 1
        case .listenerReady: ready += 1
        default: break
        }
    }
    var snapshot: (starts: Int, ready: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, ready)
    }
}

/// Test-only call boundaries: fixed stages and error metadata, never payloads.
private enum SceneLANCallDiagnostic {
    enum Stage: String { case connect, hello, begin, localConfirm, confirm, query, install, replay, readback }
    static func run<Value>(_ stage: Stage, _ body: () throws -> Value) rethrows -> Value {
        print("Scene LAN call diagnostic stage=\(stage.rawValue) result=before")
        do {
            let value = try body()
            print("Scene LAN call diagnostic stage=\(stage.rawValue) result=after")
            return value
        } catch {
            let native = error as NSError
            print("Scene LAN call diagnostic stage=\(stage.rawValue) result=failed type=\(String(reflecting: type(of: error))) domain=\(native.domain) code=\(native.code)")
            throw error
        }
    }
}

/// Teardown runs after an async test returns, in explicit reverse ownership order.
/// Held gates and owned tasks drain before grants, files or TLS fixture identities close.
@MainActor private final class SceneLANFixtureCleanup {
    private var actions: [@MainActor () async -> Void] = []
    func add(_ action: @escaping @MainActor () async -> Void) { actions.append(action) }
    func run() async {
        let pending = actions.reversed()
        actions.removeAll()
        for action in pending { await action() }
    }
}

/// Local lifecycle harness for a Root hosted outside the app's SwiftUI Scene.
@MainActor private final class SceneLANPhaseDriver: ObservableObject {
    @Published var phase: ScenePhase
    init(phase: ScenePhase) { self.phase = phase }
}
@MainActor private struct SceneLANLifecycleFixture<Content: View>: View {
    @ObservedObject var driver: SceneLANPhaseDriver
    let content: Content
    var body: some View { content.environment(\.scenePhase, driver.phase) }
}
