import XCTest
import SwiftUI
import UIKit
import ScreenpunkCore
@testable import Screenpunk

@MainActor
final class CloudAccountJourneyTests: XCTestCase {
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
        var captured: (UUID, UUID, String, String)?
        actions.enrollDevice = { captured = ($0, $1, $2, $3) }
        actions.enrollDevice?(account, location, "Tester device", "iPad")
        XCTAssertEqual(captured?.0, account); XCTAssertEqual(captured?.1, location)
        XCTAssertEqual(captured?.2, "Tester device"); XCTAssertEqual(captured?.3, "iPad")
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
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        var resolutions = 0
        let presentation = CloudProviderPresentation(testResolve: { resolutions += 1; return .init(controller: UIViewController(), window: UIWindow()) })
        let actions = CloudAccountJourneyActions(lifecycle: lifecycle, presentation: presentation, availability: .qualified)
        XCTAssertThrowsError(try actions.signIn(.apple)) { XCTAssertEqual($0 as? CloudNativeIdentityError, .notConfigured) }
        XCTAssertNil(lifecycle.coordinator); XCTAssertEqual(resolutions, 0)
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
            return .init(status: 200, body: Data((hasAccounts ? #"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Fixture workspace","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"owner":true,"administrator":true,"canEnroll":true}}],"nextCursor":null}"# : #"{"items":[],"nextCursor":null}"#).utf8))
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
