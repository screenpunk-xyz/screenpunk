import XCTest
import ScreenpunkCore
@testable import Screenpunk

@MainActor
final class CloudConnectionCoordinatorTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private var identity: Data { Data(#"{"user":{"id":"22222222-2222-4222-8222-222222222222","displayName":"Fixture person","email":null},"signInProvider":"google.com","authTime":"2026-10-02T16:00:00Z","tokenExpiresAt":"2026-10-02T17:00:00Z"}"#.utf8) }
    private var empty: Data { Data(#"{"items":[],"nextCursor":null}"#.utf8) }
    private var sparse: Data { Data(#"{"items":[],"nextCursor":"next-page"}"#.utf8) }
    private var accounts: Data { Data(#"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Fixture workspace","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"owner":true,"administrator":true,"canEnroll":true}}],"nextCursor":null}"#.utf8) }
    private var locations: Data { Data(#"{"items":[{"id":"33333333-3333-4333-8333-333333333333","name":"Fixture location","createdAt":"2026-10-02","updatedAt":"2026-10-02","capabilities":{"canView":true,"canOperate":false,"canEnroll":false}}],"nextCursor":null}"#.utf8) }

    private func coordinator(_ transports: [CoordinatorTransport], journal: (any CloudWorkspaceSetupJournal)? = nil, authenticate: @escaping (CloudNativeSignInProvider) async throws -> any CloudNativeTokenProvider = { _ in CoordinatorTokens() }, signOut: @escaping () throws -> Void = {}) -> CloudConnectionCoordinator {
        var index = 0
        return .init(authenticate: authenticate, cancelIdentityFlow: {}, signOutIdentity: signOut, makeClient: { tokens in
            let transport = transports[index]; index += 1
            return try CloudNativeClient(baseURL: URL(string: "https://cloud.example.invalid")!, tokenProvider: tokens, transport: transport)
        }, journal: journal ?? TestWorkspaceJournal())
    }

    func testAccountSwitchPreservesUnresolvedPersistenceButClearsPresentation() async throws {
        let journal = TestWorkspaceJournal(); journal.failSaveNumber = 1
        let otherIdentity = Data(String(decoding: identity, as: UTF8.self).replacingOccurrences(of: "22222222-2222-4222-8222-222222222222", with: "44444444-4444-4444-8444-444444444444").utf8)
        let first = CoordinatorTransport([.reply(identity), .reply(empty)])
        let second = CoordinatorTransport([.reply(otherIdentity), .reply(empty)])
        let coordinator = coordinator([first, second], journal: journal)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        let original = try XCTUnwrap(journal.attemptedRecord)
        coordinator.signOut(); XCTAssertNil(coordinator.pendingWorkspaceSetup)
        await coordinator.signIn(provider: .apple)?.value
        XCTAssertEqual(coordinator.failure, .pendingOtherUser)
        XCTAssertFalse(coordinator.canCreateFirstWorkspace); XCTAssertNil(coordinator.retryWorkspaceSetup())
        XCTAssertEqual(journal.attemptedRecord, original); XCTAssertEqual(journal.repairs, 0)
        XCTAssertNil(coordinator.workspaceSetupReceipt); XCTAssertNil(coordinator.pendingWorkspaceSetup)
        let requests = await second.requests
        XCTAssertEqual(requests.map { $0.url.path }, ["/v1/native/sign-in", "/v1/native/accounts"])
    }
    func testRevocationInsideClientFactoryPreventsSignInRequest() async {
        let transport = CoordinatorTransport([.reply(identity), .reply(empty)])
        weak var reference: CloudConnectionCoordinator?
        let instance = CloudConnectionCoordinator(authenticate: { _ in CoordinatorTokens() }, cancelIdentityFlow: {}, signOutIdentity: {}, makeClient: { tokens in
            reference?.cancel()
            return try CloudNativeClient(baseURL: URL(string: "https://cloud.example.invalid")!, tokenProvider: tokens, transport: transport)
        }, journal: TestWorkspaceJournal())
        reference = instance
        await instance.signIn(provider: .google)?.value
        XCTAssertNil(instance.humanIdentity); XCTAssertFalse(instance.isWorking)
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testImmediateCancelPreventsQueuedProviderPresentation() async {
        var authentications = 0
        let coordinator = coordinator([], authenticate: { _ in
            authentications += 1
            return CoordinatorTokens()
        })
        let queued = coordinator.signIn(provider: .google)
        coordinator.cancel()
        await queued?.value
        XCTAssertEqual(authentications, 0)
        XCTAssertNil(coordinator.humanIdentity)
        XCTAssertFalse(coordinator.isWorking)
    }

    func testImmediateCancelAndReplacementDoNotRunOldProviderOrClearNewIdentity() async {
        var providers: [CloudNativeSignInProvider] = []
        let transport = CoordinatorTransport([.reply(identity), .reply(accounts)])
        let coordinator = coordinator([transport], authenticate: { provider in
            providers.append(provider)
            return CoordinatorTokens()
        })
        let old = coordinator.signIn(provider: .apple)
        coordinator.cancel()
        let replacement = coordinator.signIn(provider: .google)
        await replacement?.value
        await old?.value
        XCTAssertEqual(providers, [.google])
        XCTAssertNotNil(coordinator.humanIdentity)
        XCTAssertEqual(coordinator.accounts.count, 1)
        XCTAssertFalse(coordinator.isWorking)
        XCTAssertNil(coordinator.failure)
    }

    func testSuccessfulDiscoveryFollowsSparsePagesAndRequiresExplicitAccountSelection() async throws {
        let transport = CoordinatorTransport([.reply(identity), .reply(sparse), .reply(accounts), .reply(sparse), .reply(locations)])
        let coordinator = coordinator([transport])
        await coordinator.signIn(provider: .google)?.value
        XCTAssertEqual(coordinator.accounts.count, 1)
        XCTAssertNotNil(coordinator.humanIdentity)
        XCTAssertNil(coordinator.selectedAccountID)
        XCTAssertTrue(coordinator.locations.isEmpty)
        await coordinator.discoverLocations(accountID: accountID)?.value
        XCTAssertEqual(coordinator.locations.count, 1)
        XCTAssertEqual(coordinator.selectedAccountID, accountID)
        XCTAssertFalse(coordinator.isWorking)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(URLComponents(url: requests[2].url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value, "next-page")
        XCTAssertEqual(URLComponents(url: requests[4].url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value, "next-page")
    }

    func testCancelClearsStateSynchronouslyAndDiscardsLateDiscovery() async {
        let transport = CoordinatorTransport([.reply(identity), .reply(accounts), .hold(locations)])
        let coordinator = coordinator([transport])
        await coordinator.signIn(provider: .google)?.value
        let discovery = coordinator.discoverLocations(accountID: accountID)
        await transport.waitUntilHeld()
        coordinator.cancel()
        XCTAssertNil(coordinator.humanIdentity)
        XCTAssertTrue(coordinator.accounts.isEmpty)
        XCTAssertTrue(coordinator.locations.isEmpty)
        XCTAssertNil(coordinator.selectedAccountID)
        XCTAssertFalse(coordinator.isWorking)
        await transport.release()
        await discovery?.value
        XCTAssertTrue(coordinator.locations.isEmpty)
        XCTAssertNil(coordinator.failure)
    }

    func testSignOutThenNewLoginDiscardsOldCompletionWithoutClearingNewState() async {
        let old = CoordinatorTransport([.reply(identity), .hold(accounts)])
        let new = CoordinatorTransport([.reply(identity), .reply(empty)])
        var signOuts = 0
        let coordinator = coordinator([old, new], signOut: { signOuts += 1 })
        let oldTask = coordinator.signIn(provider: .google)
        await old.waitUntilHeld()
        XCTAssertNil(coordinator.signIn(provider: .apple))
        coordinator.signOut()
        XCTAssertEqual(signOuts, 1)
        XCTAssertNil(coordinator.humanIdentity)
        XCTAssertFalse(coordinator.isWorking)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertNotNil(coordinator.humanIdentity)
        await old.release()
        await oldTask?.value
        XCTAssertNotNil(coordinator.humanIdentity)
        XCTAssertTrue(coordinator.accounts.isEmpty)
        XCTAssertFalse(coordinator.isWorking)
        XCTAssertNil(coordinator.failure)
    }

    func testProviderFailureAndSignOutFailureLeaveNoDiscoveryContextAndAllowRetry() async {
        let transport = CoordinatorTransport([.reply(identity), .reply(accounts)])
        var attempts = 0
        let coordinator = coordinator([transport], authenticate: { _ in
            attempts += 1
            if attempts == 1 { throw CloudNativeIdentityError.providerFailed }
            return CoordinatorTokens()
        }, signOut: { throw CloudNativeIdentityError.providerFailed })
        await coordinator.signIn(provider: .google)?.value
        XCTAssertEqual(coordinator.failure, .authentication)
        XCTAssertNil(coordinator.humanIdentity)
        XCTAssertFalse(coordinator.isWorking)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertEqual(coordinator.accounts.count, 1)
        coordinator.signOut()
        XCTAssertEqual(coordinator.failure, .signOut)
        XCTAssertNil(coordinator.humanIdentity)
        XCTAssertTrue(coordinator.accounts.isEmpty)
    }

    func testLateProviderCompletionAfterCancelCannotStartAPIRequest() async {
        let gate = CoordinatorGate()
        let transport = CoordinatorTransport([])
        let coordinator = coordinator([transport], authenticate: { _ in await gate.wait(); return CoordinatorTokens() })
        let operation = coordinator.signIn(provider: .google)
        await gate.waitUntilEntered()
        coordinator.cancel()
        await gate.release()
        await operation?.value
        XCTAssertNil(coordinator.humanIdentity)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(coordinator.isWorking)
    }

    func testDiscoveryFailureClearsSelectionAndAllowsRetry() async {
        let transport = CoordinatorTransport([.reply(identity), .reply(accounts), .reply(Data("invalid".utf8)), .reply(locations)])
        let coordinator = coordinator([transport])
        await coordinator.signIn(provider: .google)?.value
        await coordinator.discoverLocations(accountID: accountID)?.value
        XCTAssertEqual(coordinator.failure, .discovery)
        XCTAssertNil(coordinator.selectedAccountID)
        XCTAssertTrue(coordinator.locations.isEmpty)
        await coordinator.discoverLocations(accountID: accountID)?.value
        XCTAssertEqual(coordinator.locations.count, 1)
        XCTAssertNil(coordinator.failure)
    }
}

private struct CoordinatorTokens: CloudNativeTokenProvider {
    func idToken() async throws -> String { "fixture-short-lived-token" }
}
private actor CoordinatorTransport: HTTPTransport {
    enum Step { case reply(Data), hold(Data) }
    private var steps: [Step]
    private var continuation: CheckedContinuation<HTTPTransportResponse, Never>?
    private var heldResponse: Data?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [AuthorizedHTTPRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw CloudNativeFailure.transportUnavailable }
        switch steps.removeFirst() {
        case .reply(let data): return .init(status: 200, body: data)
        case .hold(let data):
            heldResponse = data
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiters.forEach { $0.resume() }; waiters = []
            }
        }
    }
    func waitUntilHeld() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        continuation?.resume(returning: .init(status: 200, body: heldResponse ?? Data()))
        continuation = nil; heldResponse = nil
    }
}
private actor CoordinatorGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
