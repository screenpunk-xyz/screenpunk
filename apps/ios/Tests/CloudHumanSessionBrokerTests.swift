import XCTest
import Combine
import ScreenpunkCore
@testable import Screenpunk

@MainActor
final class CloudHumanSessionBrokerTests: XCTestCase {
    func testDormantAndOccupiedLoserHaveNoFactoryOrSDKEffects() throws {
        let broker = CloudHumanSessionBroker(), first = BrokerFixture(), second = BrokerFixture()
        XCTAssertEqual(broker.state, .vacant); XCTAssertEqual(first.factories, 0)
        _ = try broker.acquire(owner: UUID(), factory: first.make)
        XCTAssertThrowsError(try broker.acquire(owner: UUID(), factory: second.make))
        XCTAssertEqual(second.factories, 0); XCTAssertEqual(second.authentications, 0); XCTAssertEqual(second.clears, 0)
    }
    func testFactoryFailureReleasesOnlyItsReservedGeneration() throws {
        let broker = CloudHumanSessionBroker()
        XCTAssertThrowsError(try broker.acquire(owner: UUID()) { lease in
            try lease.checkConstruction(); throw CloudNativeIdentityError.notConfigured
        })
        XCTAssertEqual(broker.state, .vacant)
        let next = BrokerFixture(); _ = try broker.acquire(owner: UUID(), factory: next.make)
        XCTAssertEqual(next.factories, 1)
    }
    func testObsoleteFactoryCompletionCannotReleaseReentrantSuccessor() throws {
        let broker = CloudHumanSessionBroker(), old = BrokerFixture(), next = BrokerFixture()
        var successor: CloudHumanSessionBroker.Lease?
        XCTAssertThrowsError(try broker.acquire(owner: UUID()) { lease in
            _ = broker.retire(lease)
            successor = try broker.acquire(owner: UUID(), factory: next.make)
            return try old.make(lease)
        })
        XCTAssertTrue(try XCTUnwrap(successor).isCurrent)
        XCTAssertEqual(broker.state, .attached); XCTAssertEqual(old.factories, 0)
    }

    func testBackgroundRevokesWithoutReleasingRetainedPair() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(), scene = CloudHumanSessionLifecycle(broker: broker)
        try scene.install(factory: fixture.make)
        await fixture.coordinator?.signIn(provider: .google)?.value
        let before = fixture.cancellations
        scene.didEnterBackground()
        XCTAssertEqual(fixture.cancellations, before + 1); XCTAssertEqual(broker.state, .attached)
        let loser = BrokerFixture(); XCTAssertThrowsError(try broker.acquire(owner: UUID(), factory: loser.make))
        XCTAssertEqual(loser.factories, 0); XCTAssertEqual(fixture.clears, 0)
    }
    func testNormalSignOutInvalidatesOldActionsAndAllowsExplicitFreshPair() async throws {
        let broker = CloudHumanSessionBroker(), old = BrokerFixture(), scene = CloudHumanSessionLifecycle(broker: broker)
        try scene.install(factory: old.make)
        await old.coordinator?.signIn(provider: .google)?.value
        let oldCoordinator = try XCTUnwrap(old.coordinator), oldLease = try XCTUnwrap(old.lease)
        await scene.signOut()?.value
        XCTAssertEqual(broker.state, .vacant); XCTAssertNil(scene.coordinator)
        let next = BrokerFixture(); try scene.install(factory: next.make)
        await next.coordinator?.signIn(provider: .apple)?.value
        XCTAssertEqual(next.authentications, 1)
        let before = old.authentications, clears = old.clears
        await oldCoordinator.signIn(provider: .google)?.value
        oldCoordinator.cancel(); await broker.signOut(oldLease)?.value
        XCTAssertEqual(old.authentications, before); XCTAssertEqual(old.clears, clears)
        XCTAssertEqual(next.cancellations, 1) // Only its own sign-in entry revocation.
        XCTAssertFalse(old.session?.handleCallback(URL(string: "fixture:/callback")!) ?? true)
        XCTAssertTrue(scene.coordinator === next.coordinator)
    }
    func testStaleSignInAtSuccessfulClearCannotRaceBrokerRelease() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture()
        let lease = try broker.acquire(owner: UUID(), factory: fixture.make)
        let coordinator = try XCTUnwrap(fixture.coordinator)
        var late: Task<Void, Never>?
        let observation = coordinator.$signOutState.sink { state in
            if state == .succeeded { late = coordinator.signIn(provider: .google) }
        }
        await broker.signOut(lease)?.value; await late?.value
        XCTAssertEqual(fixture.authentications, 0); XCTAssertEqual(fixture.clears, 1)
        XCTAssertEqual(broker.state, .vacant)
        withExtendedLifetime(observation) {}
    }
    func testPendingAndFailedCleanupRejectCallbacksBeforeHandler() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.holdClear = true; fixture.failClear = true
        let lease = try broker.acquire(owner: UUID(), factory: fixture.make)
        let pair = try XCTUnwrap(fixture.session)
        let clear = broker.signOut(lease)
        while fixture.clearContinuation == nil { await Task.yield() }
        XCTAssertFalse(pair.handleCallback(URL(string: "fixture:/callback")!))
        fixture.releaseClear(); await clear?.value
        XCTAssertFalse(pair.handleCallback(URL(string: "fixture:/callback")!))
        XCTAssertEqual(broker.state, .cleanupFailed)
    }

    func testRetirementWaitsIgnoredProviderExitAndOutlivesScene() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.holdAuthentication = true
        var scene: CloudHumanSessionLifecycle? = CloudHumanSessionLifecycle(broker: broker)
        try scene?.install(factory: fixture.make)
        let task = fixture.coordinator?.signIn(provider: .google)
        while fixture.authContinuation == nil { await Task.yield() }
        scene?.retirePresentationContext(); scene = nil
        while fixture.clears == 0 { await Task.yield() }
        XCTAssertEqual(broker.state, .retiring)
        XCTAssertThrowsError(try broker.acquire(owner: UUID(), factory: BrokerFixture().make))
        fixture.releaseAuthentication(); await task?.value
        while broker.state == .retiring { await Task.yield() }
        XCTAssertEqual(broker.state, .vacant); XCTAssertNil(fixture.coordinator?.humanIdentity)
    }
    func testDroppingAttachedSceneTriggersRetainedCleanupWithoutPermanentLock() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.holdClear = true
        var scene: CloudHumanSessionLifecycle? = CloudHumanSessionLifecycle(broker: broker)
        weak var weakScene = scene
        try scene?.install(factory: fixture.make)
        scene = nil
        XCTAssertNil(weakScene)
        while fixture.clearContinuation == nil { await Task.yield() }
        XCTAssertEqual(broker.state, .retiring)
        fixture.releaseClear()
        while broker.state == .retiring { await Task.yield() }
        XCTAssertEqual(broker.state, .vacant)
    }

    func testRetirementAlsoWaitsExchangeExit() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.holdExchange = true
        let lease = try broker.acquire(owner: UUID(), factory: fixture.make)
        let task = fixture.coordinator?.signIn(provider: .google)
        while fixture.exchangeContinuation == nil { await Task.yield() }
        let cleanup = broker.retire(lease)
        while fixture.clears == 0 { await Task.yield() }
        XCTAssertEqual(broker.state, .retiring)
        fixture.releaseExchange(); await task?.value; await cleanup?.value
        XCTAssertEqual(broker.state, .vacant); XCTAssertNil(fixture.coordinator?.humanIdentity)
    }
    func testPartialClearFailureRetainsCleanupForExplicitRetryFromAnotherScene() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.failClear = true
        let scene = CloudHumanSessionLifecycle(broker: broker); try scene.install(factory: fixture.make)
        await fixture.coordinator?.signIn(provider: .google)?.value
        scene.retirePresentationContext()
        while broker.state == .retiring { await Task.yield() }
        XCTAssertEqual(broker.state, .cleanupFailed)
        XCTAssertEqual(fixture.firebaseClears, 1); XCTAssertEqual(fixture.googleClears, 1)
        let other = CloudHumanSessionLifecycle(broker: broker), loser = BrokerFixture()
        XCTAssertThrowsError(try other.install(factory: loser.make)); XCTAssertEqual(loser.factories, 0)
        fixture.failClear = false; await broker.retryRetiredCleanup()?.value
        XCTAssertEqual(broker.state, .vacant)
        try other.install(factory: loser.make); XCTAssertEqual(loser.factories, 1)
    }
    func testNormalFailedSignOutBlocksReacquisitionUntilExactRetry() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.failClear = true
        let scene = CloudHumanSessionLifecycle(broker: broker); try scene.install(factory: fixture.make)
        await scene.signOut()?.value
        XCTAssertEqual(broker.state, .cleanupFailed)
        XCTAssertThrowsError(try scene.install(factory: BrokerFixture().make))
        fixture.failClear = false; await scene.retrySignOut()?.value
        XCTAssertEqual(broker.state, .vacant); XCTAssertNil(scene.coordinator)
    }
    func testRepeatedRetirementAndSignOutJoinOneSettlement() async throws {
        let broker = CloudHumanSessionBroker(), fixture = BrokerFixture(); fixture.holdClear = true
        let lease = try broker.acquire(owner: UUID(), factory: fixture.make)
        let first = broker.signOut(lease)
        while fixture.clearContinuation == nil { await Task.yield() }
        let joined = broker.retire(lease), again = broker.signOut(lease)
        first?.cancel()
        fixture.releaseClear(); await first?.value; await joined?.value; await again?.value
        XCTAssertEqual(fixture.clears, 1); XCTAssertEqual(broker.state, .vacant)
    }
    func testStaleRetirementReleaseAndCallbackCannotAffectSuccessor() async throws {
        let broker = CloudHumanSessionBroker(), old = BrokerFixture()
        let lease = try broker.acquire(owner: UUID(), factory: old.make)
        await broker.signOut(lease)?.value
        let next = BrokerFixture(); let nextLease = try broker.acquire(owner: UUID(), factory: next.make)
        XCTAssertNil(broker.retire(lease)); XCTAssertNil(broker.retrySignOut(lease)); broker.cancel(lease)
        XCTAssertTrue(nextLease.isCurrent); XCTAssertEqual(next.clears, 0); XCTAssertEqual(next.cancellations, 0)
        XCTAssertThrowsError(try lease.checkHumanAction())
    }
}

@MainActor
private final class BrokerFixture {
    var factories = 0, authentications = 0, cancellations = 0, clears = 0, firebaseClears = 0, googleClears = 0
    var failClear = false, holdAuthentication = false, holdExchange = false, holdClear = false
    var authContinuation: CheckedContinuation<Void, Never>?, exchangeContinuation: CheckedContinuation<Void, Never>?, clearContinuation: CheckedContinuation<Void, Never>?
    private var providerExited = true
    var lease: CloudHumanSessionBroker.Lease?, coordinator: CloudConnectionCoordinator?, session: CloudHumanSession?
    func make(_ lease: CloudHumanSessionBroker.Lease) throws -> CloudHumanSession {
        try lease.checkConstruction(); factories += 1; self.lease = lease
        let coordinator = CloudConnectionCoordinator(authenticate: { [self] _ in
            try lease.checkHumanAction(); authentications += 1; providerExited = false
            defer { providerExited = true }
            if holdAuthentication { await withCheckedContinuation { authContinuation = $0 } }
            try lease.checkHumanAction()
            if holdExchange { await withCheckedContinuation { exchangeContinuation = $0 } }
            try lease.checkHumanAction(); return BrokerTokens()
        }, cancelIdentityFlow: { [weak self] in if lease.isCurrent { self?.cancellations += 1 } },
        signOutIdentity: { [self] in try await clear(lease) }, retrySignOutIdentity: { [self] in try await clear(lease) },
        makeClient: { tokens in try lease.checkHumanAction(); return try CloudNativeClient(baseURL: URL(string: "https://fixture.invalid")!, tokenProvider: tokens, transport: BrokerTransport()) }, journal: BrokerJournal())
        self.coordinator = coordinator
        let pair = CloudHumanSession(testCoordinator: coordinator, testCallback: { _ in true }); session = pair; return pair
    }
    private func clear(_ lease: CloudHumanSessionBroker.Lease) async throws {
        try lease.checkSettlement(); clears += 1
        while !providerExited { await Task.yield() }
        if holdClear { await withCheckedContinuation { clearContinuation = $0 } }
        firebaseClears += 1; googleClears += 1
        if failClear { throw CloudNativeIdentityError.providerFailed }
    }
    func releaseAuthentication() { authContinuation?.resume(); authContinuation = nil }
    func releaseExchange() { exchangeContinuation?.resume(); exchangeContinuation = nil }
    func releaseClear() { clearContinuation?.resume(); clearContinuation = nil }
}
private struct BrokerTokens: CloudNativeTokenProvider { func idToken() async throws -> String { "fixture" } }
private struct BrokerTransport: HTTPTransport {
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        if request.url.path.hasSuffix("sign-in") { return .init(status: 200, body: Data(#"{"user":{"id":"11111111-1111-4111-8111-111111111111","email":"fixture@example.invalid","displayName":"Fixture"},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#.utf8)) }
        return .init(status: 200, body: Data(#"{"items":[],"nextCursor":null}"#.utf8))
    }
}
@MainActor private final class BrokerJournal: CloudWorkspaceSetupJournal {
    func load() throws -> CloudWorkspaceSetupJournalRecord? { nil }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws {}
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws {}
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord { throw CocoaError(.fileReadUnknown) }
}
