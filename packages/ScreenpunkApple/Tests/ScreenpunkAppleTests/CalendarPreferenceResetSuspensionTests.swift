import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

@MainActor final class CalendarPreferenceResetSuspensionTests: XCTestCase {
    private func fixture(_ transport: any HTTPTransport, expired: Bool = false) throws -> (GoogleCalendarDeviceService, MemoryCredentialStore, GoogleCalendarSuspensionDomain) {
        let store = MemoryCredentialStore(), domain = GoogleCalendarSuspensionDomain()
        let account = GoogleCalendarAccount(id: "fixture", email: "fixture@example.com", clientID: "123-fixture.apps.googleusercontent.com", accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: expired ? .distantPast : .distantFuture, calendars: [.init(id: "calendar", summary: "Calendar")])
        try store.put(JSONEncoder().encode(GoogleCalendarState(accounts: [account], selections: ["screen": [.init(accountID: "fixture", calendarID: "calendar")]])), for: GoogleCalendarDeviceService.storageKey)
        return (.init(store: store, transport: transport, suspension: domain), store, domain)
    }
    func testLateRefreshAndExistingNewCalendarInstancesAreBlocked() async throws {
        let transport = WriterDelayedTransport(), (service, store, domain) = try fixture(transport, expired: true)
        let other = GoogleCalendarDeviceService(store: store, transport: transport, suspension: domain)
        let generations = [service.generation, other.generation], before = try store.secret(for: GoogleCalendarDeviceService.storageKey)
        let task = Task { try await service.reloadCalendars(accountID: "fixture") }
        await transport.waitForRequest(); service.suspendForReset()
        XCTAssertNotEqual(service.generation, generations[0]); XCTAssertNotEqual(other.generation, generations[1])
        await transport.release(#"{"access_token":"late","expires_in":3600,"token_type":"Bearer"}"#)
        do { try await task.value; XCTFail("late refresh") } catch {}
        let fresh = GoogleCalendarDeviceService(store: store, transport: transport, suspension: domain)
        for blocked in [service, other, fresh] {
            XCTAssertThrowsError(try blocked.snapshot())
            XCTAssertThrowsError(try blocked.select(dashboard: "screen", selection: .init(accountID: "fixture", calendarID: "calendar"), enabled: true))
            XCTAssertThrowsError(try blocked.disconnect(accountID: "fixture")); XCTAssertThrowsError(try blocked.erase())
            XCTAssertFalse(blocked.isReady(dashboard: "screen"))
            do { try await blocked.reloadCalendars(accountID: "fixture"); XCTFail("new work") } catch {}
        }
        XCTAssertEqual(try store.secret(for: GoogleCalendarDeviceService.storageKey), before)
        let count = await transport.count(); XCTAssertEqual(count, 1)
    }
    func testLateOAuthAndInventoryCannotSave() async throws {
        for oauthFlow in [false, true] {
            let transport = WriterDelayedTransport(), (service, store, _) = try fixture(transport)
            let before = try store.secret(for: GoogleCalendarDeviceService.storageKey), generation = service.generation
            let oauth = try GoogleCalendarOAuth(clientID: "123-fixture.apps.googleusercontent.com")
            let task = Task {
                if oauthFlow { try await service.connect(oauth: oauth, code: "fixture-code", expected: generation) }
                else { try await service.reloadCalendars(accountID: "fixture") }
            }
            await transport.waitForRequest(); service.suspendForReset()
            await transport.release(oauthFlow ? #"{"access_token":"late","refresh_token":"late","expires_in":3600,"token_type":"Bearer"}"# : #"{"items":[{"id":"late","summary":"Late"}]}"#)
            do { try await task.value; XCTFail("late response") } catch { XCTAssertEqual(error as? GoogleCalendarError, .permission) }
            XCTAssertEqual(try store.secret(for: GoogleCalendarDeviceService.storageKey), before)
            let count = await transport.count(); XCTAssertEqual(count, 1)
        }
    }
    func testLateEventsCannotReturnSuccess() async throws {
        let transport = WriterDelayedTransport(), (service, store, _) = try fixture(transport)
        let before = try store.secret(for: GoogleCalendarDeviceService.storageKey)
        let task = Task { try await service.events(dashboard: "screen", parameters: ["timeMin": "2026-10-01T00:00:00Z", "timeMax": "2026-10-02T00:00:00Z"]) }
        await transport.waitForRequest(); service.suspendForReset()
        await transport.release(#"{"items":[{"id":"late-event"}]}"#)
        do { _ = try await task.value; XCTFail("late events") } catch { XCTAssertEqual(error as? GoogleCalendarError, .permission) }
        XCTAssertEqual(try store.secret(for: GoogleCalendarDeviceService.storageKey), before)
    }
    func testPreferencesBlockReadCreationWritesAndNewAliasStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenPreferenceStore(root: root); store.suspendForReset()
        XCTAssertThrowsError(try store.generation())
        let alias = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/var/", with: "/var/")), fresh = ScreenPreferenceStore(root: alias)
        XCTAssertThrowsError(try fresh.generation()); XCTAssertThrowsError(try fresh.get(dashboard: "screen", key: "key", generation: UUID()))
        XCTAssertThrowsError(try fresh.set(dashboard: "screen", key: "key", value: "late", generation: UUID()))
        XCTAssertThrowsError(try fresh.remove(dashboard: "screen", key: "key", generation: UUID())); XCTAssertThrowsError(try fresh.erase())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testPreferencesSuspensionSerializesWithInFlightAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ScreenPreferenceStore(root: root), generation = try original.generation()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), suspending = DispatchSemaphore(value: 0), suspended = DispatchSemaphore(value: 0)
        let store = ScreenPreferenceStore(root: root, beforeMutation: { entered.signal(); _ = release.wait(timeout: .now() + 3) })
        DispatchQueue.global().async { _ = entered.wait(timeout: .now() + 3); suspending.signal(); store.suspendForReset(); suspended.signal() }
        DispatchQueue.global().async { _ = suspending.wait(timeout: .now() + 3); XCTAssertEqual(suspended.wait(timeout: .now() + 0.05), .timedOut); release.signal() }
        try store.set(dashboard: "screen", key: "key", value: "before-suspend", generation: generation)
        XCTAssertEqual(suspended.wait(timeout: .now() + 3), .success)
        let file = root.appendingPathComponent("preferences-v1.json"), before = try Data(contentsOf: file)
        XCTAssertThrowsError(try original.set(dashboard: "screen", key: "key", value: "late", generation: generation))
        XCTAssertThrowsError(try ScreenPreferenceStore(root: root).generation())
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
private actor WriterDelayedTransport: HTTPTransport {
    private var requests = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<HTTPTransportResponse, Never>?
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests += 1; waiter?.resume(); waiter = nil
        return await withCheckedContinuation { response = $0 }
    }
    func waitForRequest() async { if requests > 0 { return }; await withCheckedContinuation { waiter = $0 } }
    func release(_ json: String) { response?.resume(returning: .init(status: 200, body: Data(json.utf8))); response = nil }
    func count() -> Int { requests }
}
