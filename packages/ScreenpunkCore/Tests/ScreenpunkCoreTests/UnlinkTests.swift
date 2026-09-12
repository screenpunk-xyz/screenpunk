import XCTest
@testable import ScreenpunkCore

/// TEST_PLAN "Unlink": credentials and grants are gone before any further request can be built.
final class UnlinkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func statusGrant(authRef: String = "keychain:fixture-status") throws -> ConnectionGrant {
        var grant = try ConnectionGrantValidator.decode(RepoFixtures.data("schemas/fixtures/valid/connection-grant.json"))
        grant.authRef = authRef
        return grant
    }

    private func eventsGrant() throws -> ConnectionGrant {
        try ConnectionGrantValidator.decode(RepoFixtures.data("schemas/fixtures/valid/connection-grant-ws.json"))
    }

    func testClearCredentialsRemovesSecretsAndGrantsBeforeAnyFurtherRequest() async throws {
        let store = MemoryCredentialStore()
        let http = ScriptedHTTPTransport(fallback: .success(HTTPTransportResponse(status: 200, body: Data("{}".utf8))))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try statusGrant()
        try store.put(Data("fixture-token".utf8), for: grant.authRef)
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))

        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer fixture-token")

        try await runtime.clearCredentials()

        XCTAssertNil(try store.secret(for: grant.authRef), "Keychain-backed secret is deleted")
        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("an unlinked runtime must not build requests")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        do {
            _ = try await runtime.subscribe(alias: "events", operation: "listen", parameters: [:])
            XCTFail("an unlinked runtime must not open sockets")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        XCTAssertEqual(http.requests.count, 1, "no transport call happens after unlink")
    }

    func testClearCredentialsCoversEveryAuthRefAndIsIdempotent() async throws {
        let store = MemoryCredentialStore()
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: ScriptedHTTPTransport(),
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let status = try statusGrant()
        let events = try eventsGrant()
        try store.put(Data("a".utf8), for: status.authRef)
        try store.put(Data("b".utf8), for: events.authRef)
        try store.put(Data("c".utf8), for: "keychain:orphaned-from-previous-dashboard")
        try await runtime.install(grant: status, binding: ConnectionAuthBinding(authRef: status.authRef, placement: .bearer))
        try await runtime.install(grant: events, binding: ConnectionAuthBinding(authRef: events.authRef, placement: .none))

        try await runtime.clearCredentials()
        XCTAssertNil(try store.secret(for: status.authRef))
        XCTAssertNil(try store.secret(for: events.authRef))
        XCTAssertNil(try store.secret(for: "keychain:orphaned-from-previous-dashboard"), "unlink wipes every stored secret, not only installed grants")

        try await runtime.clearCredentials()
        XCTAssertNil(try store.secret(for: status.authRef))
    }

    func testReinstallAfterUnlinkRequiresAFreshGrantAndSecret() async throws {
        let store = MemoryCredentialStore()
        let http = ScriptedHTTPTransport(fallback: .success(HTTPTransportResponse(status: 200, body: Data("{}".utf8))))
        let runtime = ConnectionRuntime(
            dashboardId: "dash",
            store: store,
            http: http,
            webSocket: MockWebSocketTransport(messages: []),
            resolver: FixedResolver(["127.0.0.1"]),
            clock: TestClock(t0)
        )
        let grant = try statusGrant()
        try store.put(Data("old".utf8), for: grant.authRef)
        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))
        try await runtime.clearCredentials()

        try await runtime.install(grant: grant, binding: ConnectionAuthBinding(authRef: grant.authRef, placement: .bearer))
        do {
            _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
            XCTFail("a re-installed grant without a re-approved secret must not send")
        } catch {
            XCTAssertEqual(error as? ConnectionFailure, .permissionRequired)
        }
        XCTAssertTrue(http.requests.isEmpty)

        try store.put(Data("new".utf8), for: grant.authRef)
        _ = try await runtime.request(alias: "status", operation: "getStatus", parameters: [:])
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new")
    }

    func testMemoryStoreNeverDescribesSecrets() throws {
        let store = MemoryCredentialStore()
        try store.put(Data("do-not-print".utf8), for: "keychain:x")
        XCTAssertFalse(store.debugDescription.contains("do-not-print"))
        XCTAssertFalse(store.debugDescription.contains("keychain:x"))
        try store.delete("keychain:x")
        XCTAssertNil(try store.secret(for: "keychain:x"))
    }

    func testUnlinkChromeIsNativeSingleActionAndSurvivesContentDeath() {
        XCTAssertEqual(UnlinkGestureSpec.fingers, 2)
        XCTAssertEqual(UnlinkGestureSpec.holdSeconds, 10)
        XCTAssertEqual(UnlinkGestureSpec.actionCount, 1)
        XCTAssertEqual(UnlinkGestureSpec.actionTitle, "Unlink")
        XCTAssertTrue(UnlinkGestureSpec.worksOverTerminatedWebContent)
        XCTAssertTrue(UnlinkGestureSpec.voiceOverEquivalent)
        XCTAssertTrue(UnlinkGestureSpec.explanation.lowercased().contains("credentials"))
        XCTAssertTrue(ContentProcessFailure.unlinkGestureRemainsAvailable)
        XCTAssertTrue(ContentProcessFailure.recoveryReloadsActivePackage)
    }
}
