import XCTest
import ScreenpunkCore
@testable import Screenpunk

@MainActor
final class CloudWorkspaceSetupTests: XCTestCase {
    private let userA = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let userB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private func coordinator(_ journal: any CloudWorkspaceSetupJournal, _ transport: SetupTransport) -> CloudConnectionCoordinator {
        .init(authenticate: { _ in SetupTokens() }, cancelIdentityFlow: {}, signOutIdentity: {}, makeClient: { tokens in
            try CloudNativeClient(baseURL: URL(string: "https://cloud.example.invalid")!, tokenProvider: tokens, transport: transport)
        }, journal: journal)
    }
    private func signedIn(_ journal: any CloudWorkspaceSetupJournal, _ transport: SetupTransport) async -> CloudConnectionCoordinator {
        let result = coordinator(journal, transport)
        await result.signIn(provider: .google)?.value
        return result
    }

    func testImmediateCancellationRetainsPrewrittenOperationWithoutSendingPost() async throws {
        let journal = TestWorkspaceJournal()
        let transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        let operation = coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")
        let saved = try XCTUnwrap(journal.record)
        coordinator.cancel()
        await operation?.value
        XCTAssertEqual(journal.record, saved)
        let posts = await transport.posts
        XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(coordinator.pendingWorkspaceSetup)
    }

    func testUnreadablePersistedJournalBlocksNewSetupWithoutReplacingBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("setup.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("unreadable-journal".utf8)
        try corrupt.write(to: url)
        let transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(CloudWorkspaceSetupFileJournal(url: url), transport)
        XCTAssertEqual(coordinator.failure, .persistence)
        XCTAssertFalse(coordinator.canCreateFirstWorkspace)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        XCTAssertNil(coordinator.recoverWorkspaceSetup())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let posts = await transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testLostReplyRestartRetriesExactNamesAndRequestID() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("setup.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let firstTransport = SetupTransport(userID: userA, setup: [.timeout])
        let first = await signedIn(CloudWorkspaceSetupFileJournal(url: url), firstTransport)
        await first.createFirstWorkspace(workspaceName: "  Cafe\u{301}  ", locationName: " Home ")?.value
        let pending = try XCTUnwrap(try CloudWorkspaceSetupFileJournal(url: url).load())
        XCTAssertNil(pending.receipt)
        let secondTransport = SetupTransport(userID: userA)
        let restarted = await signedIn(CloudWorkspaceSetupFileJournal(url: url), secondTransport)
        XCTAssertEqual(restarted.pendingWorkspaceSetup?.request, pending.request)
        XCTAssertNil(restarted.createFirstWorkspace(workspaceName: "Changed", locationName: "Changed"))
        await restarted.retryWorkspaceSetup()?.value
        let original = await firstTransport.posts
        let replay = await secondTransport.posts
        XCTAssertEqual(original, replay)
        XCTAssertEqual(restarted.workspaceSetupReceipt?.requestId, pending.request.requestId)
        XCTAssertNotNil(try CloudWorkspaceSetupFileJournal(url: url).load()?.receipt)
        XCTAssertFalse(restarted.canCreateFirstWorkspace)
    }

    func testCancelledReplyCannotSaveReceiptAndDifferentUserCannotReplayPending() async throws {
        let journal = TestWorkspaceJournal()
        let transport = SetupTransport(userID: userA, setup: [.hold])
        let first = await signedIn(journal, transport)
        let operation = first.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")
        await transport.waitUntilHeld()
        let saved = try XCTUnwrap(journal.record)
        first.signOut()
        XCTAssertNil(first.pendingWorkspaceSetup)
        XCTAssertNil(first.workspaceSetupReceipt)
        let otherTransport = SetupTransport(userID: userB)
        let other = await signedIn(journal, otherTransport)
        XCTAssertNil(other.recoverWorkspaceSetup())
        XCTAssertNil(other.retryWorkspaceSetup())
        XCTAssertNil(other.createFirstWorkspace(workspaceName: "Other", locationName: "Other"))
        XCTAssertEqual(other.failure, .pendingOtherUser)
        await transport.release()
        await operation?.value
        XCTAssertEqual(journal.record, saved)
        XCTAssertNil(first.workspaceSetupReceipt)
        let recoveryTransport = SetupTransport(userID: userA)
        let recovered = await signedIn(journal, recoveryTransport)
        await recovered.recoverWorkspaceSetup()?.value
        XCTAssertEqual(recovered.workspaceSetupReceipt?.requestId, saved.request.requestId)
        let lookups = await recoveryTransport.lookups
        XCTAssertEqual(lookups, [saved.request.requestId])
    }

    func testJournalSaveFailurePreventsPost() async {
        let journal = TestWorkspaceJournal(); journal.failSaveNumber = 1
        let transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        XCTAssertEqual(coordinator.failure, .persistence)
        let posts = await transport.posts
        XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(journal.record)
    }

    func testReceiptWriteThenThrowCannotReuseStaleEmptyDiscoveryForNewKey() async throws {
        let journal = TestWorkspaceJournal(); journal.writeThenThrowSaveNumber = 2
        let transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        await coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")?.value
        let saved = try XCTUnwrap(journal.record)
        XCTAssertNotNil(saved.receipt)
        XCTAssertNil(coordinator.workspaceSetupReceipt)
        XCTAssertEqual(coordinator.failure, .persistence)
        XCTAssertFalse(coordinator.canCreateFirstWorkspace)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Replacement", locationName: "Replacement"))
        XCTAssertEqual(journal.record, saved)
        let posts = await transport.posts
        XCTAssertEqual(posts.count, 1)
    }

    func testReceiptPersistenceFailureKeepsOriginalPendingForIdenticalRetry() async throws {
        let journal = TestWorkspaceJournal(); journal.failSaveNumber = 2
        let transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        await coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")?.value
        let saved = try XCTUnwrap(journal.record)
        XCTAssertNil(saved.receipt)
        XCTAssertNil(coordinator.workspaceSetupReceipt)
        XCTAssertEqual(coordinator.failure, .persistence)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Replacement", locationName: "Replacement"))
        await coordinator.retryWorkspaceSetup()?.value
        let posts = await transport.posts
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0], posts[1])
        XCTAssertEqual(coordinator.workspaceSetupReceipt?.requestId, saved.request.requestId)
    }

    func testUnavailableLookupPreservesPendingAndAllowsOnlyIdenticalReplay() async throws {
        let journal = TestWorkspaceJournal()
        let transport = SetupTransport(userID: userA, setup: [.timeout], lookup: [.unavailable, .unavailable])
        let coordinator = await signedIn(journal, transport)
        await coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")?.value
        let saved = try XCTUnwrap(journal.record)
        await coordinator.recoverWorkspaceSetup()?.value
        if case .api(let status, let error) = coordinator.workspaceSetupFailure {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(error.code, "workspace_setup_unavailable")
            XCTAssertEqual(error.requestId, "trace-id")
        } else { XCTFail("Preserve the accepted setup error for future recovery presentation") }
        XCTAssertEqual(journal.record, saved)
        XCTAssertNil(coordinator.workspaceSetupReceipt)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "New", locationName: "New"))
        await coordinator.retryWorkspaceSetup()?.value
        XCTAssertNil(coordinator.workspaceSetupFailure)
        XCTAssertEqual(coordinator.workspaceSetupReceipt?.requestId, saved.request.requestId)
        await coordinator.recoverWorkspaceSetup()?.value
        XCTAssertNotNil(coordinator.workspaceSetupFailure)
        coordinator.signOut()
        XCTAssertNil(coordinator.workspaceSetupFailure)
    }

    func testSetupRequiresCompletedEmptyDiscoveryAndInvalidNamesDoNotPersist() async {
        let journal = TestWorkspaceJournal()
        let transport = SetupTransport(userID: userA)
        let coordinator = coordinator(journal, transport)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        await coordinator.signIn(provider: .google)?.value
        XCTAssertTrue(coordinator.canCreateFirstWorkspace)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: " \n ", locationName: "Location"))
        XCTAssertEqual(coordinator.failure, .workspaceSetup)
        XCTAssertNil(journal.record)
        let posts = await transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testMalformedAndServerFailureNeverRotateOperation() async throws {
        for mode in [SetupTransport.Mode.malformed, .serverFailure] {
            let journal = TestWorkspaceJournal()
            let transport = SetupTransport(userID: userA, setup: [mode])
            let coordinator = await signedIn(journal, transport)
            await coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")?.value
            let request = try XCTUnwrap(journal.record?.request)
            XCTAssertNil(coordinator.workspaceSetupReceipt)
            XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Changed", locationName: "Changed"))
            await coordinator.retryWorkspaceSetup()?.value
            XCTAssertEqual(coordinator.workspaceSetupReceipt?.requestId, request.requestId)
            let posts = await transport.posts
            XCTAssertEqual(posts[0], posts[1])
        }
    }
}

@MainActor
final class TestWorkspaceJournal: CloudWorkspaceSetupJournal {
    var record: CloudWorkspaceSetupJournalRecord?
    var failSaveNumber: Int?
    var writeThenThrowSaveNumber: Int?
    private(set) var saves = 0
    func load() throws -> CloudWorkspaceSetupJournalRecord? { record }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws {
        saves += 1
        if saves == failSaveNumber { throw CocoaError(.fileWriteUnknown) }
        self.record = record
        if saves == writeThenThrowSaveNumber { throw CocoaError(.fileWriteUnknown) }
    }
}
private struct SetupTokens: CloudNativeTokenProvider {
    func idToken() async throws -> String { "fixture-token" }
}
private actor SetupTransport: HTTPTransport {
    enum Mode { case success, timeout, hold, unavailable, malformed, serverFailure }
    private let userID: UUID
    private var setup: [Mode]
    private var lookup: [Mode]
    private var continuation: CheckedContinuation<HTTPTransportResponse, Never>?
    private var heldResponse: HTTPTransportResponse?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var posts: [CloudNativeWorkspaceSetupRequest] = []
    private(set) var lookups: [UUID] = []
    init(userID: UUID, setup: [Mode] = [], lookup: [Mode] = []) { self.userID = userID; self.setup = setup; self.lookup = lookup }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        let path = request.url.path
        if path == "/v1/native/sign-in" {
            return .init(status: 200, body: Data("{\"user\":{\"id\":\"\(userID.uuidString)\",\"displayName\":\"Fixture person\",\"email\":null},\"signInProvider\":\"google.com\",\"authTime\":\"2026-10-02T16:00:00Z\",\"tokenExpiresAt\":\"2026-10-02T17:00:00Z\"}".utf8))
        }
        if path == "/v1/native/accounts" { return .init(status: 200, body: Data(#"{"items":[],"nextCursor":null}"#.utf8)) }
        let id: UUID
        let mode: Mode
        if request.method == "POST" {
            let body = try JSONDecoder().decode(CloudNativeWorkspaceSetupRequest.self, from: XCTUnwrap(request.body))
            posts.append(body); id = body.requestId; mode = setup.isEmpty ? .success : setup.removeFirst()
        } else {
            id = try XCTUnwrap(UUID(uuidString: request.url.lastPathComponent)); lookups.append(id)
            mode = lookup.isEmpty ? .success : lookup.removeFirst()
        }
        switch mode {
        case .timeout: throw URLError(.timedOut)
        case .unavailable: return .init(status: 404, body: Data(#"{"code":"workspace_setup_unavailable","message":"Unavailable","requestId":"trace-id"}"#.utf8))
        case .malformed: return .init(status: 200, body: Data("invalid".utf8))
        case .serverFailure: return .init(status: 503, body: Data())
        case .success, .hold:
            let response = HTTPTransportResponse(status: 200, body: Data("{\"requestId\":\"\(id.uuidString)\",\"accountId\":\"11111111-1111-4111-8111-111111111111\",\"locationId\":\"33333333-3333-4333-8333-333333333333\",\"createdAt\":\"2026-10-02T16:00:00.000Z\"}".utf8))
            if mode == .success { return response }
            heldResponse = response
            return await withCheckedContinuation { continuation in
                self.continuation = continuation; waiters.forEach { $0.resume() }; waiters = []
            }
        }
    }
    func waitUntilHeld() async { if continuation != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { continuation?.resume(returning: heldResponse!); continuation = nil; heldResponse = nil }
}
