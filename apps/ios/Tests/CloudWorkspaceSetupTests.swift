import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple
@testable import Screenpunk

@MainActor
final class CloudWorkspaceSetupTests: XCTestCase {
    private let userA = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let userB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private func fileJournal(_ legacy: URL) -> CloudWorkspaceSetupFileJournal {
        .init(directory: legacy.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("xyz.screenpunk.cloud-operations"), legacyJournal: legacy)
    }
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

    func testFailedInitialWriteRetainsExactRequestAcrossSignOutAndRepairsBeforePost() async throws {
        let journal = TestWorkspaceJournal(); journal.failSaveNumber = 1
        let transport = SetupTransport(userID: userA), coordinator = await signedIn(journal, transport)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: " Cafe\u{301} ", locationName: " Home "))
        let exact = try XCTUnwrap(journal.attemptedRecord)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Different", locationName: "Different"))
        coordinator.signOut(); XCTAssertNil(coordinator.pendingWorkspaceSetup)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertFalse(coordinator.canCreateFirstWorkspace)
        await coordinator.retryWorkspaceSetup()?.value
        XCTAssertEqual(journal.repairs, 1)
        let posts = await transport.posts
        XCTAssertEqual(posts, [exact.request]); XCTAssertEqual(coordinator.workspaceSetupReceipt?.requestId, exact.request.requestId)
    }
    func testReceiptRepairAfterRestartHasNoNetworkAndWrongUserCannotRepair() async throws {
        let journal = TestWorkspaceJournal(); journal.failSaveNumber = 2
        let firstTransport = SetupTransport(userID: userA), first = await signedIn(journal, firstTransport)
        await first.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")?.value
        let completed = try XCTUnwrap(journal.attemptedRecord); XCTAssertNotNil(completed.receipt)
        first.signOut()
        let otherTransport = SetupTransport(userID: userB), other = await signedIn(journal, otherTransport)
        XCTAssertNil(other.retryWorkspaceSetup()); XCTAssertEqual(other.failure, .pendingOtherUser); XCTAssertEqual(journal.repairs, 0)
        let transport = SetupTransport(userID: userA), restarted = await signedIn(journal, transport)
        await restarted.recoverWorkspaceSetup()?.value
        XCTAssertEqual(restarted.workspaceSetupReceipt, completed.receipt)
        let posts = await transport.posts, lookups = await transport.lookups
        XCTAssertTrue(posts.isEmpty); XCTAssertTrue(lookups.isEmpty); XCTAssertFalse(restarted.canCreateFirstWorkspace)
    }
    func testRevocationDuringPendingSaveDoesNotPostOrRepublish() async throws {
        let journal = TestWorkspaceJournal(), transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        journal.onSave = { [weak coordinator] _ in coordinator?.signOut() }
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        XCTAssertNotNil(journal.record); XCTAssertNil(coordinator.humanIdentity); XCTAssertNil(coordinator.pendingWorkspaceSetup)
        let posts = await transport.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testRevocationDuringReceiptSaveDoesNotRepublish() async throws {
        let journal = TestWorkspaceJournal(), transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        journal.onSave = { [weak coordinator] in if $0.receipt != nil { coordinator?.signOut() } }
        await coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location")?.value
        XCTAssertNotNil(journal.record?.receipt)
        XCTAssertNil(coordinator.humanIdentity); XCTAssertNil(coordinator.workspaceSetupReceipt); XCTAssertNil(coordinator.pendingWorkspaceSetup)
    }
    func testFreshCompleteDiscoveryUsesExplicitSuccessorAfterReceipt() async throws {
        let journal = TestWorkspaceJournal(), transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        await coordinator.createFirstWorkspace(workspaceName: "First", locationName: "Location")?.value
        let first = try XCTUnwrap(journal.record)
        await coordinator.signIn(provider: .google)?.value
        XCTAssertTrue(coordinator.canCreateFirstWorkspace)
        await coordinator.createFirstWorkspace(workspaceName: "Second", locationName: "Location")?.value
        XCTAssertEqual(journal.successors, 1); XCTAssertNotEqual(journal.record?.request.requestId, first.request.requestId)
    }
    func testRealDurableReceiptUncertaintyRestartRepairsWithoutNetwork() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("xyz.screenpunk.cloud-operations"), legacy = base.appendingPathComponent("xyz.screenpunk.device/native-workspace-setup.json")
        var replacements = 0
        let store = try CloudWorkspaceSetupOperationStore(directory: directory, legacyJournal: legacy, boundary: {
            if $0 == .afterCandidateDirectorySync { replacements += 1; if replacements == 2 { throw CocoaError(.fileWriteUnknown) } }
        }, testOnlyProcessID: UUID())
        let firstTransport = SetupTransport(userID: userA)
        let first = await signedIn(CloudWorkspaceSetupFileJournal(store: store), firstTransport)
        await first.createFirstWorkspace(workspaceName: " Cafe\u{301} ", locationName: " Home ")?.value
        XCTAssertEqual(first.failure, .persistence); first.signOut()
        let restartStore = try CloudWorkspaceSetupOperationStore(directory: directory, legacyJournal: legacy, boundary: { _ in }, testOnlyProcessID: UUID())
        let journal = CloudWorkspaceSetupFileJournal(store: restartStore)
        let otherTransport = SetupTransport(userID: userB), other = await signedIn(journal, otherTransport)
        XCTAssertNil(other.recoverWorkspaceSetup()); XCTAssertEqual(other.failure, .pendingOtherUser)
        let transport = SetupTransport(userID: userA), restarted = await signedIn(journal, transport)
        XCTAssertEqual(restarted.failure, .persistence)
        await restarted.recoverWorkspaceSetup()?.value
        XCTAssertNotNil(restarted.workspaceSetupReceipt)
        XCTAssertEqual(try restartStore.load()?.receipt, restarted.workspaceSetupReceipt)
        let posts = await transport.posts, lookups = await transport.lookups
        XCTAssertTrue(posts.isEmpty); XCTAssertTrue(lookups.isEmpty)
    }
    func testRevocationDuringJournalReadCannotPublishOrStartNewWrite() async {
        let journal = TestWorkspaceJournal(), transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(journal, transport)
        journal.onLoad = { [weak coordinator] in coordinator?.signOut() }
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        XCTAssertEqual(journal.saves, 0); XCTAssertNil(coordinator.humanIdentity)
        XCTAssertNil(coordinator.pendingWorkspaceSetup); XCTAssertNil(coordinator.failure)
        let posts = await transport.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testRevocationDuringRecoveryReadNeverRepairsOrSendsHTTP() async {
        for lookup in [true, false] {
            let journal = TestWorkspaceJournal(), transport = SetupTransport(userID: userA)
            let coordinator = await signedIn(journal, transport)
            journal.failSaveNumber = 1
            XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
            let target = journal.attemptedRecord
            coordinator.signOut()
            let restarted = await signedIn(journal, transport)
            journal.onLoad = { [weak restarted] in restarted?.signOut() }
            XCTAssertNil(lookup ? restarted.recoverWorkspaceSetup() : restarted.retryWorkspaceSetup())
            XCTAssertEqual(journal.repairs, 0)
            XCTAssertEqual(journal.saves, 1)
            XCTAssertEqual(journal.attemptedRecord, target)
            XCTAssertNil(journal.record)
            XCTAssertNil(restarted.humanIdentity)
            XCTAssertNil(restarted.pendingWorkspaceSetup)
            let posts = await transport.posts, lookups = await transport.lookups
            XCTAssertTrue(posts.isEmpty); XCTAssertTrue(lookups.isEmpty)
        }
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("xyz.screenpunk.device/native-workspace-setup.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("unreadable-journal".utf8)
        try corrupt.write(to: url)
        let transport = SetupTransport(userID: userA)
        let coordinator = await signedIn(fileJournal(url), transport)
        XCTAssertEqual(coordinator.failure, .persistence)
        XCTAssertFalse(coordinator.canCreateFirstWorkspace)
        XCTAssertNil(coordinator.createFirstWorkspace(workspaceName: "Workspace", locationName: "Location"))
        XCTAssertNil(coordinator.recoverWorkspaceSetup())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let posts = await transport.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testLostReplyRestartRetriesExactNamesAndRequestID() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("xyz.screenpunk.device/native-workspace-setup.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let firstTransport = SetupTransport(userID: userA, setup: [.timeout])
        let first = await signedIn(fileJournal(url), firstTransport)
        await first.createFirstWorkspace(workspaceName: "  Cafe\u{301}  ", locationName: " Home ")?.value
        let pending = try XCTUnwrap(try fileJournal(url).load())
        XCTAssertNil(pending.receipt)
        let secondTransport = SetupTransport(userID: userA)
        let restarted = await signedIn(fileJournal(url), secondTransport)
        XCTAssertEqual(restarted.pendingWorkspaceSetup?.request, pending.request)
        XCTAssertNil(restarted.createFirstWorkspace(workspaceName: "Changed", locationName: "Changed"))
        await restarted.retryWorkspaceSetup()?.value
        let original = await firstTransport.posts
        let replay = await secondTransport.posts
        XCTAssertEqual(original, replay)
        XCTAssertEqual(restarted.workspaceSetupReceipt?.requestId, pending.request.requestId)
        XCTAssertNotNil(try fileJournal(url).load()?.receipt)
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

    func testReceiptPersistenceFailureRepairsLocallyWithoutAnotherPost() async throws {
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
        XCTAssertEqual(posts.count, 1)
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
        XCTAssertNil(coordinator.workspaceSetupFailure)
        let lookups = await transport.lookups
        XCTAssertEqual(lookups.count, 1, "Completed local receipt needs no further lookup")
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
    var onSave: ((CloudWorkspaceSetupJournalRecord) -> Void)?
    var onLoad: (() -> Void)?
    private(set) var saves = 0
    private(set) var successors = 0
    private(set) var repairs = 0
    private var attempt: (record: CloudWorkspaceSetupJournalRecord, successor: Bool)?
    var attemptedRecord: CloudWorkspaceSetupJournalRecord? { attempt?.record }
    func load() throws -> CloudWorkspaceSetupJournalRecord? {
        onLoad?()
        guard attempt == nil else { throw CloudWorkspaceSetupOperationStoreError.outcomeUncertain }; return record
    }
    func save(_ record: CloudWorkspaceSetupJournalRecord) throws { try write(record, successor: false) }
    func beginSuccessor(_ record: CloudWorkspaceSetupJournalRecord) throws {
        guard let current = self.record, current.permits(record, beginningSuccessor: true) else { throw CloudWorkspaceSetupOperationStoreError.conflict }
        successors += 1; try write(record, successor: true)
    }
    private func write(_ record: CloudWorkspaceSetupJournalRecord, successor: Bool) throws {
        saves += 1; attempt = (record, successor)
        onSave?(record)
        if saves == failSaveNumber { throw CocoaError(.fileWriteUnknown) }
        self.record = record
        if saves == writeThenThrowSaveNumber { throw CocoaError(.fileWriteUnknown) }
        attempt = nil
    }
    func retryPendingWrite(expectedUserID: UUID) throws -> CloudWorkspaceSetupJournalRecord {
        guard let attempt else { throw CloudWorkspaceSetupOperationStoreError.noRecoverableTarget }
        guard attempt.record.userID == expectedUserID else { throw CloudWorkspaceSetupOperationStoreError.differentUser }
        repairs += 1; record = attempt.record; self.attempt = nil; return attempt.record
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
