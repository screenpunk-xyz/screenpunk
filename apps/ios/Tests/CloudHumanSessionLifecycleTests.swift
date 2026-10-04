import XCTest
import SwiftUI
import UIKit
import Combine
import ScreenpunkCore
@testable import Screenpunk

final class CloudHumanSessionLifecycleTests: XCTestCase {
    @MainActor func testAccountEntrySnapshotObservesOwnershipReleaseWithoutAcquisition() throws {
        let broker = CloudHumanSessionBroker()
        let owner = CloudHumanSessionLifecycle(broker: broker), later = CloudHumanSessionLifecycle(broker: broker)
        XCTAssertEqual(owner.accountEntryState, .available); XCTAssertEqual(later.accountEntryState, .available)
        var changes = 0, factories = 0
        let observation = later.objectWillChange.sink { changes += 1 }
        let original = FakeHumanContext()
        try owner.install(factory: { _ in
            factories += 1
            return CloudHumanSession(testCallback: original.callback, testRevoke: original.revoke)
        })
        XCTAssertEqual(owner.accountEntryState, .ownedHere); XCTAssertEqual(later.accountEntryState, .occupiedElsewhere)
        XCTAssertGreaterThan(changes, 0)
        later.cancelPresentation(); later.didEnterBackground()
        XCTAssertEqual(original.revocations, 0)
        let occupiedChanges = changes
        owner.retirePresentationContext()
        XCTAssertEqual(owner.accountEntryState, .retired); XCTAssertEqual(later.accountEntryState, .available)
        XCTAssertGreaterThan(changes, occupiedChanges); XCTAssertEqual(factories, 1)
        let successor = FakeHumanContext()
        try later.install(CloudHumanSession(testCallback: successor.callback, testRevoke: successor.revoke))
        owner.cancelPresentation(); owner.didEnterBackground(); owner.retirePresentationContext()
        XCTAssertEqual(successor.revocations, 0); XCTAssertEqual(later.accountEntryState, .ownedHere)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testAttachedFailedSignOutKeepsOwnerEntryAndBlocksOtherWindow() async throws {
        let broker = CloudHumanSessionBroker()
        var fail = true
        let coordinator = CloudConnectionCoordinator(authenticate: { _ in LifecycleTokens() },
            cancelIdentityFlow: {}, signOutIdentity: { if fail { throw CloudNativeIdentityError.providerFailed } },
            makeClient: { try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: $0, transport: LifecycleTransport()) }, journal: LifecycleJournal())
        let owner = CloudHumanSessionLifecycle(broker: broker), later = CloudHumanSessionLifecycle(broker: broker)
        try owner.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in true }))
        await owner.signOut()?.value
        XCTAssertEqual(coordinator.signOutState, .failed)
        XCTAssertEqual(owner.accountEntryState, .ownedHere); XCTAssertTrue(owner.coordinator === coordinator)
        XCTAssertEqual(later.accountEntryState, .occupiedElsewhere); XCTAssertEqual(later.retiredCleanupState, .none)
        fail = false; await owner.retrySignOut()?.value
        XCTAssertEqual(owner.accountEntryState, .available); XCTAssertEqual(later.accountEntryState, .available)
        XCTAssertNil(later.coordinator)
    }

    @MainActor func testWrongSceneOnlyTransportsToAttachedOwner() throws {
        let broker = CloudHumanSessionBroker()
        let owner = CloudHumanSessionLifecycle(broker: broker)
        let receiver = CloudHumanSessionLifecycle(broker: broker)
        let context = FakeHumanContext()
        try owner.install(CloudHumanSession(testCallback: { context.callback($0) }, testRevoke: { context.revoke() }))
        let url = URL(string: "com.googleusercontent.apps.fixture:/oauth2callback")!
        XCTAssertFalse(receiver.handleCallback(url))
        XCTAssertTrue(receiver.dispatchGoogleCallback(url))
        receiver.cancelPresentation(); receiver.scenePhaseChanged(.background)
        XCTAssertEqual(context.revocations, 0)
        receiver.retirePresentationContext()
        XCTAssertFalse(receiver.dispatchGoogleCallback(url))
        XCTAssertTrue(owner.dispatchGoogleCallback(url))
        owner.cancelPresentation()
        XCTAssertFalse(owner.dispatchGoogleCallback(url))
    }

    @MainActor func testLaterLiveSceneObservesRepairAndRetiredReceiverCannotRetry() async throws {
        let broker = CloudHumanSessionBroker(), gate = LifecycleClearGate()
        var fail = true, clears = 0, cancellations = 0
        let coordinator = CloudConnectionCoordinator(authenticate: { _ in LifecycleTokens() },
            cancelIdentityFlow: { cancellations += 1 }, signOutIdentity: {
                clears += 1
                if fail { throw CloudNativeIdentityError.providerFailed }
                await gate.wait()
            }, makeClient: { try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: $0, transport: LifecycleTransport()) }, journal: LifecycleJournal())
        let owner = CloudHumanSessionLifecycle(broker: broker)
        try owner.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in true }))
        let receiver = CloudHumanSessionLifecycle(broker: broker)
        var notifications = 0
        let observation = receiver.objectWillChange.sink { notifications += 1 }
        owner.retirePresentationContext()
        while broker.state == .retiring { await Task.yield() }
        guard case .failed(let handle) = receiver.retiredCleanupState else { return XCTFail("Missing handle") }
        XCTAssertEqual(receiver.accountEntryState, .occupiedElsewhere)
        XCTAssertEqual(owner.accountEntryState, .retired)
        XCTAssertEqual(owner.retiredCleanupState, .none)
        XCTAssertNil(owner.retryRetiredCleanup(handle))
        fail = false
        let retry = receiver.retryRetiredCleanup(handle)
        while !gate.entered { await Task.yield() }
        let before = cancellations
        receiver.cancelPresentation(); receiver.didEnterBackground(); receiver.retirePresentationContext()
        XCTAssertEqual(cancellations, before)
        XCTAssertNil(receiver.retryRetiredCleanup(handle))
        gate.release(); await retry?.value
        XCTAssertEqual(clears, 2); XCTAssertEqual(broker.retiredCleanupState, .none)
        XCTAssertGreaterThanOrEqual(notifications, 3)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testDormantCallbacksAndPhasesNeverConstructSession() {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        XCTAssertNil(lifecycle.coordinator)
        XCTAssertFalse(lifecycle.handleCallback(URL(string: "calendar:/oauth2redirect")!))
        XCTAssertFalse(lifecycle.handleCallback(URL(string: "com.googleusercontent.apps.fixture:/oauth2callback")!))
        lifecycle.scenePhaseChanged(.inactive); lifecycle.scenePhaseChanged(.background)
        lifecycle.scenePhaseChanged(.active); lifecycle.cancelPresentation()
        XCTAssertNil(lifecycle.coordinator)
    }

    @MainActor func testUnconfiguredExplicitFactoryFailsBeforePresentation() {
        var presentations = 0
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let presentation = CloudProviderPresentation(testResolve: { presentations += 1; return .init(controller: UIViewController(), window: UIWindow()) })
        XCTAssertThrowsError(try lifecycle.installExplicit(presentation: presentation)) { error in
            XCTAssertEqual(error as? CloudNativeIdentityError, .notConfigured)
        }
        XCTAssertEqual(presentations, 0)
    }

    @MainActor func testOnePairRetainedAndCallbacksUseItsCurrentAdmission() throws {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        var context: FakeHumanContext? = FakeHumanContext()
        weak var retained = context
        try lifecycle.install(CloudHumanSession(testCallback: { [context = context!] in context.callback($0) },
                                               testRevoke: { [context = context!] in context.revoke() }))
        context = nil
        XCTAssertNotNil(retained)
        let sameOwner = lifecycle // SwiftUI redraws retain this StateObject; no replacement factory exists.
        let cloud = URL(string: "com.googleusercontent.apps.fixture:/oauth2callback?code=fixture")!
        XCTAssertTrue(sameOwner.handleCallback(cloud))
        XCTAssertFalse(sameOwner.handleCallback(URL(string: "calendar:/oauth2redirect")!))
        XCTAssertEqual(retained?.acceptedCallbacks, [cloud])
        XCTAssertThrowsError(try lifecycle.install(CloudHumanSession(testCallback: { _ in true }, testRevoke: {})))
        lifecycle.cancelPresentation()
        XCTAssertEqual(retained?.revocations, 1)
        XCTAssertFalse(lifecycle.handleCallback(cloud))
        XCTAssertNotNil(retained) // Revocation does not discard the coordinator's unresolved context.
        XCTAssertEqual(retained?.pendingRequest, "immutable-pending-fixture")
    }

    @MainActor func testBackgroundOnlyRevokesAndActiveDoesNotReplay() throws {
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()), context = FakeHumanContext()
        try lifecycle.install(CloudHumanSession(testCallback: context.callback, testRevoke: context.revoke))
        lifecycle.scenePhaseChanged(.inactive); lifecycle.scenePhaseChanged(.active)
        XCTAssertEqual(context.revocations, 0)
        lifecycle.scenePhaseChanged(.background)
        XCTAssertEqual(context.revocations, 1)
        lifecycle.scenePhaseChanged(.inactive); lifecycle.scenePhaseChanged(.active)
        XCTAssertEqual(context.revocations, 1)
        XCTAssertEqual(context.pendingRequest, "immutable-pending-fixture")
    }

    @MainActor func testRealCoordinatorRevokedOnceWithoutLosingPendingOperation() async throws {
        let journal = LifecycleJournal(), transport = LifecycleTransport()
        var cancellations = 0
        let coordinator = CloudConnectionCoordinator(authenticate: { _ in LifecycleTokens() },
            cancelIdentityFlow: { cancellations += 1 }, signOutIdentity: {},
            makeClient: { try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: $0, transport: transport) }, journal: journal)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Exact workspace", locationName: "Exact location"))
        let original = try XCTUnwrap(journal.attempt)
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        try lifecycle.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in false }))
        XCTAssertTrue(lifecycle.coordinator === coordinator)
        let before = cancellations
        lifecycle.didEnterBackground()
        XCTAssertEqual(cancellations, before + 1)
        XCTAssertNil(coordinator.humanIdentity); XCTAssertNil(coordinator.pendingWorkspaceSetup)
        XCTAssertEqual(journal.attempt, original)
        await coordinator.signIn(provider: .google)?.value
        await coordinator.retryWorkspaceSetup()?.value
        XCTAssertEqual(journal.record?.request, original.request)
        XCTAssertEqual(journal.repairs, 1)
        let posts = await transport.posts
        XCTAssertEqual(posts, [original.request])
    }

    @MainActor func testSceneSignOutRetainsPairThroughBackgroundAndPresentationCancel() async throws {
        let journal = LifecycleJournal(), transport = LifecycleTransport(), gate = LifecycleClearGate()
        var clears = 0
        let coordinator = CloudConnectionCoordinator(authenticate: { _ in LifecycleTokens() },
            cancelIdentityFlow: {}, signOutIdentity: { clears += 1; await gate.wait() },
            makeClient: { try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: $0, transport: transport) }, journal: journal)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Exact workspace", locationName: "Exact location"))
        let original = try XCTUnwrap(journal.attempt)
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        try lifecycle.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in false }))
        let first = lifecycle.signOut()
        while !gate.entered { await Task.yield() }
        let joined = lifecycle.signOut()
        lifecycle.didEnterBackground(); lifecycle.cancelPresentation()
        XCTAssertTrue(lifecycle.coordinator === coordinator)
        XCTAssertEqual(coordinator.signOutState, .pending)
        XCTAssertNil(coordinator.humanIdentity); XCTAssertNil(coordinator.pendingWorkspaceSetup)
        XCTAssertEqual(journal.attempt, original)
        XCTAssertNil(coordinator.signIn(provider: .google))
        first?.cancel() // Settlement is an explicit human intent, not presentation work.
        gate.release()
        await first?.value; await joined?.value
        XCTAssertEqual(clears, 1); XCTAssertEqual(coordinator.signOutState, .succeeded)
        XCTAssertEqual(journal.attempt, original)
        XCTAssertNil(lifecycle.coordinator)
    }

    @MainActor func testRetirementPublishesOneTerminalTransition() throws {
        let coordinator = CloudConnectionCoordinator(authenticate: { _ in throw CancellationError() },
            cancelIdentityFlow: {}, signOutIdentity: {},
            makeClient: { try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: $0, transport: LifecycleTransport()) },
            journal: LifecycleJournal())
        let lifecycle = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        try lifecycle.install(CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in false }))
        XCTAssertTrue(lifecycle.coordinator === coordinator)
        var changes = 0
        let observation = lifecycle.objectWillChange.sink { changes += 1 }
        lifecycle.retirePresentationContext()
        XCTAssertGreaterThanOrEqual(changes, 1); XCTAssertNil(lifecycle.coordinator)
        let terminalChanges = changes
        lifecycle.retirePresentationContext()
        XCTAssertEqual(changes, terminalChanges)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testRetirementTerminalAndInjectedBrokersDoNotRevokeEachOther() throws {
        let first = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker()), second = CloudHumanSessionLifecycle(broker: CloudHumanSessionBroker())
        let a = FakeHumanContext(), b = FakeHumanContext()
        try first.install(CloudHumanSession(testCallback: a.callback, testRevoke: a.revoke))
        try second.install(CloudHumanSession(testCallback: b.callback, testRevoke: b.revoke))
        first.retirePresentationContext(); first.retirePresentationContext()
        first.scenePhaseChanged(.background); first.cancelPresentation()
        XCTAssertNil(first.coordinator)
        XCTAssertEqual(a.revocations, 1); XCTAssertEqual(b.revocations, 0)
        XCTAssertFalse(first.handleCallback(URL(string: "com.googleusercontent.apps.fixture:/oauth2callback")!))
        XCTAssertThrowsError(try first.install(CloudHumanSession(testCallback: { _ in true }, testRevoke: {})))
        XCTAssertEqual(a.pendingRequest, "immutable-pending-fixture")
    }
}

@MainActor
private final class FakeHumanContext {
    var revocations = 0
    var acceptedCallbacks: [URL] = []
    let pendingRequest = "immutable-pending-fixture"
    private var active = true
    func callback(_ url: URL) -> Bool {
        guard active, url.scheme == "com.googleusercontent.apps.fixture", url.host == nil,
              url.path == "/oauth2callback" else { return false }
        acceptedCallbacks.append(url); return true
    }
    func revoke() { revocations += 1; active = false }
}


@MainActor
private final class LifecycleJournal: CloudWorkspaceSetupJournal {
    var record: CloudWorkspaceSetupJournalRecord?
    var attempt: CloudWorkspaceSetupJournalRecord?
    var repairs = 0
    func load() throws -> CloudWorkspaceSetupJournalRecord? {
        if attempt != nil { throw CocoaError(.fileWriteUnknown) }; return record
    }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws {
        if self.record == nil { attempt = record; throw CocoaError(.fileWriteUnknown) }
        self.record = record
    }
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws { XCTFail("Unexpected successor") }
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord {
        let retained = try XCTUnwrap(attempt)
        guard retained.userID == expectedUserID else { throw CocoaError(.fileWriteUnknown) }
        repairs += 1; record = retained; attempt = nil; return retained
    }
}
private struct LifecycleTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "fixture-token" } }
private actor LifecycleTransport: HTTPTransport {
    private(set) var posts: [CloudNativeWorkspaceSetupRequest] = []
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        if request.url.path == "/v1/native/sign-in" {
            return .init(status: 200, body: Data(#"{"user":{"id":"22222222-2222-4222-8222-222222222222","displayName":"Fixture","email":null},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#.utf8))
        }
        if request.url.path == "/v1/native/accounts" { return .init(status: 200, body: Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
        let setup = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(request.body))
        posts.append(setup)
        return .init(status: 200, body: Data("{\"requestId\":\"\(setup.requestId.uuidString)\",\"accountId\":\"11111111-1111-4111-8111-111111111111\",\"locationId\":\"33333333-3333-4333-8333-333333333333\",\"createdAt\":\"2026-10-02T16:00:00Z\"}".utf8))
    }
}


@MainActor
private final class LifecycleClearGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { let saved = continuation; continuation = nil; saved?.resume() }
}
